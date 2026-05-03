//
//  TargetRowView.swift
//  VMixer
//
//  Created by Rohan Abraham on 5/2/26.
//

import SwiftUI

struct TargetRowView: View {
    @ObservedObject var engine: AudioEngine
    let target: AudioEngine.Target
    
    // Remembers the volume before the user clicked Mute
    @State private var preMuteVolume: Double = 0.5

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // App Name & Close Button
            HStack {
                if let icon = target.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 20, height: 20)
                } else {
                    // Fallback icon just in case macOS can't find it
                    Image(systemName: "app.dashed")
                        .resizable()
                        .frame(width: 20, height: 20)
                        .foregroundColor(.secondary)
                }
                Text(target.displayName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                
                Spacer()
                
                Button(action: { engine.removeTarget(pid: target.pid) }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .focusable(false)
            }

            // Controls Row (Meter, Mute, Slider, Percentage)
            HStack(spacing: 12) {
                
                // 1. The VU Meter
                VUMeterView(level: target.level)
                
                // 2. Mute Button
                Button(action: {
                    if !target.isMuted {
                        // About to mute: Save current volume if it's not already 0
                        if target.volume > 0.001 {
                            preMuteVolume = Double(target.volume)
                        }
                        // Crush volume to 0 and mute
                        engine.setVolume(pid: target.pid, volume: 0.0)
                        engine.setMuted(pid: target.pid, muted: true)
                    } else {
                        // About to unmute: Restore the old volume
                        engine.setMuted(pid: target.pid, muted: false)
                        if target.volume <= 0.001 {
                            // Fallback to 50% if the preMuteVolume was somehow 0
                            let restoreVol = preMuteVolume > 0.001 ? preMuteVolume : 0.5
                            engine.setVolume(pid: target.pid, volume: Float(restoreVol))
                        }
                    }
                }) {
                    Image(systemName: target.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundColor(target.isMuted ? .red : .primary)
                        .frame(width: 20)
                }
                .buttonStyle(.plain)
                .focusable(false)

                // 3. Volume Slider
                Slider(
                    value: Binding(
                        get: { Double(target.volume) },
                        set: { newValue in
                            engine.setVolume(pid: target.pid, volume: Float(newValue))
                            
                            // If user drags slider down to 0, activate Mute
                            if newValue <= 0.001 && !target.isMuted {
                                engine.setMuted(pid: target.pid, muted: true)
                            }
                            // If user drags slider up from 0, deactivate Mute
                            else if newValue > 0.001 && target.isMuted {
                                engine.setMuted(pid: target.pid, muted: false)
                            }
                        }
                    ),
                    in: 0...1
                )
                .tint(target.isMuted ? .gray : .blue)
                
                // 4. Percentage Text
                Text("\(Int(target.volume * 100))%")
                    .monospacedDigit()
                    .font(.caption)
                    .frame(width: 35, alignment: .trailing)
            }
            .frame(height: 24)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
    }
}
