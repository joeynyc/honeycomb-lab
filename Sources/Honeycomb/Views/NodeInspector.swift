import SwiftUI

struct NodeInspector: View {
    let node: LabNode?
    let onRefresh: () -> Void
    let onSSH: () -> Void
    @State private var ping = PingService()

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
            }
            .padding(.top, 8)

            if let r = ping.result, r.nodeID == node.id {
                row("PING", r.summary)
                    .foregroundStyle(r.isError ? LabTheme.alert : LabTheme.text)
            }
        }
        .onChange(of: node.id) { _, _ in
            ping.clear()
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

    private func labelChip(_ title: String) -> some View {
        Text(title)
            .font(LabTheme.monoTiny)
            .tracking(1)
            .foregroundStyle(LabTheme.phosphor)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(LabTheme.phosphor.opacity(0.5), lineWidth: 1)
            )
    }
}
