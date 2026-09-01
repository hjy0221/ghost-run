// Reproducible, code-native placeholder matching the in-game Ghost silhouette.
// Run: swiftc -parse-as-library Tools/RenderGhostIcon.swift -o /tmp/render-ghost-icon
// Then: /tmp/render-ghost-icon <output.png>
import AppKit
import SwiftUI

private struct Hood: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.width * 0.12, y: r.height))
        p.addLine(to: CGPoint(x: r.width * 0.15, y: r.height * 0.43))
        p.addQuadCurve(to: CGPoint(x: r.midX, y: 0), control: CGPoint(x: r.width * 0.1, y: 0))
        p.addQuadCurve(to: CGPoint(x: r.width * 0.85, y: r.height * 0.43), control: CGPoint(x: r.width * 0.9, y: 0))
        p.addLine(to: CGPoint(x: r.width * 0.88, y: r.height))
        p.addLine(to: CGPoint(x: r.width * 0.62, y: r.height * 0.84))
        p.addLine(to: CGPoint(x: r.midX, y: r.height))
        p.addLine(to: CGPoint(x: r.width * 0.38, y: r.height * 0.84))
        p.closeSubpath()
        return p
    }
}

private struct GhostIcon: View {
    var body: some View {
        ZStack {
            Color(red: 0.025, green: 0.03, blue: 0.07)
            Circle().stroke(Color.purple.opacity(0.25), lineWidth: 4).frame(width: 780, height: 780)
            Circle().stroke(Color.purple.opacity(0.5), lineWidth: 8).frame(width: 680, height: 680)
            Hood()
                .fill(LinearGradient(colors: [Color.white, Color(red: 0.61, green: 0.5, blue: 0.9)], startPoint: .top, endPoint: .bottom))
                .frame(width: 510, height: 570)
                .shadow(color: .purple.opacity(0.45), radius: 36)
            HStack(spacing: 64) {
                Capsule().frame(width: 47, height: 86)
                Capsule().frame(width: 47, height: 86)
            }
            .foregroundStyle(Color(red: 0.025, green: 0.03, blue: 0.07))
            .offset(y: -36)
        }
        .frame(width: 1024, height: 1024)
    }
}

@main
struct RenderGhostIcon {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Supply an output PNG path") }
        let renderer = ImageRenderer(content: GhostIcon())
        renderer.isOpaque = true
        guard let image = renderer.cgImage else { fatalError("Render failed") }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG failed") }
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
