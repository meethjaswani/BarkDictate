// Renders the README's demo images from the app's own island views (RecordingDot, Waveform).

import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

private struct DemoScene: View {
    let island: IslandModel
    let pulse: CGFloat
    let typed: String
    let cursor: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color(red: 0.16, green: 0.17, blue: 0.29)
            Color.black.opacity(0.25).frame(height: 32)
            HStack {
                RecordingDot(model: island, frozenPulse: pulse)
                Spacer()
                Waveform(model: island)
            }
            .padding(.horizontal, 14)
            .frame(width: 290, height: 32)
            .background(UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14).fill(.black))
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 7) {
                    ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.85)).frame(width: 11, height: 11) }
                    Spacer()
                    Text("Notes").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                }
                (Text(typed) + Text(cursor ? "|" : " ").foregroundColor(.accentColor))
                    .font(.system(size: 17))
                    .foregroundStyle(.white)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
            }
            .padding(18)
            .frame(width: 560, height: 180)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.13)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.08)))
            .padding(.top, 92)
        }
        .frame(width: 720, height: 320)
        .environment(\.colorScheme, .dark)
    }
}

private struct IslandCloseup: View {
    let island: IslandModel
    let pulse: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            Color(red: 0.16, green: 0.17, blue: 0.29)
            Color.black.opacity(0.25).frame(height: 32)
            HStack {
                RecordingDot(model: island, frozenPulse: pulse)
                Spacer()
                Waveform(model: island)
            }
            .padding(.horizontal, 14)
            .frame(width: 290, height: 32)
            .background(UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14).fill(.black))
        }
        .frame(width: 420, height: 64)
    }
}

@MainActor
private func image(_ view: some View, scale: CGFloat) -> CGImage {
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    return renderer.cgImage!
}

@MainActor
func renderDemo(to dir: URL) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let island = IslandModel()

    // Live text as the app produced it for a test clip: words appear, then get revised.
    let steps = [
        "", "So I was think", "So I was thinking about", "So I was thinking about the project",
        "So I was thinking about the project time", "So I was thinking about the project timeline",
        "So I was thinking about the project timeline and I believe we",
        "So I was thinking about the project timeline, and I believe we should move the",
        "So I was thinking about the project timeline, and I believe we should move the launch to next",
        "So I was thinking about the project timeline, and I believe we should move the launch to next Thursday.",
    ]
    var frames: [(CGImage, Double)] = []
    var t = 0.0
    for (i, text) in steps.enumerated() {
        for k in 0..<4 {
            t += 0.1
            let speaking = i > 0
            let v = speaking ? 0.35 + 0.35 * sin(t * 9) * sin(t * 2.3) + Double.random(in: 0...0.3) : 0.02
            island.push(Float(max(0, v) / 14))
            let pulse = CGFloat((t.truncatingRemainder(dividingBy: 1.1)) / 1.1)
            frames.append((image(DemoScene(island: island, pulse: pulse, typed: text, cursor: k < 2), scale: 1.5), 0.1))
        }
    }
    island.phase = .done
    frames.append((image(DemoScene(island: island, pulse: 0, typed: steps.last!, cursor: false), scale: 1.5), 2.0))

    let gifURL = dir.appendingPathComponent("demo.gif")
    let dest = CGImageDestinationCreateWithURL(gifURL as CFURL, UTType.gif.identifier as CFString, frames.count, nil)!
    CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for (frame, delay) in frames {
        CGImageDestinationAddImage(dest, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
    }
    CGImageDestinationFinalize(dest)

    // Close-ups of the island: listening and done.
    func png(_ view: some View, _ name: String) {
        let rep = NSBitmapImageRep(cgImage: image(view, scale: 3))
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
    }
    island.phase = .listening
    for _ in 0..<14 { island.push(Float(Double.random(in: 0.2...0.9) / 14)) }
    png(IslandCloseup(island: island, pulse: 0.3), "island-listening.png")
    island.phase = .done
    png(IslandCloseup(island: island, pulse: 0), "island-done.png")
    print("Rendered \(frames.count) GIF frames and 2 stills to \(dir.path)")
}
