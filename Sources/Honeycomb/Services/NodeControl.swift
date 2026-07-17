import Foundation
import Observation

/// Start/stop inference on remote nodes over SSH — Docker containers that
/// already exist on the host, so config (model, flags, ports) is preserved.
///
/// SERVE starts the fleet.json `container` name (the node's preferred serve).
/// STOP discovers whatever inference container is actually running (vLLM image,
/// or the configured name if that one is up) so swapping models never leaves
/// STOP targeting a stale exited container.
@MainActor
@Observable
final class NodeControl {
    struct ActionResult: Equatable {
        var nodeID: String
        var message: String
        var isError: Bool
    }

    private(set) var busyNodeID: String?
    private(set) var lastResult: ActionResult?

    /// STOP when SSH is available and this node is a docker-served box
    /// (configured container and/or vLLM probe — not LM Link peers).
    func canStop(_ node: LabNode) -> Bool {
        guard node.sshHost != nil else { return false }
        return node.container != nil || node.probe == .vllmSSH
    }

    func canStart(_ node: LabNode) -> Bool {
        node.sshHost != nil && node.container != nil
    }

    /// Preferred container label for confirm copy (may be stale vs what's running).
    func preferredContainer(for node: LabNode) -> String? {
        node.container
    }

    func start(_ node: LabNode) async {
        guard busyNodeID == nil,
              let host = node.sshHost,
              let container = node.container
        else { return }
        busyNodeID = node.id
        lastResult = nil
        defer { busyNodeID = nil }

        let result = await Subprocess.run(
            "/usr/bin/ssh",
            [
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=5",
                "--",
                host,
                "docker", "start", container,
            ],
            timeout: 30,
            mergeStderr: true
        )
        guard let result else {
            lastResult = ActionResult(nodeID: node.id, message: "start timed out", isError: true)
            return
        }
        if result.status == 0 {
            lastResult = ActionResult(
                nodeID: node.id,
                message: "container starting — model load takes a few minutes",
                isError: false
            )
        } else {
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            lastResult = ActionResult(
                nodeID: node.id,
                message: "start failed (exit \(result.status)) \(detail.prefix(80))",
                isError: true
            )
        }
    }

    func stop(_ node: LabNode) async {
        guard busyNodeID == nil, let host = node.sshHost else { return }
        busyNodeID = node.id
        lastResult = nil
        defer { busyNodeID = nil }

        // List running containers; host-network vLLM has empty Ports, so image match.
        let list = await Subprocess.run(
            "/usr/bin/ssh",
            [
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=5",
                "--",
                host,
                "docker", "ps", "--format", "{{.Names}}\t{{.Image}}",
            ],
            timeout: 15,
            mergeStderr: true
        )
        guard let list else {
            lastResult = ActionResult(nodeID: node.id, message: "stop timed out listing containers", isError: true)
            return
        }
        if list.status != 0 {
            let detail = list.output.trimmingCharacters(in: .whitespacesAndNewlines)
            lastResult = ActionResult(
                nodeID: node.id,
                message: "docker ps failed (exit \(list.status)) \(detail.prefix(80))",
                isError: true
            )
            return
        }

        var targets = ProbeParsers.runningInferenceContainers(
            dockerPs: list.output,
            preferred: node.container
        )
        // Nothing matched by image — still try the configured name if set
        // (docker stop on an exited container is harmless / clear error).
        if targets.isEmpty, let preferred = node.container {
            targets = [preferred]
        }
        if targets.isEmpty {
            lastResult = ActionResult(
                nodeID: node.id,
                message: "no inference container running",
                isError: false
            )
            return
        }

        var args = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "--",
            host,
            "docker", "stop",
        ]
        args.append(contentsOf: targets)

        let result = await Subprocess.run(
            "/usr/bin/ssh",
            args,
            // docker stop waits for graceful shutdown (default 10s then SIGKILL)
            timeout: 60,
            mergeStderr: true
        )
        guard let result else {
            lastResult = ActionResult(
                nodeID: node.id,
                message: "stop timed out on \(targets.joined(separator: ", "))",
                isError: true
            )
            return
        }
        if result.status == 0 {
            let label = targets.joined(separator: ", ")
            lastResult = ActionResult(
                nodeID: node.id,
                message: "stopped \(label)",
                isError: false
            )
        } else {
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            lastResult = ActionResult(
                nodeID: node.id,
                message: "stop failed (exit \(result.status)) \(detail.prefix(100))",
                isError: true
            )
        }
    }
}
