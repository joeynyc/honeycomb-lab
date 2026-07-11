import SwiftUI

/// Hex lattice background + live node hexes (axial layout).
struct HoneycombCanvas: View {
    let nodes: [LabNode]
    let selectedID: String?
    let onSelect: (String) -> Void

    /// Pixel size of one hex (center to vertex)
    private let hexSize: CGFloat = 52
    private let latticeRadius = 3

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2 - 8)

            ZStack {
                // Ambient glow
                Circle()
                    .fill(LabTheme.phosphor.opacity(0.04))
                    .frame(width: 280, height: 280)
                    .blur(radius: 40)
                    .position(center)

                Canvas { context, size in
                    drawLattice(context: context, center: center)
                }
                .allowsHitTesting(false)

                // Connection edges under nodes; pulses animate toward LIT nodes
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !anyStreaming)) { timeline in
                    Canvas { context, size in
                        drawEdges(
                            context: context,
                            center: center,
                            time: timeline.date.timeIntervalSinceReferenceDate
                        )
                    }
                }
                .allowsHitTesting(false)

                ForEach(nodes) { node in
                    let p = axialToPixel(q: node.axial.q, r: node.axial.r, size: hexSize, origin: center)
                    NodeHexView(
                        node: node,
                        isSelected: node.id == selectedID,
                        size: hexSize
                    )
                    .position(p)
                    .onTapGesture { onSelect(node.id) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Geometry

    private func axialToPixel(q: Int, r: Int, size: CGFloat, origin: CGPoint) -> CGPoint {
        // Pointy-top axial
        let x = size * (sqrt(3) * CGFloat(q) + sqrt(3) / 2 * CGFloat(r))
        let y = size * (3.0 / 2.0 * CGFloat(r))
        return CGPoint(x: origin.x + x, y: origin.y + y)
    }

    private func hexPath(center: CGPoint, size: CGFloat) -> Path {
        var path = Path()
        for i in 0..<6 {
            let angle = (CGFloat(i) * 60 - 30) * .pi / 180
            let pt = CGPoint(
                x: center.x + size * cos(angle),
                y: center.y + size * sin(angle)
            )
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        path.closeSubpath()
        return path
    }

    private var anyStreaming: Bool {
        nodes.contains { $0.isStreaming }
    }

    private func drawLattice(context: GraphicsContext, center: CGPoint) {
        let bgSize = hexSize * 0.92
        for q in -latticeRadius...latticeRadius {
            for r in -latticeRadius...latticeRadius {
                let s = -q - r
                if abs(s) > latticeRadius { continue }
                // Skip centers occupied by real nodes (drawn separately)
                if nodes.contains(where: { $0.axial.q == q && $0.axial.r == r }) { continue }
                let p = axialToPixel(q: q, r: r, size: hexSize, origin: center)
                let path = hexPath(center: p, size: bgSize * 0.78)
                context.stroke(
                    path,
                    with: .color(LabTheme.stroke.opacity(0.5)),
                    lineWidth: 1
                )
            }
        }
    }

    private func drawEdges(context: GraphicsContext, center: CGPoint, time: TimeInterval) {
        // Mini is hub; Sparks peer-linked; 4080 to mini
        let pairs: [(String, String)] = [
            ("mini", "joeydgx"),
            ("mini", "gx10"),
            ("mini", "pc4080"),
            ("joeydgx", "gx10"),
        ]
        for (a, b) in pairs {
            guard let na = nodes.first(where: { $0.id == a }),
                  let nb = nodes.first(where: { $0.id == b })
            else { continue }
            let pa = axialToPixel(q: na.axial.q, r: na.axial.r, size: hexSize, origin: center)
            let pb = axialToPixel(q: nb.axial.q, r: nb.axial.r, size: hexSize, origin: center)
            var path = Path()
            path.move(to: pa)
            path.addLine(to: pb)

            let bothLive = (na.health == .online || na.health == .degraded)
                && (nb.health == .online || nb.health == .degraded)
            let color = bothLive
                ? LabTheme.phosphor.opacity(0.35)
                : LabTheme.strokeDim.opacity(0.6)
            let width: CGFloat = (a == "joeydgx" && b == "gx10") ? 2.2 : 1.2

            context.stroke(path, with: .color(color), lineWidth: width)

            // Traffic pulses travel hub → destination while the node is LIT
            if a == "mini" && nb.isStreaming {
                drawPulses(context: context, from: pa, to: pb, time: time)
            }
        }
    }

    /// Two glowing dots gliding along the edge — traffic direction made visible.
    private func drawPulses(context: GraphicsContext, from: CGPoint, to: CGPoint, time: TimeInterval) {
        for i in 0..<2 {
            let phase = (time * 0.55 + Double(i) * 0.5).truncatingRemainder(dividingBy: 1.0)
            let x = from.x + (to.x - from.x) * phase
            let y = from.y + (to.y - from.y) * phase
            let dot = CGRect(x: x - 3, y: y - 3, width: 6, height: 6)
            context.fill(
                Path(ellipseIn: dot.insetBy(dx: -2, dy: -2)),
                with: .color(LabTheme.phosphor.opacity(0.25))
            )
            context.fill(
                Path(ellipseIn: dot),
                with: .color(LabTheme.phosphor.opacity(0.9))
            )
        }
    }
}

struct NodeHexView: View {
    let node: LabNode
    let isSelected: Bool
    let size: CGFloat

    var body: some View {
        let fillOpacity: Double = {
            switch node.health {
            case .online: return 0.22
            case .degraded: return 0.12
            case .offline: return 0.04
            case .unknown: return 0.06
            }
        }()

        ZStack {
            // Active traffic pulse (gateway-driven)
            if node.isStreaming {
                HexShape()
                    .fill(LabTheme.phosphor.opacity(0.35))
                    .scaleEffect(1.08)
                    .blur(radius: 2)
            }
            HexShape()
                .fill(node.health.color.opacity(node.isStreaming ? 0.35 : fillOpacity))
            // Health lives in the outline color; text stays quiet
            HexShape()
                .stroke(
                    node.isStreaming
                        ? LabTheme.phosphor
                        : (isSelected ? LabTheme.phosphor : node.health.color.opacity(0.75)),
                    lineWidth: node.isStreaming ? 2.8 : (isSelected ? 2.4 : 1.5)
                )
                .shadow(
                    color: node.isStreaming
                        ? LabTheme.phosphor.opacity(0.7)
                        : (isSelected ? LabTheme.phosphor.opacity(0.45) : .clear),
                    radius: node.isStreaming ? 14 : 8
                )

            VStack(spacing: 4) {
                Text(node.name)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(LabTheme.phosphor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(hexSubtitle)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(hexSubtitleColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(10)
        }
        .frame(width: size * 1.7, height: size * 1.7)
        .contentShape(HexShape())
        .scaleEffect(isSelected ? 1.06 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .animation(.easeOut(duration: 0.25), value: node.health)
        .animation(.easeInOut(duration: 0.35), value: node.isStreaming)
    }

    /// One quiet line: traffic beats trouble beats what's serving.
    private var hexSubtitle: String {
        if node.isStreaming { return "LIT" }
        switch node.health {
        case .offline: return "OFFLINE"
        case .degraded: return "DEGRADED"
        case .unknown: return "…"
        case .online:
            if let model = node.models.first {
                let base = model.split(separator: "/").last.map(String.init) ?? model
                return base.count > 14 ? String(base.prefix(12)) + "…" : base
            }
            return node.role.shortLabel
        }
    }

    private var hexSubtitleColor: Color {
        if node.isStreaming { return LabTheme.phosphor }
        switch node.health {
        case .offline: return LabTheme.alert
        case .degraded: return LabTheme.amber
        default: return LabTheme.textMuted
        }
    }
}

struct HexShape: Shape {
    func path(in rect: CGRect) -> Path {
        let size = min(rect.width, rect.height) / 2
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        for i in 0..<6 {
            let angle = (CGFloat(i) * 60 - 30) * .pi / 180
            let pt = CGPoint(x: c.x + size * cos(angle), y: c.y + size * sin(angle))
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        path.closeSubpath()
        return path
    }
}
