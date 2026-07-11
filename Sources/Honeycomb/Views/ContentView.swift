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
                    // Lattice — the map is the status display; no text strip
                    HoneycombCanvas(
                        nodes: monitor.nodes,
                        selectedID: monitor.selectedNodeID,
                        onSelect: { monitor.select($0) }
                    )
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
                        .foregroundStyle(LabTheme.phosphorDim)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("\(monitor.onlineCount)/\(monitor.nodes.count) NODES · " +
                     (monitor.gatewayOK ? "GW ● :4000" : "GW ○ DOWN"))
                    .font(LabTheme.monoSmall)
                    .foregroundStyle(monitor.gatewayOK ? LabTheme.phosphor : LabTheme.alert)
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
}
