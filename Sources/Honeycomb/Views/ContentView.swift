import SwiftUI

struct ContentView: View {
    @Bindable var monitor: HealthMonitor
    @AppStorage("showFeed") private var showFeed = true

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
                    VStack(spacing: 10) {
                        HoneycombCanvas(
                            nodes: monitor.nodes,
                            extraLinks: monitor.fleet.links,
                            selectedID: monitor.selectedNodeID,
                            onSelect: { monitor.select($0) }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay {
                            if monitor.nodes.isEmpty {
                                emptyFleetHint
                            }
                        }

                        if showFeed {
                            TrafficFeed(feed: monitor.feed)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Inspector only — full height, no chat
                    NodeInspector(
                        node: monitor.selectedNode,
                        history: monitor.history,
                        control: monitor.control,
                        doctor: monitor.doctor,
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

    /// First-run guidance when fleet.json is missing, empty, or malformed.
    private var emptyFleetHint: some View {
        VStack(spacing: 8) {
            Text("NO NODES CONFIGURED")
                .font(LabTheme.monoSmall.weight(.bold))
                .tracking(2)
                .foregroundStyle(LabTheme.phosphor)
            Text("Edit the fleet definition and relaunch:")
                .font(LabTheme.monoSmall)
                .foregroundStyle(LabTheme.textMuted)
            Text("~/Library/Application Support/Honeycomb/fleet.json")
                .font(LabTheme.monoSmall)
                .foregroundStyle(LabTheme.text)
                .textSelection(.enabled)
            Text("See fleet.example.json in the repo for the format.")
                .font(LabTheme.monoTiny)
                .foregroundStyle(LabTheme.textMuted)
        }
        .padding(22)
        .background(LabTheme.panel.opacity(0.95))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(LabTheme.stroke, lineWidth: 1)
        )
    }

    private var topBar: some View {
        HStack(alignment: .center) {
            HStack(spacing: 12) {
                HexMark(size: 36)
                    .shadow(color: LabTheme.phosphor.opacity(0.4), radius: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(monitor.fleet.title)
                        .font(.system(size: 26, weight: .heavy, design: .monospaced))
                        .foregroundStyle(LabTheme.phosphor)
                        .shadow(color: LabTheme.phosphor.opacity(0.35), radius: 10)
                    Text(monitor.nodes.map { $0.name.uppercased() }.joined(separator: "  ·  "))
                        .font(LabTheme.monoTiny)
                        .tracking(2)
                        .foregroundStyle(LabTheme.phosphorDim)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button {
                showFeed.toggle()
            } label: {
                Text("FEED")
                    .font(LabTheme.monoTiny)
                    .tracking(1)
                    .foregroundStyle(showFeed ? LabTheme.phosphor : LabTheme.textMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(
                                showFeed ? LabTheme.phosphor.opacity(0.5) : LabTheme.stroke,
                                lineWidth: 1
                            )
                    )
            }
            .buttonStyle(.plain)
            .padding(.trailing, 14)

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
