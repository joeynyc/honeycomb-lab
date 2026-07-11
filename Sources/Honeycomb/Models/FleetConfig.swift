import Foundation

/// How a node is probed for health/models. This is the only thing the
/// monitor switches on — no node IDs are special.
enum ProbeKind: String, Codable, Sendable {
    /// DGX-style: SSH is ground truth, vLLM :8000 checked separately
    case vllmSSH = "vllm-ssh"
    /// The machine the app runs on, serving via LM Studio
    case lmstudioHub = "lmstudio-hub"
    /// Remote GPU reached through the hub's LM Studio via LM Link
    case lmlinkPeer = "lmlink-peer"
    /// Plain OpenAI-compatible HTTP endpoint
    case httpOnly = "http-only"
}

/// fleet.json — the entire lab description. Lives in
/// ~/Library/Application Support/Honeycomb/fleet.json (written from the
/// bundled default on first run; HONEYCOMB_FLEET env var overrides the path).
struct FleetConfig: Codable, Sendable {
    struct Node: Codable, Sendable {
        var id: String
        var name: String
        var role: String
        var shortLabel: String?
        var probe: String
        var baseURL: String
        var modelsPath: String?
        var hostname: String?
        var address: String?
        var sshHost: String?
        var dashboardURL: String?
        /// Backend id in the gateway's config.json this node serves behind
        var gatewayBackend: String?
        /// If set, gateway activity lights this hex only for these aliases
        var litAliases: [String]?
        /// Gateway alias the PING button uses
        var pingAlias: String?
        /// Docker container SERVE/STOP controls over SSH
        var container: String?
        /// LM Link peer name to look for (lmlink-peer probes)
        var lmLinkPeer: String?
        var hub: Bool?
        var axial: [Int]?
        var notes: String?
    }

    var title: String?
    var nodes: [Node]
    /// Extra edges beyond hub→node, as [fromID, toID]
    var links: [[String]]?
}

enum FleetStore {
    struct Fleet: Sendable {
        var title: String
        var nodes: [LabNode]
        var links: [(String, String)]
    }

    static func load() -> Fleet {
        let config = loadConfig()
        let ringPositions: [(Int, Int)] = [
            (0, -1), (-1, 0), (1, 0), (0, 1), (-1, 1), (1, -1), (-2, 1), (2, -1),
        ]
        var usedPositions = Set(config.nodes.compactMap { n -> String? in
            guard let a = n.axial, a.count == 2 else { return nil }
            return "\(a[0]),\(a[1])"
        })
        var ring = ringPositions.filter { !usedPositions.contains("\($0.0),\($0.1)") }

        let nodes: [LabNode] = config.nodes.compactMap { n in
            guard let base = URL(string: n.baseURL),
                  let probe = ProbeKind(rawValue: n.probe)
            else { return nil }
            let axial: (Int, Int)
            if let a = n.axial, a.count == 2 {
                axial = (a[0], a[1])
            } else if !ring.isEmpty {
                axial = ring.removeFirst()
            } else {
                axial = (0, 0)
            }
            usedPositions.insert("\(axial.0),\(axial.1)")
            return LabNode(
                id: n.id,
                name: n.name,
                hostname: n.hostname ?? n.name,
                hostAddress: n.address ?? base.host() ?? "",
                roleLabel: n.role,
                roleShort: n.shortLabel ?? String(n.role.prefix(4)).uppercased(),
                probe: probe,
                baseURL: base,
                modelsPath: n.modelsPath ?? "/v1/models",
                sshHost: n.sshHost,
                dashboardURL: n.dashboardURL.flatMap(URL.init(string:)),
                gatewayBackend: n.gatewayBackend,
                litAliases: n.litAliases,
                pingAlias: n.pingAlias,
                container: n.container,
                lmLinkPeer: n.lmLinkPeer,
                isHub: n.hub ?? (probe == .lmstudioHub),
                notes: n.notes ?? "",
                axial: (q: axial.0, r: axial.1)
            )
        }

        let ids = Set(nodes.map(\.id))
        let links = (config.links ?? [])
            .filter { $0.count == 2 && ids.contains($0[0]) && ids.contains($0[1]) }
            .map { ($0[0], $0[1]) }

        return Fleet(title: config.title ?? "HONEYCOMB", nodes: nodes, links: links)
    }

    private static func loadConfig() -> FleetConfig {
        // 1. Explicit override (also how tests point at alternate fleets)
        if let path = ProcessInfo.processInfo.environment["HONEYCOMB_FLEET"],
           let config = read(URL(fileURLWithPath: path)) {
            return config
        }
        // 2. User's fleet in Application Support
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Honeycomb", isDirectory: true)
        let userFile = dir.appendingPathComponent("fleet.json")
        if let config = read(userFile) {
            return config
        }
        // 3. Bundled default — copy it out so the user can edit it
        if let bundled = Bundle.module.url(forResource: "fleet-default", withExtension: "json"),
           let config = read(bundled) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: bundled, to: userFile)
            return config
        }
        return FleetConfig(title: "HONEYCOMB", nodes: [], links: nil)
    }

    private static func read(_ url: URL) -> FleetConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(FleetConfig.self, from: data)
    }
}
