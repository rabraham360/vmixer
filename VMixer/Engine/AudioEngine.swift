//
//  AudioEngine.swift
//  VMixer
//
//  Created by Rohan Abraham on 5/2/26.
//

import Foundation
import AppKit
import CoreAudio
import AudioToolbox
import Combine
import Accelerate
import CoreGraphics
import AVFoundation
import os

@MainActor
final class AudioEngine: ObservableObject {
    
    // MARK: - Realtime Control
    private final class RealtimeControl {
        private var lock = os_unfair_lock_s()
        private var _volume: Float = 1.0
        private var _muted = false
        private var _lastFrameCount: UInt64 = 0
        private var _currentLevel: Float = 0.0
        
        let volumeCompensation: Float
        
        init(volumeCompensation: Float = 1.0) {
            self.volumeCompensation = volumeCompensation
        }
        
        var gain: Float {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            return _muted ? 0.0 : (_volume * volumeCompensation)
        }
        
        var currentLevel: Float {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            return _currentLevel
        }
        
        func set(volume: Float) {
            os_unfair_lock_lock(&lock)
            _volume = min(max(volume, 0.0), 1.0)
            os_unfair_lock_unlock(&lock)
        }
        
        func set(muted: Bool) {
            os_unfair_lock_lock(&lock)
            _muted = muted
            os_unfair_lock_unlock(&lock)
        }
        
        func set(level: Float) {
            os_unfair_lock_lock(&lock)
            _currentLevel = level
            os_unfair_lock_unlock(&lock)
        }
        
        func add(frames: UInt32) {
            os_unfair_lock_lock(&lock)
            _lastFrameCount &+= UInt64(frames)
            os_unfair_lock_unlock(&lock)
        }
    }

    // MARK: - Models
    struct Target: Identifiable {
        let id: Int32
        let pid: Int32
        var displayName: String
        let bundleID: String?
        var tapID: AudioObjectID
        var aggregateDeviceID: AudioObjectID
        var ioProcID: AudioDeviceIOProcID?
        var volume: Float
        var isMuted: Bool
        var level: Float = 0.0
        var icon: NSImage?
    }

    struct RunningApp: Identifiable, Hashable {
        let pid: Int32
        let name: String
        let bundleID: String?

        var id: Int32 { pid }
        var title: String {
            if let bundleID, !bundleID.isEmpty {
                return "\(name) (\(bundleID))"
            }
            return name
        }
    }

    // MARK: - Published State
    @Published private(set) var targets: [Target] = []
    @Published private(set) var runningApps: [RunningApp] = []
    @Published var statusMessage = "Ready"
    
    @Published var masterVolume: Float = 1.0 {
        didSet {
            if !isSyncingHardware { setSystemVolume(to: masterVolume) }
        }
    }
    
    @Published var isMasterMuted: Bool = false {
        didSet {
            if !isSyncingHardware { setSystemMute(isMuted: isMasterMuted) }
        }
    }
    
    private var selectedOutputDeviceID: AudioObjectID = 0
    private var isSyncingHardware = false
    
    private var controlsByPID: [Int32: RealtimeControl] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var pollingTask: Task<Void, Never>?

    // MARK: - Initialization
    init() {
        self.selectedOutputDeviceID = getDefaultOutputDeviceID()
        
        self.isSyncingHardware = true
        self.masterVolume = getSystemVolume(for: self.selectedOutputDeviceID)
        self.isMasterMuted = getSystemMute(for: self.selectedOutputDeviceID)
        self.isSyncingHardware = false
        
        refreshRunningApps()
        
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
        
        let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if audioStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if !granted { print("Microphone permission denied!") }
            }
        } else if audioStatus == .denied || audioStatus == .restricted {
            statusMessage = "Microphone permission is blocked in System Settings."
        }
        
        autoHookExistingMediaApps()
        setupAutoHookingObserver()
        
        // Start the master async loop
        startPolling()
    }
    
    // MARK: - Bulletproof Polling Loop
    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { @MainActor in
            while !Task.isCancelled {
                self.updateHardwareAndMeters()
                // Sleep for ~33ms (approx 30 frames per second)
                try? await Task.sleep(nanoseconds: 33_333_333)
            }
        }
    }
    
    private func updateHardwareAndMeters() {
        // 1. Verify we are targeting the actual physical output device right now
        let currentDevice = getDefaultOutputDeviceID()
        if currentDevice != selectedOutputDeviceID {
            self.selectedOutputDeviceID = currentDevice
            handleDeviceChange()
        }
        
        // 2. Check the hardware for keyboard button presses!
        if selectedOutputDeviceID != 0 {
            let currentVol = getSystemVolume(for: selectedOutputDeviceID)
            if abs(masterVolume - currentVol) > 0.01 {
                isSyncingHardware = true
                masterVolume = currentVol
                isSyncingHardware = false
            }
            
            let currentMute = getSystemMute(for: selectedOutputDeviceID)
            if isMasterMuted != currentMute {
                isSyncingHardware = true
                isMasterMuted = currentMute
                isSyncingHardware = false
            }
        }
        
        // 3. Update the VU meters for the UI
        for i in 0..<targets.count {
            let pid = targets[i].pid
            if let control = controlsByPID[pid] {
                targets[i].level = control.currentLevel
            }
        }
    }

    // MARK: - Auto Hooking Logic
    private func autoHookExistingMediaApps() {
        let mediaAppBundles: Set<String> = [
            "com.spotify.client", "com.apple.Music", "com.apple.Safari",
            "com.google.Chrome", "org.mozilla.firefox", "com.microsoft.edgemac", "com.apple.TV","com.apple.FaceTime"
        ]
        
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier,
                  mediaAppBundles.contains(bundleID),
                  app.processIdentifier > 0 else { continue }
            
            let runningApp = RunningApp(
                pid: app.processIdentifier,
                name: app.localizedName ?? bundleID,
                bundleID: bundleID
            )
            addTarget(app: runningApp)
        }
    }

    private func setupAutoHookingObserver() {
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self = self,
                      let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.activationPolicy == .regular,
                      app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                
                let defaults = UserDefaults.standard
                let autoHookEnabled = defaults.object(forKey: "autoHookEnabled") as? Bool ?? true
                guard autoHookEnabled else { return }
                
                let ignoredString = defaults.string(forKey: "ignoredBundleIDs") ?? "com.apple.finder"
                let ignoredBundleIDs = Set(ignoredString.split(separator: ",").map(String.init))
                
                if let bundleID = app.bundleIdentifier, ignoredBundleIDs.contains(bundleID) { return }
                if self.targets.contains(where: { $0.pid == app.processIdentifier }) { return }
                
                let runningApp = RunningApp(
                    pid: app.processIdentifier,
                    name: app.localizedName ?? app.bundleIdentifier ?? "Unknown",
                    bundleID: app.bundleIdentifier
                )
                self.addTarget(app: runningApp)
            }
            .store(in: &cancellables)
    }

    // MARK: - App Tracking & Setup
    func refreshRunningApps() {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.processIdentifier > 0 }
            .filter { !$0.isTerminated }
            .compactMap { app -> RunningApp? in
                let pid = Int32(app.processIdentifier)
                guard pid > 0 else { return nil }
                if pid == Int32(ProcessInfo.processInfo.processIdentifier) {
                    return nil
                }

                let localizedName = app.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let fallbackName = app.bundleIdentifier ?? "PID \(pid)"
                let safeName = localizedName.isEmpty ? fallbackName : localizedName
                return RunningApp(pid: pid, name: safeName, bundleID: app.bundleIdentifier)
            }
            .reduce(into: [Int32: RunningApp]()) { acc, app in
                acc[app.pid] = app
            }
            .map(\.value)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        runningApps = apps
    }

    func addTarget(pid: Int32, name: String?) {
        addTarget(pid: pid, name: name, bundleID: nil)
    }

    func addTarget(pid: Int32, name: String?, bundleID: String?) {
        guard pid > 0 else { return }
        if targets.contains(where: { $0.pid == pid }) { return }

        guard let tapResult = createTapWithFallback(pid: pid, bundleID: bundleID) else {
            return
        }
        let tapID = tapResult.tapID
        guard tapID != kAudioObjectUnknown, tapID != 0 else { return }

        var compensation: Float = 1.0
                
        if let bundleID = bundleID {
            switch bundleID {
            case "com.apple.FaceTime":
                compensation = 20   // 3x boost for FaceTime
            case "com.spotify.client":
                compensation = 1.5   // Example: 1.5x boost for Spotify
            case "com.apple.Safari", "com.google.Chrome":
                compensation = 1.25   // Example: Lower browser volume to 80%
            default:
                compensation = 1.0   // Normal volume for everything else
            }
        }
        let control = RealtimeControl(volumeCompensation: compensation)
        
        guard let aggregateDeviceID = createAggregateDevice(tapID: tapID) else {
            _ = AudioHardwareDestroyProcessTap(tapID)
            return
        }
        guard let ioProcID = startTapIO(deviceID: aggregateDeviceID, control: control) else {
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            _ = AudioHardwareDestroyProcessTap(tapID)
            return
        }

        controlsByPID[pid] = control
        let normalizedName = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = normalizedName.isEmpty ? "PID \(pid)" : normalizedName
        
        var appIcon: NSImage?
        if let app = NSRunningApplication(processIdentifier: pid) {
            appIcon = app.icon
        }

        let target = Target(
            id: pid,
            pid: pid,
            displayName: displayName,
            bundleID: bundleID,
            tapID: tapID,
            aggregateDeviceID: aggregateDeviceID,
            ioProcID: ioProcID,
            volume: 1.0,
            isMuted: false,
            level: 0.0,
            icon: appIcon
        )
        
        targets.append(target)
        statusMessage = "Auto-Hooked \(target.displayName)"
    }

    func addTarget(app: RunningApp) {
        addTarget(pid: app.pid, name: app.name, bundleID: app.bundleID)
    }

    // MARK: - CoreAudio Integration
    private func createTapWithFallback(pid: Int32, bundleID: String?) -> (tapID: AudioObjectID, usedBundleFallback: Bool)? {
        
        if let bundleID, !bundleID.isEmpty {
            var bundleTapID: AudioObjectID = 0
            let bundleDescription = CATapDescription()
            bundleDescription.uuid = UUID()
            
            var bundlesToTap = [bundleID]
            switch bundleID {
            case "com.apple.Safari", "com.apple.SafariTechnologyPreview":
                bundlesToTap.append("com.apple.WebKit.WebContent")
                bundlesToTap.append("com.apple.WebKit.GPU")
            case "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi":
                bundlesToTap.append("\(bundleID).helper")
                bundlesToTap.append("\(bundleID).helper.renderer")
                bundlesToTap.append("\(bundleID).helper.plugin")
            case "org.mozilla.firefox":
                bundlesToTap.append("org.mozilla.plugincontainer")
            case "com.apple.FaceTime":
                bundlesToTap.append("com.apple.avconferenced")
            default:
                break
            }
            
            bundleDescription.bundleIDs = bundlesToTap
            bundleDescription.isMixdown = true
            bundleDescription.isMono = false
            bundleDescription.name = "VMixerTap-\(pid)"
            bundleDescription.isPrivate = false
            bundleDescription.muteBehavior = .mutedWhenTapped

            let bundleStatus = AudioHardwareCreateProcessTap(bundleDescription, &bundleTapID)
            if bundleStatus == noErr {
                let recoveredTapID = normalizedTapID(
                    bundleTapID,
                    fallbackUID: bundleDescription.uuid.uuidString,
                    expectedName: bundleDescription.name
                )
                if recoveredTapID != kAudioObjectUnknown, recoveredTapID != 0 {
                    return (recoveredTapID, true)
                }
                statusMessage = "Tap was created but UID lookup failed."
                return nil
            }
        }

        if let processObjectID = translatePIDToProcessObjectID(pid: pid) {
            var pidTapID: AudioObjectID = 0
            let pidDescription = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
            pidDescription.uuid = UUID()
            pidDescription.name = "VMixerTap-\(pid)"
            pidDescription.isPrivate = false
            pidDescription.muteBehavior = .mutedWhenTapped

            let pidStatus = AudioHardwareCreateProcessTap(pidDescription, &pidTapID)
            if pidStatus == noErr {
                let recoveredTapID = normalizedTapID(
                    pidTapID,
                    fallbackUID: pidDescription.uuid.uuidString,
                    expectedName: pidDescription.name
                )
                if recoveredTapID != kAudioObjectUnknown, recoveredTapID != 0 {
                    return (recoveredTapID, false)
                }
                statusMessage = "Tap was created but UID lookup failed."
                return nil
            }
            statusMessage = "Could not hook PID \(pid)."
            return nil
        }

        statusMessage = "PID \(pid) cannot be tapped by PID."
        return nil
    }

    private func normalizedTapID(_ tapID: AudioObjectID, fallbackUID: String, expectedName: String) -> AudioObjectID {
        if tapID != 0, tapID != kAudioObjectUnknown {
            return tapID
        }
        if let translated = translateTapUIDToObjectID(uid: fallbackUID) {
            return translated
        }
        if let listed = findTapFromTapList(expectedUID: fallbackUID, expectedName: expectedName) {
            return listed
        }
        return 0
    }

    private func translateTapUIDToObjectID(uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToTap,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidValue: CFString = uid as CFString
        var tapID: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<CFString>.size),
            &uidValue,
            &size,
            &tapID
        )

        guard status == noErr, tapID != 0, tapID != kAudioObjectUnknown else { return nil }
        return tapID
    }

    private func findTapFromTapList(expectedUID: String, expectedName: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTapList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize)
        guard sizeStatus == noErr, dataSize >= UInt32(MemoryLayout<AudioObjectID>.size) else { return nil }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var taps = Array(repeating: AudioObjectID(0), count: count)
        let dataStatus = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &taps)
        guard dataStatus == noErr else { return nil }

        for tap in taps.reversed() {
            guard tap != 0, tap != kAudioObjectUnknown else { continue }
            let uid = tapUID(for: tap)
            let name = objectName(for: tap)
            if uid == expectedUID || name == expectedName {
                return tap
            }
        }
        return nil
    }

    private func objectName(for objectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfName: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &cfName)
        guard status == noErr, let cfName else { return nil }
        return cfName as String
    }

    // MARK: - App Controls
    func removeTarget(pid: Int32) {
        guard let index = targets.firstIndex(where: { $0.pid == pid }) else { return }
        let target = targets[index]

        if let ioProcID = target.ioProcID {
            _ = AudioDeviceStop(target.aggregateDeviceID, ioProcID)
            _ = AudioDeviceDestroyIOProcID(target.aggregateDeviceID, ioProcID)
        }
        _ = AudioHardwareDestroyAggregateDevice(target.aggregateDeviceID)

        let status = AudioHardwareDestroyProcessTap(target.tapID)
        controlsByPID[pid] = nil

        targets.remove(at: index)
        if status == noErr {
            statusMessage = "Removed \(target.displayName)."
        }
    }

    func setMuted(pid: Int32, muted: Bool) {
        guard let index = targets.firstIndex(where: { $0.pid == pid }) else { return }
        targets[index].isMuted = muted
        controlsByPID[pid]?.set(muted: muted)
        statusMessage = muted ? "Muted \(targets[index].displayName)." : "Unmuted \(targets[index].displayName)."
    }

    func setVolume(pid: Int32, volume: Float) {
        guard let index = targets.firstIndex(where: { $0.pid == pid }) else { return }
        let clamped = min(max(volume, 0.0), 1.0)
        targets[index].volume = clamped
        controlsByPID[pid]?.set(volume: clamped)
    }

    private func startTapIO(deviceID: AudioObjectID, control: RealtimeControl) -> AudioDeviceIOProcID? {
        var ioProcID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, deviceID, nil) { _, inInputData, _, outOutputData, _ in
            let gain = control.gain

            let inBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let outBuffers = UnsafeMutableAudioBufferListPointer(outOutputData)
            
            var maxLevel: Float = 0.0

            for bufferIndex in 0..<min(inBuffers.count, outBuffers.count) {
                let input = inBuffers[bufferIndex]
                var output = outBuffers[bufferIndex]
                let byteCount = min(input.mDataByteSize, output.mDataByteSize)

                guard let src = input.mData, let dst = output.mData, byteCount > 0 else { continue }
                dst.copyMemory(from: src, byteCount: Int(byteCount))

                let frameCount = Int(byteCount) / MemoryLayout<Float>.size
                if frameCount > 0 {
                    control.add(frames: UInt32(frameCount))
                }
                
                let floatPointer = dst.bindMemory(to: Float.self, capacity: frameCount)
                
                var rms: Float = 0.0
                vDSP_rmsqv(floatPointer, 1, &rms, vDSP_Length(frameCount))
                let db = 20 * log10(max(rms, 0.001))
                let normalizedLevel = max(0.0, min(1.0, (db + 60) / 60))
                maxLevel = max(maxLevel, Float(normalizedLevel))
                
                if gain != 1.0 {
                    var mutableGain = gain
                    vDSP_vsmul(floatPointer, 1, &mutableGain, floatPointer, 1, vDSP_Length(frameCount))
                }
                output.mDataByteSize = byteCount
                outBuffers[bufferIndex] = output
            }
            
            control.set(level: maxLevel)
        }

        guard status == noErr, let ioProcID else { return nil }

        let startStatus = AudioDeviceStart(deviceID, ioProcID)
        guard startStatus == noErr else {
            _ = AudioDeviceDestroyIOProcID(deviceID, ioProcID)
            return nil
        }

        return ioProcID
    }

    private func createAggregateDevice(tapID: AudioObjectID) -> AudioObjectID? {
        let uid = "Rohan.VMixer.Aggregate.\(UUID().uuidString)"
        guard let tapUID = tapUID(for: tapID) else { return nil }
        guard let outputDeviceUID = defaultOutputDeviceUID() else { return nil }

        let tapEntry: [String: Any] = [
            kAudioSubTapUIDKey: tapUID,
            kAudioSubTapDriftCompensationKey: true
        ]

        let outputSubdeviceEntry: [String: Any] = [
            kAudioSubDeviceUIDKey: outputDeviceUID
        ]

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VMixer-\(tapUID.prefix(6))",
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [outputSubdeviceEntry],
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceTapListKey: [tapEntry],
            kAudioAggregateDeviceTapAutoStartKey: true
        ]

        var deviceID: AudioObjectID = 0
        let status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown, deviceID != 0 else { return nil }
        return deviceID
    }

    private func tapUID(for tapID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &cfUID)
        guard status == noErr, let cfUID else { return nil }
        return cfUID as String
    }

    private func defaultOutputDeviceUID() -> String? {
        let deviceID = getDefaultOutputDeviceID()
        guard deviceID != 0 else { return nil }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID: CFString?
        var uidSize = UInt32(MemoryLayout<CFString?>.size)
        let uidStatus = AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &cfUID)
        guard uidStatus == noErr, let cfUID else { return nil }
        return cfUID as String
    }

    private func translatePIDToProcessObjectID(pid: Int32) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var pidValue = pid
        var objectID: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<Int32>.size),
            &pidValue,
            &size,
            &objectID
        )

        guard status == noErr, objectID != kAudioObjectUnknown else { return nil }
        return objectID
    }
    
    // MARK: - Master Output Getters/Setters
    private func getSystemVolume(for deviceID: AudioObjectID) -> Float {
        var volume: Float = 0.0
        var dataSize = UInt32(MemoryLayout<Float>.size)
        
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioHardwareServiceGetPropertyData(deviceID, &address, 0, nil, &dataSize, &volume) == noErr {
            return volume
        }
        
        // Fallback 1: Raw Main Hardware Slider
        address.mSelector = kAudioDevicePropertyVolumeScalar
        if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &volume) == noErr {
            return volume
        }
        
        // Fallback 2: Raw Channel 1 Slider (MacBook built-in speakers)
        address.mElement = 1
        if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &volume) == noErr {
            return volume
        }
        
        return 0.0
    }
    
    private func getSystemMute(for deviceID: AudioObjectID) -> Bool {
        var mutedInt: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &mutedInt) == noErr {
            return mutedInt == 1
        }
        
        address.mElement = 1
        if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &mutedInt) == noErr {
            return mutedInt == 1
        }
        
        // Software Fallback
        return getSystemVolume(for: deviceID) <= 0.001
    }
    
    private func getDefaultOutputDeviceID() -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return deviceID
    }
    
    func setSystemVolume(to value: Float) {
        let deviceID = selectedOutputDeviceID
        guard deviceID != 0 else { return }
        
        var volume = value
        let dataSize = UInt32(MemoryLayout<Float>.size)
        
        // Try Virtual Service First
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioHardwareServiceSetPropertyData(deviceID, &address, 0, nil, dataSize, &volume) == noErr { return }
        
        // Try Raw Hardware Next
        address.mSelector = kAudioDevicePropertyVolumeScalar
        if AudioObjectSetPropertyData(deviceID, &address, 0, nil, dataSize, &volume) == noErr { return }
        
        // Split L/R channels for stuboorn hardware
        address.mElement = 1
        AudioObjectSetPropertyData(deviceID, &address, 0, nil, dataSize, &volume)
        address.mElement = 2
        AudioObjectSetPropertyData(deviceID, &address, 0, nil, dataSize, &volume)
    }
    
    func setSystemMute(isMuted: Bool) {
        let deviceID = selectedOutputDeviceID
        guard deviceID != 0 else { return }

        var mutedInt: UInt32 = isMuted ? 1 : 0
        let dataSize = UInt32(MemoryLayout<UInt32>.size)
        
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        if AudioObjectSetPropertyData(deviceID, &address, 0, nil, dataSize, &mutedInt) == noErr { return }
        
        address.mElement = 1
        let lStatus = AudioObjectSetPropertyData(deviceID, &address, 0, nil, dataSize, &mutedInt)
        address.mElement = 2
        let rStatus = AudioObjectSetPropertyData(deviceID, &address, 0, nil, dataSize, &mutedInt)
        
        if lStatus == noErr || rStatus == noErr { return }
        
        setSystemVolume(to: isMuted ? 0.0 : masterVolume)
    }
    
    private func handleDeviceChange() {
        print("Output device changed! Re-routing audio...")
        
        let activeApps = targets.map { (pid: $0.pid, name: $0.displayName, bundleID: $0.bundleID) }
        
        for app in activeApps {
            removeTarget(pid: app.pid)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            for app in activeApps {
                self?.addTarget(pid: app.pid, name: app.name, bundleID: app.bundleID)
            }
        }
    }
}
