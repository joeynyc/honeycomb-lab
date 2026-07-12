import SwiftUI

struct ContentView: View {
    @Bindable var monitor: HealthMonitor
    @AppStorage("showFeed") private var showFeed = true
    /// Redacts addresses/hostnames for screenshots, demos, and projectors.
    @AppStorage("privacyMode") private var privacyMode = false

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
                            if !monitor.gatewayOK {
                                gatewayDownHint
                            } else if monitor.nodes.isEmpty {
                                emptyFleetHint
                            }
                        }
                        .overlay(alignment: .bottomLeading) {
                            let issues = monitor.fleet.problems
                                + [monitor.history.storageError].compactMap { $0 }
                            if !issues.isEmpty {
                                problemPanel(issues)
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

    /// Config and storage problems must never be silent — a dropped node or a
    /// history that never persists would otherwise just look like nothing.
    private func problemPanel(_ issues: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("CONFIG · \(issues.count) ISSUE\(issues.count == 1 ? "" : "S")")
                .font(LabTheme.monoTiny)
                .tracking(1)
                .foregroundStyle(LabTheme.amber)
            ForEach(issues.prefix(4), id: \.self) { problem in
                Text("· \(problem)")
                    .font(LabTheme.monoTiny)
                    .foregroundStyle(LabTheme.textMuted)
                    .lineLimit(2)
            }
            if issues.count > 4 {
                Text("+ \(issues.count - 4) more")
                    .font(LabTheme.monoTiny)
                    .foregroundStyle(LabTheme.dim)
            }
        }
        .padding(10)
        .frame(maxWidth: 420, alignment: .leading)
        .background(LabTheme.panel.opacity(0.95))
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(LabTheme.amberDim, lineWidth: 1)
        )
        .padding(10)
    }

    private func toggleChip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(LabTheme.monoTiny)
                .tracking(1)
                .foregroundStyle(on ? LabTheme.phosphor : LabTheme.textMuted)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(on ? LabTheme.phosphor.opacity(0.5) : LabTheme.stroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    /// The gateway is the engine — if it's down, nothing else is meaningful.
    /// A downloaded .app can start its own bundled copy right here.
    private var gatewayDownHint: some View {
        VStack(spacing: 10) {
            Text("GATEWAY NOT RUNNING")
                .font(LabTheme.monoSmall.weight(.bold))
                .tracking(2)
                .foregroundStyle(LabTheme.alert)
            Text("The map and node control need the gateway on :4000.")
                .font(LabTheme.monoSmall)
                .foregroundStyle(LabTheme.textMuted)

            if monitor.launcher.canStart {
                Button {
                    Task {
                        await monitor.launcher.start()
                        await monitor.refreshAll()
                    }
                } label: {
                    Text(monitor.launcher.isStarting ? "STARTING…" : "START GATEWAY")
                        .font(LabTheme.monoTiny)
                        .tracking(1)
                        .foregroundStyle(LabTheme.bg)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(LabTheme.phosphor)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                }
                .buttonStyle(.plain)
                .disabled(monitor.launcher.isStarting)
            } else if let reason = monitor.launcher.blockedReason {
                Text(reason)
                    .font(LabTheme.monoTiny)
                    .foregroundStyle(LabTheme.amber)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            if let err = monitor.launcher.lastError {
                Text(err)
                    .font(LabTheme.monoTiny)
                    .foregroundStyle(LabTheme.alert)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
        }
        .padding(24)
        .background(LabTheme.panel.opacity(0.96))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(LabTheme.stroke, lineWidth: 1)
        )
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

            HStack(spacing: 8) {
                toggleChip("FEED", on: showFeed) { showFeed.toggle() }
                toggleChip("PRIVACY", on: privacyMode) { privacyMode.toggle() }
            }
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
