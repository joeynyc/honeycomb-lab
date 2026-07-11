import Foundation
import Observation

/// Start/stop inference on remote nodes over SSH — Docker containers that
/// already exist on the host, so config (model, flags, ports) is preserved.
/// Container names come from fleet.json (node "container" field).
@MainActor
@Observable
final class NodeControl {
    struct Target: Sendable {
        /// Existing Docker container to start/stop (e.g. "qwen36-35b-nvfp4")
        var container: String
    }

    struct ActionResult: Equatable {
        var nodeID: String
        var message: String
        var isError: Bool
    }

    private(set) var busyNodeID: String?
    private(set) var lastResult: ActionResult?

    func target(for node: LabNode) -> Target? {
        guard node.sshHost != nil, let container = node.container else { return nil }
        return Target(container: container)
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
              let target = target(for: node)
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

}
