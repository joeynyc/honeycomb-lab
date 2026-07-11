import Foundation
import UserNotifications

/// Rolling per-node health/latency history with small-JSON persistence,
/// plus macOS notifications on node state changes.
@MainActor
final class HealthHistory {
    struct Sample: Codable, Equatable, Sendable {
        var ts: Date
        var health: String
        var latencyMs: Double?
    }

    /// Last state-change timestamp per node ("went offline 14m ago")
    private(set) var lastChange: [String: Date] = [:]
    private(set) var samples: [String: [Sample]] = [:]

    private let window: TimeInterval = 3600
    private let fileURL: URL
    private var lastSave = Date.distantPast
    private var notificationsReady = false

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Honeycomb", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.json")
        load()

        // UNUserNotificationCenter needs a real app bundle; guard so a bare
        // `swift run` binary doesn't crash.
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                Task { @MainActor in self.notificationsReady = granted }
            }
        }
    }

    /// Record one poll result. Returns true if this was a state transition.
    @discardableResult
    func record(nodeID: String, nodeName: String, health: NodeHealth, latencyMs: Double?) -> Bool {
        let now = Date()
        var nodeSamples = samples[nodeID] ?? []
        let previous = nodeSamples.last?.health
        nodeSamples.append(Sample(ts: now, health: health.rawValue, latencyMs: latencyMs))
        let cutoff = now.addingTimeInterval(-window)
        nodeSamples.removeAll { $0.ts < cutoff }
        samples[nodeID] = nodeSamples

        var transitioned = false
        if let previous, previous != health.rawValue {
            lastChange[nodeID] = now
            transitioned = true
            // Only notify on transitions involving offline, and never from unknown
            if previous != NodeHealth.unknown.rawValue {
                if health == .offline {
                    notify(title: "\(nodeName) went offline", body: "Was \(previous).")
                } else if previous == NodeHealth.offline.rawValue {
                    notify(title: "\(nodeName) is back", body: "Now \(health.rawValue).")
                }
            }
        }

        if now.timeIntervalSince(lastSave) > 60 || transitioned {
            save()
            lastSave = now
        }
        return transitioned
    }

    func latencySeries(nodeID: String, count: Int = 60) -> [Double] {
        (samples[nodeID] ?? []).suffix(count).map { $0.latencyMs ?? 0 }
    }

    private func notify(title: String, body: String) {
        guard notificationsReady else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private struct Snapshot: Codable {
        var samples: [String: [Sample]]
        var lastChange: [String: Date]
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return }
        let cutoff = Date().addingTimeInterval(-window)
        samples = snap.samples.mapValues { list in list.filter { $0.ts >= cutoff } }
        lastChange = snap.lastChange
    }

    private func save() {
        let snap = Snapshot(samples: samples, lastChange: lastChange)
        guard let data = try? JSONEncoder().encode(snap) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
