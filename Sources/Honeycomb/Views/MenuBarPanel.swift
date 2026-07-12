import SwiftUI

/// Green honeycomb-styled menu bar dropdown panel.
struct MenuBarPanel: View {
    @Bindable var monitor: HealthMonitor
    var onOpenMain: () -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(LabTheme.stroke.opacity(0.8))

            VStack(alignment: .leading, spacing: 6) {
                ForEach(monitor.nodes) { node in
                    nodeRow(node)
                }
            }
            .padding(10)

            Divider().overlay(LabTheme.stroke.opacity(0.8))

            HStack(spacing: 8) {
                menuButton("RESCAN") {
                    Task { await monitor.refreshAll() }
                }
                menuButton("OPEN LAB") {
                    onOpenMain()
                }
                Spacer(minLength: 0)
                menuButton("QUIT") {
                    onQuit()
                }
            }
            .padding(10)
        }
        .frame(width: 280)
        .background(LabTheme.bg)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(LabTheme.phosphor.opacity(0.35), lineWidth: 1)
        )
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 10) {
            HexMark(size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("HONEYCOMB")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(LabTheme.phosphor)
                Text(monitor.gatewayOK ? "GW ● :4000" : "GW ○ offline")
                    .font(LabTheme.monoTiny)
                    .foregroundStyle(monitor.gatewayOK ? LabTheme.phosphorDim : LabTheme.alert)
            }
            Spacer()
            Text("\(monitor.onlineCount)/\(monitor.nodes.count)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(LabTheme.phosphorDim)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(LabTheme.panel)
    }

    private func nodeRow(_ node: LabNode) -> some View {
        Button {
            monitor.select(node.id)
            onOpenMain()
        } label: {
            HStack(spacing: 8) {
                Text(node.health.glyph)
                    .foregroundStyle(node.isStreaming ? LabTheme.phosphor : node.health.color)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text(node.name)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(node.isStreaming ? LabTheme.phosphor : LabTheme.text)
                        if node.isStreaming {
                            Text("LIT")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundStyle(LabTheme.phosphor)
                        }
                    }
                    Text(Privacy.scrub(node.pathBadge) + " · " + node.roleShort)
                        .font(LabTheme.monoTiny)
                        .foregroundStyle(LabTheme.textMuted)
                }
                Spacer()
                if !node.models.isEmpty {
                    Text(short(node.models[0]))
                        .font(LabTheme.monoTiny)
                        .foregroundStyle(LabTheme.textMuted)
                        .lineLimit(1)
                        .frame(maxWidth: 90, alignment: .trailing)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(node.isStreaming ? LabTheme.phosphor.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func menuButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(LabTheme.phosphor)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(LabTheme.phosphor.opacity(0.45), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func short(_ id: String) -> String {
        let base = id.split(separator: "/").last.map(String.init) ?? id
        return base.count > 14 ? String(base.prefix(12)) + "…" : base
    }
}

/// Small honeycomb mark for menu / branding.
struct HexMark: View {
    var size: CGFloat = 24

    var body: some View {
        Canvas { context, sz in
            let s = min(sz.width, sz.height)
            let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
            let cellR = s * 0.22
            let spacing = cellR * 1.1
            let cells: [(Int, Int)] = [(0, 0), (1, 0), (-1, 0), (0, 1), (0, -1)]
            for cell in cells {
                let q = CGFloat(cell.0)
                let r = CGFloat(cell.1)
                let x = spacing * (CGFloat(3).squareRoot() * q + CGFloat(3).squareRoot() / 2 * r)
                let y = spacing * (1.5 * r)
                let center = CGPoint(x: c.x + x, y: c.y + y)
                let radius = cellR * 0.85
                var path = Path()
                for i in 0..<6 {
                    let angle = (Double(i) * 60.0 - 30.0) * .pi / 180.0
                    let pt = CGPoint(
                        x: center.x + radius * CGFloat(cos(angle)),
                        y: center.y + radius * CGFloat(sin(angle))
                    )
                    if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                }
                path.closeSubpath()
                let isCenter = cell.0 == 0 && cell.1 == 0
                context.stroke(
                    path,
                    with: .color(LabTheme.phosphor.opacity(isCenter ? 1 : 0.55)),
                    lineWidth: isCenter ? 1.4 : 0.9
                )
                if isCenter {
                    context.fill(path, with: .color(LabTheme.phosphor.opacity(0.25)))
                }
            }
        }
        .frame(width: size, height: size)
    }
}
