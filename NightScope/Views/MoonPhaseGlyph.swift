import SwiftUI

/// 月の欠け方を 8 段階に丸めず連続的に描くアイコン。
struct MoonPhaseGlyph: View {
    let phase: Double
    var isSouthernHemisphere = false
    var size: CGFloat = 24

    var body: some View {
        Canvas { context, canvasSize in
            let radius = Double(min(canvasSize.width, canvasSize.height)) / 2
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            let disc = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.fill(Circle().path(in: disc), with: .color(.secondary.opacity(0.25)))

            let points = Self.litPoints(phase: phase, isSouthern: isSouthernHemisphere, center: center, radius: radius)
            guard let first = points.first else { return }
            var lit = Path()
            lit.move(to: first)
            for point in points.dropFirst() {
                lit.addLine(to: point)
            }
            lit.closeSubpath()
            context.fill(lit, with: .color(Self.litColor))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private static let litColor = Color(red: 1.0, green: 0.93, blue: 0.68)

    /// 輝面の多角形。北半球の見え方（満ちる月は右が光る）を基準に、南半球では左右を反転する。
    static func litPoints(phase: Double, isSouthern: Bool, center: CGPoint, radius: Double) -> [CGPoint] {
        let points = MoonPhase.litPolygon(center: center, radius: radius, phase: phase)
        guard isSouthern else { return points }
        return points.map { CGPoint(x: 2 * center.x - $0.x, y: $0.y) }
    }
}

#Preview {
    HStack {
        ForEach([0.05, 0.25, 0.4, 0.5, 0.6, 0.75, 0.9], id: \.self) { phase in
            MoonPhaseGlyph(phase: phase, size: 32)
        }
    }
    .padding()
}
