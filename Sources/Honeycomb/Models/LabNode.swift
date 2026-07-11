import Foundation
import SwiftUI

enum NodeHealth: String, Sendable {
    case online
    case degraded
    case offline
    case unknown

    var color: Color {
        switch self {
        case .online: return LabTheme.phosphor
        case .degraded: return LabTheme.amber
        case .offline: return LabTheme.alert
        case .unknown: return LabTheme.dim
        }
    }

    var glyph: String {
        switch self {
        case .online: return "●"
        case .degraded: return "◐"
        case .offline: return "○"
        case .unknown: return "·"
        }
    }
}

/// Live utilization for a node (DGX Sparks; unified memory on GB10, so
/// system memory *is* GPU memory).
struct NodeMetrics: Equatable, Sendable {
    var gpuUtilPct: Int?
    var memUsedMB: Int?
    var memTotalMB: Int?
    /// vLLM KV-cache usage 0–100
    var kvCachePct: Double?
    var runningRequests: Int?
    /// Computed from vLLM's generation_tokens_total counter between polls
    var genTokPerSec: Double?
    /// Raw counter used for the delta
    var genTokensTotal: Double?
}

struct LabNode: Identifiable, Sendable, Equatable {
    let id: String
    var name: String
    var hostname: String
    /// LAN or Tailscale address used for reachability context
    var hostAddress: String
    var roleLabel: String
    var roleShort: String
    var probe: ProbeKind
    /// OpenAI-compatible inference base when this node serves chat
    var baseURL: URL
    var modelsPath: String
    /// SSH alias (NVIDIA Sync host, or any ~/.ssh/config entry)
    var sshHost: String?
    /// Dashboard tunnel to check (optional)
    var dashboardURL: URL?
    /// Gateway backend id this node serves behind (for LIT mapping)
    var gatewayBackend: String?
    /// If set, gateway activity lights this hex only for these aliases
    var litAliases: [String]?
    /// Gateway alias the PING button uses
    var pingAlias: String?
    /// Docker container name for SERVE/STOP over SSH
    var container: String?
    /// LM Link peer name (lmlink-peer probes)
    var lmLinkPeer: String?
    /// Remote command producing a spark-doctor scan JSON on stdout
    var doctorCommand: String?
    var isHub: Bool
    var notes: String

    /// Axial coords for honeycomb layout (q, r)
    var axial: (q: Int, r: Int)

    var health: NodeHealth = .unknown
    var latencyMs: Double?
    var metrics: NodeMetrics?
    /// Only *loaded / serving* models — never a full catalog dump
    var models: [String] = []
    var lastChecked: Date?
    var lastError: String?
    var isStreaming: Bool = false

    /// Real connection facts (filled by probe)
    var sshOK: Bool = false
    var dashboardOK: Bool = false
    var inferenceOK: Bool = false
    var statusDetail: String = ""

    var displayModel: String {
        if models.isEmpty {
            if inferenceOK { return "API up · nothing loaded" }
            if health == .online || health == .degraded {
                switch probe {
                case .lmstudioHub: return "control plane"
                case .lmlinkPeer: return "LM Link · no model loaded"
                case .vllmSSH: return sshHost != nil ? "connected · no vLLM" : "connected"
                case .httpOnly: return "connected"
                }
            }
            return "—"
        }
        if models.count == 1 {
            let m = models[0]
            let short = m.split(separator: "/").last.map(String.init) ?? m
            return short.count > 40 ? String(short.prefix(37)) + "…" : short
        }
        // Accurate multi-model summary (never invent huge catalog counts)
        let first = models[0].split(separator: "/").last.map(String.init) ?? models[0]
        let head = first.count > 24 ? String(first.prefix(21)) + "…" : first
        return "\(head) + \(models.count - 1) more"
    }

    /// Chat only when an OpenAI-compatible endpoint answers
    var canChat: Bool { inferenceOK }

    /// Single accurate path label for hex / strip (never "ONLINE" + "OFF" together)
    var pathBadge: String {
        if isStreaming { return "LIT" }
        switch probe {
        case .lmlinkPeer:
            if health == .offline { return "DOWN" }
            if dashboardOK { return "LM LINK" }
            if sshOK { return "SSH" }
            return health == .online ? "UP" : "DOWN"
        case .lmstudioHub:
            return inferenceOK ? "LMS" : "HUB"
        case .vllmSSH:
            if health == .offline { return "DOWN" }
            if inferenceOK { return "SSH+vLLM" }
            if sshOK || dashboardOK { return "SSH" }
            return "DOWN"
        case .httpOnly:
            return health == .online ? "API" : health.rawValue.uppercased()
        }
    }

    var pathBadgeColor: Color {
        if isStreaming { return LabTheme.phosphor }
        switch pathBadge {
        case "DOWN", "OFF": return LabTheme.alert
        case "SSH": return LabTheme.amber
        case "LM LINK", "SSH+vLLM", "LMS", "LIT", "API": return LabTheme.phosphorDim
        case "HUB", "UP": return LabTheme.amber.opacity(0.9)
        default: return LabTheme.dim
        }
    }

    static func == (lhs: LabNode, rhs: LabNode) -> Bool {
        lhs.id == rhs.id
            && lhs.health == rhs.health
            && lhs.latencyMs == rhs.latencyMs
            && lhs.metrics == rhs.metrics
            && lhs.models == rhs.models
            && lhs.lastError == rhs.lastError
            && lhs.isStreaming == rhs.isStreaming
            && lhs.sshOK == rhs.sshOK
            && lhs.dashboardOK == rhs.dashboardOK
            && lhs.inferenceOK == rhs.inferenceOK
            && lhs.statusDetail == rhs.statusDetail
    }
}
