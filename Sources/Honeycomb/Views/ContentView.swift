import SwiftUI

struct ContentView: View {
    @Bindable var monitor: HealthMonitor

    var body: some View {
        ZStack {
            CRTBackground()

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 10)

                HStack(alignment: .top, spacing: 14) {
                    // Lattice
                    VStack(spacing: 10) {
                        HoneycombCanvas(
                            nodes: monitor.nodes,
                            selectedID: monitor.selectedNodeID,
                            onSelect: { monitor.select($0) }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        fleetStrip
                            .padding(.bottom, 4)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Inspector only — full height, no chat
                    NodeInspector(
                        node: monitor.selectedNode,
                        onRefresh: {
                            Task { await monitor.refreshAll() }
                        },
                        onSSH: {
                            if let n = monitor.selectedNode {
                                monitor.openSSH(n)
                            }
                        }
                    )
                    .frame(width: 360)
                    .frame(maxHeight: .infinity)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
        }
        .frame(minWidth: 960, minHeight: 620)
        .preferredColorScheme(.dark)
    }

    private var topBar: some View {
        HStack(alignment: .center) {
            HStack(spacing: 12) {
                HexMark(size: 36)
                    .shadow(color: LabTheme.phosphor.opacity(0.4), radius: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text("HONEYCOMB")
                        .font(.system(size: 26, weight: .heavy, design: .monospaced))
                        .foregroundStyle(LabTheme.phosphor)
                        .shadow(color: LabTheme.phosphor.opacity(0.35), radius: 10)
                    Text("LAB  ·  JOEYDGX  ·  GX10  ·  4080  ·  MINI")
                        .font(LabTheme.monoTiny)
                        .tracking(2)
                        .foregroundStyle(LabTheme.amber)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("\(monitor.onlineCount)/\(monitor.nodes.count) NODES LIVE")
                    .font(LabTheme.monoSmall)
                    .foregroundStyle(LabTheme.phosphor)
                Text(monitor.gatewayOK ? "GATEWAY ● :4000" : "GATEWAY ○ down")
                    .font(LabTheme.monoTiny)
                    .foregroundStyle(monitor.gatewayOK ? LabTheme.phosphorDim : LabTheme.alert)
                Text(monitor.gatewayDetail)
                    .font(LabTheme.monoTiny)
                    .foregroundStyle(LabTheme.dim)
                    .lineLimit(1)
                Text(monitor.statusLine)
                    .font(LabTheme.monoTiny)
                    .foregroundStyle(LabTheme.textMuted)
                HStack(spacing: 6) {
                    if monitor.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                    }
                    if let t = monitor.lastFullRefresh {
                        Text("scan \(t.formatted(date: .omitted, time: .standard))")
                            .font(LabTheme.monoTiny)
                            .foregroundStyle(LabTheme.dim)
                    }
                }
            }
        }
    }

    /// Compact truthful status for all nodes under the lattice
    private var fleetStrip: some View {
        HStack(spacing: 12) {
            ForEach(monitor.nodes) { node in
                Button {
                    monitor.select(node.id)
                } label: {
                    HStack(spacing: 5) {
                        Text(node.health.glyph)
                            .foregroundStyle(node.health.color)
                        Text(node.name)
                            .foregroundStyle(
                                node.id == monitor.selectedNodeID
                                    ? LabTheme.phosphor
                                    : LabTheme.textMuted
                            )
                        if node.isStreaming {
                            Text("LIT")
                                .foregroundStyle(LabTheme.phosphor)
                        } else if !node.models.isEmpty {
                            Text(short(node.models[0]))
                                .foregroundStyle(LabTheme.amber.opacity(0.75))
                                .lineLimit(1)
                        }
                    }
                    .font(LabTheme.monoTiny)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 2)
                            .fill(LabTheme.panel.opacity(0.9))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(
                                node.id == monitor.selectedNodeID
                                    ? LabTheme.phosphor.opacity(0.45)
                                    : LabTheme.amberDim.opacity(0.3),
                                lineWidth: 1
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func short(_ id: String) -> String {
        let base = id.split(separator: "/").last.map(String.init) ?? id
        return base.count > 18 ? String(base.prefix(15)) + "…" : base
    }
}
