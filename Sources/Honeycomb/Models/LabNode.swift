import Foundation
import SwiftUI

enum NodeRole: String, Codable, CaseIterable, Sendable {
    case mainSpark = "MAIN SPARK"
    case peerSpark = "PEER SPARK"
    case controlPlane = "CONTROL PLANE"
    case desktopGPU = "DESKTOP GPU"

    var shortLabel: String {
        switch self {
        case .mainSpark: return "MAIN"
        case .peerSpark: return "PEER"
        case .controlPlane: return "HUB"
        case .desktopGPU: return "4080"
        }
    }
}

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

struct LabNode: Identifiable, Sendable, Equatable {
    let id: String
    var name: String
    var hostname: String
    /// LAN or Tailscale address used for reachability context
    var hostAddress: String
    var role: NodeRole
    /// OpenAI-compatible inference base when this node serves chat
    var baseURL: URL
    var modelsPath: String
    /// NVIDIA Sync / SSH alias
    var sshHost: String?
    /// NVIDIA Sync local dashboard tunnel (DGX only)
    var dashboardURL: URL?
    var notes: String

    /// Axial coords for honeycomb layout (q, r)
    var axial: (q: Int, r: Int)

    var health: NodeHealth = .unknown
    var latencyMs: Double?
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
                if id == "mini" { return "control plane" }
                if id == "pc4080" { return "LM Link · no model loaded on PC" }
                if sshHost != nil { return "Sync connected · no vLLM" }
                return "connected"
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
        switch id {
        case "pc4080":
            if health == .offline { return "DOWN" }
            if isStreaming { return "LIT" }
            if dashboardOK && inferenceOK { return "LM LINK" } // mesh + Mini LMS API
            if dashboardOK { return "LM LINK" }
            if sshOK { return "SSH" }
            return health == .online ? "UP" : "DOWN"
        case "mini":
            if isStreaming { return "LIT" }
            return inferenceOK ? "LMS" : "HUB"
        case "joeydgx", "gx10":
            if health == .offline { return "DOWN" }
            if isStreaming { return "LIT" }
            if inferenceOK { return "SYNC+vLLM" }
            if sshOK || dashboardOK { return "SYNC" }
            return "DOWN"
        default:
            if isStreaming { return "LIT" }
            return health.rawValue.uppercased()
        }
    }

    var pathBadgeColor: Color {
        if isStreaming { return LabTheme.phosphor }
        switch pathBadge {
        case "DOWN", "OFF": return LabTheme.alert
        case "SSH": return LabTheme.amber
        case "LM LINK", "SYNC+vLLM", "LMS", "LIT": return LabTheme.phosphorDim
        case "SYNC", "HUB", "UP": return LabTheme.amber.opacity(0.9)
        default: return LabTheme.dim
        }
    }

    static func == (lhs: LabNode, rhs: LabNode) -> Bool {
        lhs.id == rhs.id
            && lhs.health == rhs.health
            && lhs.latencyMs == rhs.latencyMs
            && lhs.models == rhs.models
            && lhs.lastError == rhs.lastError
            && lhs.isStreaming == rhs.isStreaming
            && lhs.sshOK == rhs.sshOK
            // isStreaming already compared
            && lhs.dashboardOK == rhs.dashboardOK
            && lhs.inferenceOK == rhs.inferenceOK
            && lhs.statusDetail == rhs.statusDetail
    }
}

enum LabCatalog {
    /// Real lab nodes only.
    static let seed: [LabNode] = [
        LabNode(
            id: "joeydgx",
            name: "JoeyDGX",
            hostname: "spark-db08",
            hostAddress: "192.168.1.15",
            role: .mainSpark,
            baseURL: URL(string: "http://192.168.1.15:8000")!,
            modelsPath: "/v1/models",
            sshHost: "JoeyDGX",
            dashboardURL: URL(string: "http://127.0.0.1:11000")!,
            notes: "Primary DGX Spark (GB10). Online = NVIDIA Sync SSH. Models = only what vLLM is serving.",
            axial: (q: -1, r: 0)
        ),
        LabNode(
            id: "gx10",
            name: "gx10",
            hostname: "gx10-3028",
            hostAddress: "192.168.1.192",
            role: .peerSpark,
            baseURL: URL(string: "http://192.168.1.192:8000")!,
            modelsPath: "/v1/models",
            sshHost: "gx10",
            dashboardURL: nil,
            notes: "Peer Spark. Models = only the active vLLM serve (e.g. Qwen3.6-35B NVFP4).",
            axial: (q: 1, r: 0)
        ),
        LabNode(
            id: "mini",
            name: "Mac mini",
            hostname: "Mac-mini",
            hostAddress: "192.168.1.11",
            role: .controlPlane,
            // LM Studio local server (also front door for LM Link remote models)
            baseURL: URL(string: "http://127.0.0.1:1234")!,
            modelsPath: "/v1/models",
            sshHost: nil,
            dashboardURL: nil,
            notes: "Honeycomb hub. Gateway: http://127.0.0.1:4000/v1 · LMS :1234.",
            axial: (q: 0, r: -1)
        ),
        LabNode(
            id: "pc4080",
            name: "PC 4080",
            hostname: "ZeroCool",
            hostAddress: "100.67.238.63",
            role: .desktopGPU,
            baseURL: URL(string: "http://127.0.0.1:1234")!,
            modelsPath: "/v1/models",
            sshHost: "zerocool",
            dashboardURL: nil,
            notes: "RTX 4080 via LM Link (peer ZeroCool). Models = loaded on the PC device only.",
            axial: (q: 0, r: 1)
        ),
    ]
}
