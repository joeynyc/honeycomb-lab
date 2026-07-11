import Foundation
import Observation

/// spark-doctor integration: runs the node's configured doctor command over
/// SSH (read-only diagnostics), parses findings, and keeps the latest report
/// per node. Nodes opt in via "doctorCommand" in fleet.json.
@MainActor
@Observable
final class DoctorService {
    struct Finding: Equatable, Sendable, Identifiable {
        var id: String { ruleID }
        var ruleID: String
        var title: String
        /// info | warning | critical
        var severity: String
        var explanation: String
        var recommendedActions: [String]
    }

    struct Report: Equatable, Sendable {
        var nodeID: String
        var date: Date
        var findings: [Finding]
        var error: String?

        var worstSeverity: String? {
            if findings.contains(where: { $0.severity == "critical" }) { return "critical" }
            if findings.contains(where: { $0.severity == "warning" }) { return "warning" }
            return findings.isEmpty ? nil : "info"
        }
        var hasCritical: Bool { worstSeverity == "critical" }
    }

    private(set) var reports: [String: Report] = [:]
    private(set) var busyNodeID: String?

    func report(for nodeID: String) -> Report? {
        reports[nodeID]
    }

    /// True while a report is fresh enough to influence health display.
    func freshReport(for nodeID: String, maxAge: TimeInterval = 3600) -> Report? {
        guard let r = reports[nodeID], Date().timeIntervalSince(r.date) < maxAge else {
            return nil
        }
        return r
    }

    func scan(_ node: LabNode) async {
        guard busyNodeID == nil,
              let host = node.sshHost,
              let command = node.doctorCommand
        else { return }
        busyNodeID = node.id
        defer { busyNodeID = nil }

        let result = await Subprocess.run(
            "/usr/bin/ssh",
            ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "--", host, command],
            // collectors + GPU sampling take a while
            timeout: 120
        )
        guard let result else {
            reports[node.id] = Report(nodeID: node.id, date: Date(), findings: [], error: "doctor timed out")
            return
        }
        guard result.status == 0 || !result.output.isEmpty,
              let data = result.output.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawFindings = obj["findings"] as? [[String: Any]]
        else {
            reports[node.id] = Report(
                nodeID: node.id,
                date: Date(),
                findings: [],
                error: "doctor failed (exit \(result.status))"
            )
            return
        }
        let findings = rawFindings.compactMap { f -> Finding? in
            guard let rule = f["rule_id"] as? String,
                  let title = f["title"] as? String,
                  let severity = f["severity"] as? String
            else { return nil }
            return Finding(
                ruleID: rule,
                title: title,
                severity: severity,
                explanation: f["explanation"] as? String ?? "",
                recommendedActions: f["recommended_actions"] as? [String] ?? []
            )
        }
        reports[node.id] = Report(nodeID: node.id, date: Date(), findings: findings, error: nil)
    }
}
