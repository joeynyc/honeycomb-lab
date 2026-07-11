import Foundation
import Observation

/// Start/stop inference on remote nodes over SSH — Docker containers that
/// already exist on the Spark, so config (model, flags, ports) is preserved.
/// Container names live in ~/Library/Application Support/Honeycomb/control.json.
@MainActor
@Observable
final class NodeControl {
    struct Target: Codable, Sendable {
        /// Existing Docker container to start/stop (e.g. "qwen36-35b-nvfp4")
        var container: String
    }

    struct ActionResult: Equatable {
        var nodeID: String
        var message: String
        var isError: Bool
    }

    private(set) var targets: [String: Target] = [:]
    private(set) var busyNodeID: String?
    private(set) var lastResult: ActionResult?

    private let fileURL: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Honeycomb", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("control.json")
        load()
    }

    func target(for node: LabNode) -> Target? {
        guard node.sshHost != nil else { return nil }
        return targets[node.id]
    }

    func start(_ node: LabNode) async {
        await run(node, verb: "start")
    }

    func stop(_ node: LabNode) async {
        await run(node, verb: "stop")
    }

    private func run(_ node: LabNode, verb: String) async {
        guard busyNodeID == nil,
              let host = node.sshHost,
              let target = targets[node.id]
        else { return }
        busyNodeID = node.id
        lastResult = nil
        defer { busyNodeID = nil }

        let result = await Subprocess.run(
            "/usr/bin/ssh",
            [
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=5",
                host,
                "docker", verb, target.container,
            ],
            // docker stop waits for graceful shutdown; start returns fast
            timeout: verb == "stop" ? 45 : 30
        )
        guard let result else {
            lastResult = ActionResult(nodeID: node.id, message: "\(verb) timed out", isError: true)
            return
        }
        if result.status == 0 {
            let note = verb == "start"
                ? "container starting — model load takes a few minutes"
                : "container stopped"
            lastResult = ActionResult(nodeID: node.id, message: note, isError: false)
        } else {
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            lastResult = ActionResult(
                nodeID: node.id,
                message: "\(verb) failed (exit \(result.status)) \(detail.prefix(80))",
                isError: true
            )
        }
    }

    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Target].self, from: data) {
            targets = decoded
            return
        }
        // First run: write discovered defaults so they're user-editable.
        targets = [
            "gx10": Target(container: "qwen36-35b-nvfp4"),
            "joeydgx": Target(container: "nemotron-puzzle-75b"),
        ]
        if let data = try? JSONEncoder().encode(targets) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
