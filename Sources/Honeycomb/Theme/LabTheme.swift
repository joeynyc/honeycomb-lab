import SwiftUI

enum LabTheme {
    /// Near-black CRT
    static let bg = Color(red: 0.04, green: 0.055, blue: 0.04)
    static let bgElevated = Color(red: 0.06, green: 0.08, blue: 0.06)
    /// Solid panel — no desktop bleed-through
    static let panel = Color(red: 0.045, green: 0.065, blue: 0.045)

    /// Phosphor green (title / online)
    static let phosphor = Color(red: 0.49, green: 1.0, blue: 0.23)
    static let phosphorDim = Color(red: 0.29, green: 0.55, blue: 0.18)

    /// Amber honeycomb strokes
    static let amber = Color(red: 0.77, green: 0.64, blue: 0.35)
    static let amberDim = Color(red: 0.45, green: 0.38, blue: 0.22)

    static let dim = Color(red: 0.29, green: 0.42, blue: 0.29)
    static let text = Color(red: 0.72, green: 0.92, blue: 0.62)
    static let textMuted = Color(red: 0.35, green: 0.48, blue: 0.35)
    static let alert = Color(red: 1.0, green: 0.27, blue: 0.4)

    static let mono: Font = .system(.body, design: .monospaced)
    static let monoSmall: Font = .system(size: 11, weight: .regular, design: .monospaced)
    static let monoTiny: Font = .system(size: 9, weight: .medium, design: .monospaced)
    static let titleBlock: Font = .system(size: 28, weight: .bold, design: .monospaced)
}

struct CRTBackground: View {
    var body: some View {
        ZStack {
            LabTheme.bg
            // soft vignette
            RadialGradient(
                colors: [
                    Color.clear,
                    Color.black.opacity(0.55)
                ],
                center: .center,
                startRadius: 80,
                endRadius: 520
            )
            // scanlines
            Canvas { context, size in
                let step: CGFloat = 3
                var y: CGFloat = 0
                while y < size.height {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(
                        path,
                        with: .color(.black.opacity(0.12)),
                        lineWidth: 1
                    )
                    y += step
                }
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}
