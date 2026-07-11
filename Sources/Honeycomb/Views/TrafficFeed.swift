import SwiftUI

/// Scrolling log of recent gateway requests — the paper trail behind LIT.
struct TrafficFeed: View {
    let feed: [HealthMonitor.FeedEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("TRAFFIC")
                    .font(LabTheme.monoTiny)
                    .tracking(2)
                    .foregroundStyle(LabTheme.phosphorDim)
                Spacer()
                Text("\(feed.count) recent")
                    .font(LabTheme.monoTiny)
                    .foregroundStyle(LabTheme.dim)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            Divider().overlay(LabTheme.stroke.opacity(0.8))

            if feed.isEmpty {
                Text("No gateway traffic yet — requests through :4000 appear here.")
                    .font(LabTheme.monoTiny)
                    .foregroundStyle(LabTheme.textMuted)
                    .padding(12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(feed) { entry in
                            feedRow(entry)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(height: 132)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LabTheme.panel)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(LabTheme.stroke.opacity(0.9), lineWidth: 1)
        )
    }

    private func feedRow(_ entry: HealthMonitor.FeedEntry) -> some View {
        HStack(spacing: 8) {
            Text(entry.date.formatted(date: .omitted, time: .standard))
                .foregroundStyle(LabTheme.dim)
            Text(entry.alias ?? entry.backend)
                .foregroundStyle(LabTheme.phosphorDim)
            Text("← \(shortModel(entry.model))")
                .foregroundStyle(LabTheme.text)
                .lineLimit(1)
            Spacer()
            if let toks = entry.completionTokens {
                Text("\(toks) tok")
                    .foregroundStyle(LabTheme.textMuted)
            }
            if entry.stream {
                Text("stream")
                    .foregroundStyle(LabTheme.textMuted)
            }
            if let ms = entry.durationMs {
                Text(ms >= 1000 ? String(format: "%.1fs", ms / 1000) : String(format: "%.0fms", ms))
                    .foregroundStyle(LabTheme.textMuted)
            }
            if let status = entry.status, !(200...299).contains(status) {
                Text("\(status)")
                    .foregroundStyle(LabTheme.alert)
            }
        }
        .font(LabTheme.monoTiny)
    }

    private func shortModel(_ id: String) -> String {
        let base = id.split(separator: "/").last.map(String.init) ?? id
        return base.count > 28 ? String(base.prefix(25)) + "…" : base
    }
}
