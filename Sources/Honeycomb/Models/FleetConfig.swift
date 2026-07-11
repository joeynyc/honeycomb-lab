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
        /// Remote command that prints a spark-doctor scan JSON to stdout
        var doctorCommand: String?
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
        /// Problems found while loading — surfaced in the UI so a typo in
        /// fleet.json never silently drops a node.
        var problems: [String] = []
    }

    /// Hex ring spiral — unlimited, so a growing fleet never collides at (0,0).
    private static func spiralPositions(count: Int, skipping used: Set<String>) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        var radius = 1
        while out.count < count, radius < 12 {
            // Walk the ring at this radius (pointy-top axial directions)
            let directions = [(1, 0), (0, 1), (-1, 1), (-1, 0), (0, -1), (1, -1)]
            var q = -radius, r = radius  // start corner
            for dir in directions {
                for _ in 0..<radius {
                    if !used.contains("\(q),\(r)") && !(q == 0 && r == 0) {
                        out.append((q, r))
                        if out.count >= count { return out }
                    }
                    q += dir.0
                    r += dir.1
                }
            }
            radius += 1
        }
        return out
    }

    static func load() -> Fleet {
        let (config, configProblems) = loadConfig()
        var problems = configProblems

        // Cells claimed by explicit axial values — the auto-placer must avoid
        // them even for nodes it hasn't reached yet.
        let reserved = Set(config.nodes.compactMap { n -> String? in
            guard let a = n.axial, a.count == 2 else { return nil }
            return "\(a[0]),\(a[1])"
        })
        // Cells actually handed out so far — this is what a collision means.
        var assigned = Set<String>()
        let needsPosition = config.nodes.filter { ($0.axial?.count ?? 0) != 2 }.count
        var ring = spiralPositions(count: needsPosition, skipping: reserved)

        var seenIDs = Set<String>()
        let nodes: [LabNode] = config.nodes.compactMap { n in
            guard !n.id.isEmpty else {
                problems.append("a node has no id — skipped")
                return nil
            }
            guard !seenIDs.contains(n.id) else {
                problems.append("duplicate node id “\(n.id)” — only the first is used")
                return nil
            }
            guard let base = URL(string: n.baseURL), base.scheme != nil else {
                problems.append("“\(n.id)”: baseURL “\(n.baseURL)” is not a valid URL — skipped")
                return nil
            }
            guard let probe = ProbeKind(rawValue: n.probe) else {
                let valid = ["vllm-ssh", "lmstudio-hub", "lmlink-peer", "http-only"]
                problems.append("“\(n.id)”: unknown probe “\(n.probe)” (use \(valid.joined(separator: ", "))) — skipped")
                return nil
            }
            if probe == .vllmSSH && n.sshHost == nil {
                problems.append("“\(n.id)”: probe vllm-ssh without sshHost — health falls back to HTTP only")
            }
            seenIDs.insert(n.id)

            var axial: (Int, Int)
            if let a = n.axial, a.count == 2 {
                axial = (a[0], a[1])
            } else if !ring.isEmpty {
                axial = ring.removeFirst()
            } else {
                axial = (0, 0)
            }
            // Never stack two hexes on the same cell — the lower one would be
            // untappable and invisible.
            if assigned.contains("\(axial.0),\(axial.1)") {
                let taken = axial
                let free = spiralPositions(count: 1, skipping: assigned.union(reserved))
                if let spot = free.first { axial = spot }
                problems.append("“\(n.id)”: axial [\(taken.0), \(taken.1)] already used — moved to [\(axial.0), \(axial.1)]")
            }
            assigned.insert("\(axial.0),\(axial.1)")
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
                doctorCommand: n.doctorCommand,
                isHub: n.hub ?? (probe == .lmstudioHub),
                notes: n.notes ?? "",
                axial: (q: axial.0, r: axial.1)
            )
        }

        let ids = Set(nodes.map(\.id))
        let links = (config.links ?? [])
            .filter { $0.count == 2 && ids.contains($0[0]) && ids.contains($0[1]) }
            .map { ($0[0], $0[1]) }

        return Fleet(
            title: config.title ?? "HONEYCOMB",
            nodes: nodes,
            links: links,
            problems: problems
        )
    }

    static var fleetFileURL: URL {
        if let path = ProcessInfo.processInfo.environment["HONEYCOMB_FLEET"] {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Honeycomb", isDirectory: true)
            .appendingPathComponent("fleet.json")
    }

    private static func loadConfig() -> (FleetConfig, [String]) {
        var problems: [String] = []

        // 1. Explicit override (also how tests point at alternate fleets)
        if let path = ProcessInfo.processInfo.environment["HONEYCOMB_FLEET"] {
            switch read(URL(fileURLWithPath: path)) {
            case .success(let config):
                return (config, problems)
            case .failure(let why):
                problems.append("HONEYCOMB_FLEET=\(path): \(why.message)")
                return (FleetConfig(title: "HONEYCOMB", nodes: [], links: nil), problems)
            }
        }

        // 2. User's fleet in Application Support
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Honeycomb", isDirectory: true)
        let userFile = dir.appendingPathComponent("fleet.json")
        if FileManager.default.fileExists(atPath: userFile.path) {
            switch read(userFile) {
            case .success(let config):
                return (config, problems)
            case .failure(let why):
                // A broken fleet.json must never be silently replaced by the
                // default — the user would lose their edits and never know.
                problems.append("fleet.json could not be read: \(why.message)")
                return (FleetConfig(title: "HONEYCOMB", nodes: [], links: nil), problems)
            }
        }

        // 3. First run — copy the bundled default out so the user can edit it
        if let bundled = Bundle.module.url(forResource: "fleet-default", withExtension: "json"),
           case .success(let config) = read(bundled) {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: bundled, to: userFile)
            } catch {
                problems.append("could not write \(userFile.path): \(error.localizedDescription)")
            }
            return (config, problems)
        }
        return (FleetConfig(title: "HONEYCOMB", nodes: [], links: nil), problems)
    }

    /// Human-readable load failure.
    private struct LoadError: Error { var message: String }

    private static func read(_ url: URL) -> Result<FleetConfig, LoadError> {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .failure(LoadError(message: error.localizedDescription))
        }
        do {
            return .success(try JSONDecoder().decode(FleetConfig.self, from: data))
        } catch let DecodingError.keyNotFound(key, ctx) {
            return .failure(LoadError(message: "missing required field “\(key.stringValue)” \(ctx.codingPath.map(\.stringValue).joined(separator: "."))"))
        } catch let DecodingError.dataCorrupted(ctx) {
            return .failure(LoadError(message: "invalid JSON — \(ctx.debugDescription)"))
        } catch {
            return .failure(LoadError(message: error.localizedDescription))
        }
    }
}
