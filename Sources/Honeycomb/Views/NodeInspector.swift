import SwiftUI

struct NodeInspector: View {
    let node: LabNode?
    var history: HealthHistory?
    var control: NodeControl?
    let onRefresh: () -> Void
    let onSSH: () -> Void
    @State private var ping = PingService()
    @State private var pendingAction: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider().overlay(LabTheme.stroke.opacity(0.8))
            if let node {
                detail(node)
            } else {
                Text("Select a hex")
                    .font(LabTheme.monoSmall)
                    .foregroundStyle(LabTheme.textMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LabTheme.panel)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(LabTheme.stroke.opacity(0.9), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack {
            Text("NODE // INSPECT")
                .font(LabTheme.monoTiny)
                .tracking(2)
                .foregroundStyle(LabTheme.phosphorDim)
            Spacer()
            Button(action: onRefresh) {
                Text("↻ SCAN")
                    .font(LabTheme.monoTiny)
                    .foregroundStyle(LabTheme.phosphor)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func detail(_ node: LabNode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(node.name)
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundStyle(LabTheme.phosphor)
                Spacer()
                Text(node.role.rawValue)
                    .font(LabTheme.monoTiny)
                    .foregroundStyle(LabTheme.phosphorDim)
            }

            row("HOST", "\(node.hostname) · \(node.hostAddress)")
            row("ROLE", node.role.rawValue)
            row("HEALTH", "\(node.health.glyph) \(node.health.rawValue.uppercased())")
            row("PATH", node.pathBadge)
            if node.id == "pc4080" {
                row("LINK", node.dashboardOK ? "ZeroCool · LM Link connected" : "LM Link peer not seen")
                row("SSH", (node.sshHost ?? "zerocool") + (node.sshOK ? " · ok" : " · down"))
            } else {
                if let ssh = node.sshHost {
                    row("SSH", ssh + (node.sshOK ? " · ok" : " · down"))
                }
                if node.dashboardURL != nil {
                    row("SYNC", node.dashboardOK ? "dashboard tunnel ok" : "no dashboard tunnel")
                }
            }
            if node.id == "mini" {
                row("INFER", node.inferenceOK
                    ? "LM Studio · \(node.baseURL.absoluteString)"
                    : "LM Studio server off (lms server start)")
            } else if node.id == "pc4080" {
                row("INFER", node.inferenceOK
                    ? "API via Mini LMS · \(node.baseURL.absoluteString)"
                    : "no chat API yet (load model on PC / start LMS on Mini)")
            } else {
                row("INFER", node.inferenceOK
                    ? "vLLM · \(node.baseURL.absoluteString)"
                    : "idle (no vLLM on :8000)")
            }
            if !node.statusDetail.isEmpty {
                row("LINKS", node.statusDetail)
            }
            if let ms = node.latencyMs {
                row("LATENCY", String(format: "%.0f ms", ms))
            }
            if let m = node.metrics {
                if let gpu = m.gpuUtilPct {
                    metricRow("GPU", "\(gpu)%", fraction: Double(gpu) / 100)
                }
                if let used = m.memUsedMB, let total = m.memTotalMB, total > 0 {
                    metricRow(
                        "MEM",
                        String(format: "%.0f / %.0f GB", Double(used) / 1024, Double(total) / 1024),
                        fraction: Double(used) / Double(total)
                    )
                }
                if let kv = m.kvCachePct {
                    metricRow("KV CACHE", String(format: "%.0f%%", kv), fraction: kv / 100)
                }
                if let running = m.runningRequests, running > 0 {
                    row("ACTIVE", "\(running) request\(running == 1 ? "" : "s")")
                }
                if let tps = m.genTokPerSec, tps > 0.05 {
                    row("THRUPUT", String(format: "%.1f tok/s", tps))
                }
            }
            if let err = node.lastError {
                row("NOTE", err)
            }
            if let t = node.lastChecked {
                row("CHECKED", t.formatted(date: .omitted, time: .standard))
            }
            if let changed = history?.lastChange[node.id] {
                row("CHANGED", changed.formatted(.relative(presentation: .named)))
            }
            if let series = history?.latencySeries(nodeID: node.id),
               series.count > 4, series.contains(where: { $0 > 0 }) {
                HStack(alignment: .center, spacing: 8) {
                    Text("TREND")
                        .font(LabTheme.monoTiny)
                        .foregroundStyle(LabTheme.textMuted)
                        .frame(width: 64, alignment: .leading)
                    Sparkline(values: series)
                        .frame(height: 18)
                }
            }

            Text(node.id == "mini" || node.id == "pc4080" ? "LOADED MODELS" : "SERVING MODELS")
                .font(LabTheme.monoTiny)
                .foregroundStyle(LabTheme.phosphorDim)
                .padding(.top, 4)

            if node.models.isEmpty {
                Text(node.displayModel)
                    .font(LabTheme.monoSmall)
                    .foregroundStyle(LabTheme.textMuted)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(node.models.prefix(8), id: \.self) { m in
                            Text("· \(m)")
                                .font(LabTheme.monoSmall)
                                .foregroundStyle(LabTheme.text)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if node.models.count > 8 {
                            Text("+ \(node.models.count - 8) more serving")
                                .font(LabTheme.monoTiny)
                                .foregroundStyle(LabTheme.textMuted)
                        }
                    }
                }
                .frame(maxHeight: 120)
            }

            Text(node.notes)
                .font(LabTheme.monoTiny)
                .foregroundStyle(LabTheme.textMuted)
                .padding(.top, 6)

            HStack(spacing: 10) {
                if node.sshHost != nil {
                    Button(action: onSSH) {
                        labelChip("SSH")
                    }
                    .buttonStyle(.plain)
                }
                // Only show OPEN API when something is actually listening
                if node.inferenceOK {
                    Link(destination: node.baseURL) {
                        labelChip("OPEN API")
                    }
                }
                if PingService.aliases[node.id] != nil {
                    Button {
                        Task { await ping.ping(node: node) }
                    } label: {
                        labelChip(ping.isPinging ? "PING…" : "PING")
                    }
                    .buttonStyle(.plain)
                    .disabled(ping.isPinging)
                }
                if let control, let target = control.target(for: node) {
                    let busy = control.busyNodeID == node.id
                    if node.inferenceOK {
                        Button {
                            pendingAction = "stop"
                        } label: {
                            labelChip(busy ? "…" : "STOP", tint: LabTheme.alert)
                        }
                        .buttonStyle(.plain)
                        .disabled(busy)
                    } else {
                        Button {
                            pendingAction = "start"
                        } label: {
                            labelChip(busy ? "…" : "SERVE")
                        }
                        .buttonStyle(.plain)
                        .disabled(busy)
                    }
                    Spacer()
                        .frame(width: 0)
                        .confirmationDialog(
                            "\(pendingAction?.uppercased() ?? "") \(target.container) on \(node.name)?",
                            isPresented: Binding(
                                get: { pendingAction != nil },
                                set: { if !$0 { pendingAction = nil } }
                            ),
                            titleVisibility: .visible
                        ) {
                            Button(pendingAction == "stop" ? "Stop container" : "Start container") {
                                let action = pendingAction
                                pendingAction = nil
                                Task {
                                    if action == "stop" {
                                        await control.stop(node)
                                    } else {
                                        await control.start(node)
                                    }
                                    onRefresh()
                                }
                            }
                            Button("Cancel", role: .cancel) { pendingAction = nil }
                        }
                }
            }
            .padding(.top, 8)

            if let r = ping.result, r.nodeID == node.id {
                row("PING", r.summary)
                    .foregroundStyle(r.isError ? LabTheme.alert : LabTheme.text)
            }
            if let r = control?.lastResult, r.nodeID == node.id {
                row("CTRL", r.message)
                    .foregroundStyle(r.isError ? LabTheme.alert : LabTheme.text)
            }
        }
        .onChange(of: node.id) { _, _ in
            ping.clear()
            pendingAction = nil
        }
    }

    /// Key/value row with a thin utilization bar under the value.
    private func metricRow(_ k: String, _ v: String, fraction: Double) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(k)
                .font(LabTheme.monoTiny)
                .foregroundStyle(LabTheme.textMuted)
                .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(v)
                    .font(LabTheme.monoSmall)
                    .foregroundStyle(LabTheme.text)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(LabTheme.strokeDim)
                        Capsule()
                            .fill(fraction > 0.85 ? LabTheme.amber : LabTheme.phosphorDim)
                            .frame(width: max(2, geo.size.width * min(1, max(0, fraction))))
                    }
                }
                .frame(height: 3)
            }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(k)
                .font(LabTheme.monoTiny)
                .foregroundStyle(LabTheme.textMuted)
                .frame(width: 64, alignment: .leading)
            Text(v)
                .font(LabTheme.monoSmall)
                .foregroundStyle(LabTheme.text)
                .textSelection(.enabled)
        }
    }

    /// Tiny latency trend line over the last hour of polls.
    private struct Sparkline: View {
        let values: [Double]

        var body: some View {
            Canvas { context, size in
                guard values.count > 1 else { return }
                let maxV = max(values.max() ?? 1, 1)
                let stepX = size.width / CGFloat(values.count - 1)
                var path = Path()
                for (i, v) in values.enumerated() {
                    let x = CGFloat(i) * stepX
                    let y = size.height - (CGFloat(v / maxV) * (size.height - 2)) - 1
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
                context.stroke(path, with: .color(LabTheme.phosphorDim), lineWidth: 1)
            }
        }
    }

    private func labelChip(_ title: String, tint: Color = LabTheme.phosphor) -> some View {
        Text(title)
            .font(LabTheme.monoTiny)
            .tracking(1)
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(tint.opacity(0.5), lineWidth: 1)
            )
    }
}
