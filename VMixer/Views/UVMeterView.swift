//
//  VUMeterView.swift
//  VMixer
//
//  Created by Rohan Abraham on 5/2/26.
//

import SwiftUI

struct VUMeterView: View {
    var level: Float 
    
    // Customization: Tweak these to change the look
    let segmentCount = 20
    let spacing: CGFloat = 1.0

    var body: some View {
        GeometryReader { geo in
            // Calculate how tall each little LED block should be
            let totalSpacing = CGFloat(segmentCount - 1) * spacing
            let segmentHeight = max(0, (geo.size.height - totalSpacing) / CGFloat(segmentCount))
            
            VStack(spacing: spacing) {
                // Reverse the loop so index 0 (lowest volume) is at the bottom of the VStack
                ForEach((0..<segmentCount).reversed(), id: \.self) { index in
                    let segmentThreshold = Float(index + 1) / Float(segmentCount)
                    let isLit = level >= segmentThreshold
                    let segmentColor = colorFor(index: index)
                    
                    RoundedRectangle(cornerRadius: 1)
                        .fill(segmentColor)
                        .opacity(isLit ? 1.0 : 0.15)
                        .frame(height: segmentHeight)
                        .shadow(color: isLit ? segmentColor.opacity(0.6) : .clear, radius: 1, x: 0, y: 0)
                }
            }
            .animation(.easeOut(duration: 0.05), value: level)
        }
        // Force the width to be a tiny, sleek bar
        .frame(width: 5)
    }
    
    // Bottom is green, middle is yellow, top is red
    private func colorFor(index: Int) -> Color {
        let ratio = Float(index) / Float(segmentCount)
        if ratio < 0.65 { return .green }
        if ratio < 0.85 { return .yellow }
        return .red
    }
}
