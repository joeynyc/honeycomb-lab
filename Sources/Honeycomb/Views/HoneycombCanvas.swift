import SwiftUI

/// Hex lattice background + live node hexes (axial layout).
struct HoneycombCanvas: View {
    let nodes: [LabNode]
    /// Extra edges from fleet.json, beyond the implicit hub→node spokes
    var extraLinks: [(String, String)] = []
    let selectedID: String?
    let onSelect: (String) -> Void

    /// Pixel size of one hex (center to vertex) — shrinks so a growing fleet
    /// always fits the window instead of spilling off-canvas.
    private func hexSize(for size: CGSize) -> CGFloat {
        let extent = nodes.reduce(1) { acc, node in
            max(acc, abs(node.axial.q), abs(node.axial.r), abs(node.axial.q + node.axial.r))
        }
        // Width of the layout in hex-size units, plus a hex of margin
        let unitsWide = CGFloat(extent) * 2.0 * 1.732 + 3.2
        let unitsTall = CGFloat(extent) * 3.0 + 3.4
        let fitted = min(size.width / unitsWide, size.height / unitsTall)
        return max(26, min(52, fitted))
    }

    private var latticeRadius: Int {
        let extent = nodes.reduce(1) { acc, node in
            max(acc, abs(node.axial.q), abs(node.axial.r), abs(node.axial.q + node.axial.r))
        }
        return min(5, max(3, extent + 1))
    }

    /// Offset that centres the *nodes* in the view, not the axial origin —
    /// otherwise a lopsided fleet drifts to one side.
    private func clusterOffset(hexSize: CGFloat) -> CGPoint {
        guard !nodes.isEmpty else { return .zero }
        let points = nodes.map {
            axialToPixel(q: $0.axial.q, r: $0.axial.r, size: hexSize, origin: .zero)
        }
        let minX = points.map(\.x).min() ?? 0, maxX = points.map(\.x).max() ?? 0
        let minY = points.map(\.y).min() ?? 0, maxY = points.map(\.y).max() ?? 0
        return CGPoint(x: -(minX + maxX) / 2, y: -(minY + maxY) / 2)
    }

    var body: some View {
        GeometryReader { geo in
            let hexSize = hexSize(for: geo.size)
            let shift = clusterOffset(hexSize: hexSize)
            let center = CGPoint(
                x: geo.size.width / 2 + shift.x,
                y: geo.size.height / 2 - 8 + shift.y
            )

            ZStack {
                // Ambient glow
                Circle()
                    .fill(LabTheme.phosphor.opacity(0.04))
                    .frame(width: 280, height: 280)
                    .blur(radius: 40)
                    .position(center)

                Canvas { context, size in
                    drawLattice(context: context, center: center, hexSize: hexSize)
                }
                .allowsHitTesting(false)

                // Connection edges under nodes; pulses animate toward LIT nodes
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !anyStreaming)) { timeline in
                    Canvas { context, size in
                        drawEdges(
                            context: context,
                            center: center,
                            hexSize: hexSize,
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

    private func drawLattice(context: GraphicsContext, center: CGPoint, hexSize: CGFloat) {
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

    /// Hub → every other node, plus explicit fleet.json links.
    private var edgePairs: [(String, String)] {
        var pairs: [(String, String)] = []
        if let hub = nodes.first(where: { $0.isHub }) {
            for node in nodes where node.id != hub.id {
                pairs.append((hub.id, node.id))
            }
        }
        for (a, b) in extraLinks
        where !pairs.contains(where: { ($0.0 == a && $0.1 == b) || ($0.0 == b && $0.1 == a) }) {
            pairs.append((a, b))
        }
        return pairs
    }

    private func drawEdges(context: GraphicsContext, center: CGPoint, hexSize: CGFloat, time: TimeInterval) {
        let hubID = nodes.first(where: { $0.isHub })?.id
        for (a, b) in edgePairs {
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
            // Explicit (non-spoke) links draw heavier
            let isSpoke = a == hubID || b == hubID
            let width: CGFloat = isSpoke ? 1.2 : 2.2

            context.stroke(path, with: .color(color), lineWidth: width)

            // Traffic pulses travel hub → destination while the node is LIT
            if a == hubID && nb.isStreaming {
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
                    .font(.system(size: max(9, size * 0.23), weight: .bold, design: .monospaced))
                    .foregroundStyle(LabTheme.phosphor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(hexSubtitle)
                    .font(.system(size: max(7, size * 0.19), weight: .medium, design: .monospaced))
                    .foregroundStyle(hexSubtitleColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(size * 0.18)
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
            return node.roleShort
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
