import Foundation
import Observation

@MainActor
@Observable
final class HealthMonitor {
    private(set) var nodes: [LabNode]
    private(set) var isRefreshing = false
    private(set) var lastFullRefresh: Date?
    /// Honeycomb gateway (OpenAI front door on :4000)
    private(set) var gatewayOK: Bool = false
    private(set) var gatewayDetail: String = "gateway unknown"
    var selectedNodeID: String?

    private var pollTask: Task<Void, Never>?
    private let session: URLSession
    private let pollInterval: Duration
    private let gatewayURL = URL(string: "http://127.0.0.1:4000/health")!

    init(nodes: [LabNode] = LabCatalog.seed, pollInterval: Duration = .seconds(4)) {
        self.nodes = nodes
        self.selectedNodeID = nodes.first(where: { $0.role == .mainSpark })?.id
            ?? nodes.first?.id
        self.pollInterval = pollInterval

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 4
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    var selectedNode: LabNode? {
        guard let selectedNodeID else { return nodes.first }
        return nodes.first(where: { $0.id == selectedNodeID })
    }

    var statusLine: String {
        let g = gatewayOK ? "GW●" : "GW○"
        return g + " " + nodes.map { "\($0.role.shortLabel)\($0.health.glyph)" }.joined(separator: " ")
    }

    var onlineCount: Int {
        nodes.filter { $0.health == .online || $0.health == .degraded }.count
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            await self?.refreshAll()
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: self.pollInterval)
                guard !Task.isCancelled else { break }
                await self.refreshAll()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func select(_ id: String) {
        selectedNodeID = id
    }

    func refreshAll() async {
        isRefreshing = true
        defer {
            isRefreshing = false
            lastFullRefresh = Date()
        }

        let snapshot = nodes
        let session = self.session
        let gatewayURL = self.gatewayURL

        async let nodeResults: [(String, ProbeResult)] = Self.probeAll(nodes: snapshot, session: session)
        async let gw: GatewaySnapshot = Self.fetchGateway(session: session, url: gatewayURL)

        let results = await nodeResults
        let gateway = await gw

        gatewayOK = gateway.ok
        gatewayDetail = gateway.detail

        for (id, result) in results {
            guard let idx = nodes.firstIndex(where: { $0.id == id }) else { continue }
            nodes[idx].health = result.health
            nodes[idx].latencyMs = result.latencyMs
            nodes[idx].models = result.models
            nodes[idx].lastError = result.error
            nodes[idx].sshOK = result.sshOK
            nodes[idx].dashboardOK = result.dashboardOK
            nodes[idx].inferenceOK = result.inferenceOK
            nodes[idx].statusDetail = result.detail
            nodes[idx].lastChecked = Date()
            // Lit = gateway saw traffic to this node recently
            nodes[idx].isStreaming = gateway.nodeActivity[id] ?? false
        }
    }

    private struct GatewaySnapshot: Sendable {
        var ok: Bool
        var detail: String
        var nodeActivity: [String: Bool]
    }

    private nonisolated static func probeAll(nodes: [LabNode], session: URLSession) async -> [(String, ProbeResult)] {
        await withTaskGroup(of: (String, ProbeResult).self) { group in
            for node in nodes {
                group.addTask {
                    let result = await Self.probe(node: node, session: session)
                    return (node.id, result)
                }
            }
            var acc: [(String, ProbeResult)] = []
            for await item in group { acc.append(item) }
            return acc
        }
    }

    private nonisolated static func fetchGateway(session: URLSession, url: URL) async -> GatewaySnapshot {
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return GatewaySnapshot(ok: false, detail: "gateway HTTP error", nodeActivity: [:])
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return GatewaySnapshot(ok: true, detail: "gateway up", nodeActivity: [:])
            }
            var activity: [String: Bool] = [:]
            if let na = obj["node_activity"] as? [String: Any] {
                for (k, v) in na {
                    activity[k] = (v as? Bool) ?? false
                }
            }
            // Also map backend-level active flags
            if let backends = obj["backends"] as? [String: Any] {
                if let gx = backends["gx10"] as? [String: Any], gx["active"] as? Bool == true {
                    activity["gx10"] = true
                }
                if let jd = backends["joeydgx"] as? [String: Any], jd["active"] as? Bool == true {
                    activity["joeydgx"] = true
                }
                if let lms = backends["lms"] as? [String: Any], lms["active"] as? Bool == true {
                    activity["mini"] = true
                    let alias = (lms["last_alias"] as? String) ?? ""
                    if alias.hasPrefix("pc") || alias.contains("4080") {
                        activity["pc4080"] = true
                    }
                }
            }
            let up = (obj["backends"] as? [String: Any])?.values.compactMap { $0 as? [String: Any] }
                .filter { $0["healthy"] as? Bool == true }.count ?? 0
            return GatewaySnapshot(
                ok: true,
                detail: "gateway :4000 · \(up) backends up",
                nodeActivity: activity
            )
        } catch {
            return GatewaySnapshot(ok: false, detail: "gateway down · start gateway/start.sh", nodeActivity: [:])
        }
    }

    func openSSH(_ node: LabNode) {
        guard let host = node.sshHost else { return }
        let script = """
        tell application "Terminal"
          activate
          do script "ssh \(host)"
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    // MARK: - Probe

    private struct ProbeResult: Sendable {
        var health: NodeHealth
        var latencyMs: Double?
        var models: [String]
        var error: String?
        var sshOK: Bool
        var dashboardOK: Bool
        var inferenceOK: Bool
        var detail: String
    }

    private nonisolated static func modelsURL(for node: LabNode) -> URL {
        let base = node.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = node.modelsPath.hasPrefix("/") ? node.modelsPath : "/" + node.modelsPath
        return URL(string: base + path) ?? node.baseURL.appendingPathComponent("v1/models")
    }

    private nonisolated static func probe(node: LabNode, session: URLSession) async -> ProbeResult {
        switch node.id {
        case "pc4080":
            return await probePC(node: node, session: session)
        case "mini":
            return await probeControlPlane(node: node, session: session)
        default:
            // DGX Sparks: real connection = NVIDIA Sync SSH
            if node.sshHost != nil {
                return await probeDGX(node: node, session: session)
            }
            return await probeHTTPOnly(node: node, session: session)
        }
    }

    /// Mac mini hub — this machine. Never list huge catalogs.
    /// Online always (we're running here). Models = currently *loaded* in LM Studio (`lms ps`).
    private nonisolated static func probeControlPlane(node: LabNode, session: URLSession) async -> ProbeResult {
        let start = ContinuousClock.now

        async let server: (Bool, _, _) = checkInference(node: node, session: session)
        async let loaded: [String] = listLMStudioLoadedModels(deviceFilter: nil) // local only
        async let linkSelf: (Bool, String) = checkLMLinkSelf()

        let (serverOK, _, _) = await server
        let loadedModels = await loaded
        let (linkOK, linkDetail) = await linkSelf

        let elapsed = start.duration(to: .now)
        let latency = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15

        var parts: [String] = ["hub"]
        if linkOK { parts.append("lm-link") }
        if serverOK { parts.append("lms :1234") }
        if !loadedModels.isEmpty {
            parts.append("\(loadedModels.count) loaded")
        } else {
            parts.append("no model loaded")
        }

        return ProbeResult(
            health: .online,
            latencyMs: latency,
            models: loadedModels,
            error: nil,
            sshOK: false,
            dashboardOK: linkOK,
            inferenceOK: serverOK,
            detail: parts.joined(separator: " · ") + (linkOK ? "" : " · \(linkDetail)")
        )
    }

    /// Loaded models only (`lms ps`), optionally filtered by DEVICE column.
    private nonisolated static func listLMStudioLoadedModels(deviceFilter: String?) async -> [String] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-lc", "lms ps 2>/dev/null"]
                let out = Pipe()
                process.standardOutput = out
                process.standardError = Pipe()
                do {
                    try process.run()
                    process.waitUntilExit()
                    let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    if text.localizedCaseInsensitiveContains("No models are currently loaded") {
                        cont.resume(returning: [])
                        return
                    }
                    var found: [String] = []
                    for line in text.components(separatedBy: .newlines) {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty,
                              !trimmed.hasPrefix("IDENTIFIER"),
                              !trimmed.hasPrefix("LLM"),
                              !trimmed.hasPrefix("EMBEDDING"),
                              !trimmed.hasPrefix("To load"),
                              !trimmed.hasPrefix("SIZE")
                        else { continue }
                        if let filter = deviceFilter {
                            guard line.localizedCaseInsensitiveContains(filter) else { continue }
                        } else {
                            // Local hub: skip rows that are only on a remote device name
                            // (lms ps format varies; keep lines without a remote peer if ambiguous)
                            if line.localizedCaseInsensitiveContains("ZeroCool") { continue }
                        }
                        let parts = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                        if let id = parts.first, id.count > 2 {
                            found.append(id)
                        }
                    }
                    cont.resume(returning: found)
                } catch {
                    cont.resume(returning: [])
                }
            }
        }
    }

    private nonisolated static func checkLMLinkSelf() async -> (Bool, String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-lc", "lms link status 2>/dev/null"]
                let out = Pipe()
                process.standardOutput = out
                process.standardError = Pipe()
                do {
                    try process.run()
                    process.waitUntilExit()
                    let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let online = text.localizedCaseInsensitiveContains("Status: Online")
                        || text.localizedCaseInsensitiveContains("Status: online")
                    cont.resume(returning: (
                        online,
                        online ? "link self online" : "lm link offline on mini"
                    ))
                } catch {
                    cont.resume(returning: (false, error.localizedDescription))
                }
            }
        }
    }

    /// PC RTX 4080 — LM Link peer (ZeroCool) is the real connection.
    /// Local LM Studio server on the Mini exposes OpenAI API including remote Link models.
    private nonisolated static func probePC(node: LabNode, session: URLSession) async -> ProbeResult {
        let start = ContinuousClock.now

        async let ssh: (Bool, String?) = {
            guard let host = node.sshHost else { return (false, nil) }
            return await checkSSH(host: host)
        }()
        async let link: (Bool, String) = checkLMLinkPeer(name: "ZeroCool")
        async let lmsServer: (Bool, [String], String?) = checkInference(node: node, session: session)
        // Disk inventory on peer is noisy; prefer *loaded* on ZeroCool if any.
        async let remoteLoaded: [String] = listLMStudioLoadedModels(deviceFilter: "ZeroCool")
        async let remoteDisk: [String] = listLMStudioModelsOnDevice(device: "ZeroCool")

        let (sshOK, sshErr) = await ssh
        let (linkOK, linkDetail) = await link
        let (serverOK, _, _) = await lmsServer
        let loadedOnPC = await remoteLoaded
        let diskOnPC = await remoteDisk
        // Accurate: loaded first; else only note disk presence as empty for "serving" list
        let peerModels = loadedOnPC

        let elapsed = start.duration(to: .now)
        let latency = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15

        let hostUp = linkOK || sshOK
        var parts: [String] = []
        if linkOK { parts.append("lm-link") }
        if sshOK { parts.append("ssh") }
        if serverOK { parts.append("lms-api") }
        if !loadedOnPC.isEmpty {
            parts.append("\(loadedOnPC.count) loaded on PC")
        } else if !diskOnPC.isEmpty {
            parts.append("\(diskOnPC.count) on disk · none loaded")
        } else {
            parts.append("no PC model loaded")
        }

        let detail: String
        if hostUp {
            detail = parts.isEmpty ? "connected" : parts.joined(separator: " · ")
        } else {
            detail = linkDetail.isEmpty ? (sshErr ?? "link offline") : linkDetail
        }

        let models = peerModels

        let health: NodeHealth = hostUp ? .online : .offline
        let inferenceOK = serverOK && linkOK

        return ProbeResult(
            health: health,
            latencyMs: hostUp ? latency : nil,
            models: models,
            error: hostUp ? nil : (sshErr ?? "LM Link peer offline"),
            sshOK: sshOK,
            dashboardOK: linkOK, // reuse flag: dashboardOK == LM Link for PC
            inferenceOK: inferenceOK,
            detail: detail
        )
    }

    /// Parse `lms link status` for a named peer (e.g. ZeroCool).
    private nonisolated static func checkLMLinkPeer(name: String) async -> (Bool, String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-lc", "lms link status 2>/dev/null"]
                let out = Pipe()
                process.standardOutput = out
                process.standardError = Pipe()
                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = out.fileHandleForReading.readDataToEndOfFile()
                    let text = String(data: data, encoding: .utf8) ?? ""
                    // Look for peer block: "- ZeroCool" then "Status: connected"
                    let connected: Bool = {
                        let lines = text.components(separatedBy: .newlines)
                        var inPeer = false
                        for line in lines {
                            let t = line.trimmingCharacters(in: .whitespaces)
                            if t.hasPrefix("- ") {
                                inPeer = t.dropFirst(2).lowercased().contains(name.lowercased())
                            } else if inPeer && t.lowercased().hasPrefix("status:") {
                                return t.lowercased().contains("connected")
                                    || t.lowercased().contains("online")
                            }
                        }
                        // fallback: name + connected anywhere
                        return text.localizedCaseInsensitiveContains(name)
                            && text.localizedCaseInsensitiveContains("connected")
                    }()
                    cont.resume(returning: (
                        connected,
                        connected ? "\(name) connected" : "\(name) not in link mesh"
                    ))
                } catch {
                    cont.resume(returning: (false, error.localizedDescription))
                }
            }
        }
    }

    /// Models listed under a remote device in `lms ls` (DEVICE column).
    private nonisolated static func listLMStudioModelsOnDevice(device: String) async -> [String] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-lc", "lms ls 2>/dev/null"]
                let out = Pipe()
                process.standardOutput = out
                process.standardError = Pipe()
                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = out.fileHandleForReading.readDataToEndOfFile()
                    let text = String(data: data, encoding: .utf8) ?? ""
                    var found: [String] = []
                    for line in text.components(separatedBy: .newlines) {
                        guard line.localizedCaseInsensitiveContains(device) else { continue }
                        // First column-ish token is model id
                        let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                        if let first = parts.first, first.count > 2, !first.hasPrefix("LLM") {
                            found.append(first)
                        }
                    }
                    cont.resume(returning: found)
                } catch {
                    cont.resume(returning: [])
                }
            }
        }
    }

    /// JoeyDGX / gx10 — SSH is the ground truth for "is the Spark connected?"
    private nonisolated static func probeDGX(node: LabNode, session: URLSession) async -> ProbeResult {
        let start = ContinuousClock.now

        async let ssh: (Bool, String?) = checkSSH(host: node.sshHost!)
        async let dash: Bool = {
            guard let url = node.dashboardURL else { return false }
            return await checkHTTPAlive(url: url, session: session)
        }()
        async let inference: (Bool, [String], String?) = checkInference(node: node, session: session)

        let (sshOK, sshErr) = await ssh
        let dashboardOK = await dash
        let (inferenceOK, models, _) = await inference

        let elapsed = start.duration(to: .now)
        let latency = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15

        let hostUp = sshOK || dashboardOK
        var parts: [String] = []
        if sshOK { parts.append("ssh") }
        if dashboardOK { parts.append("sync-dashboard") }
        if inferenceOK {
            if models.isEmpty {
                parts.append("vllm idle")
            } else if models.count == 1 {
                parts.append("vllm · \(shortModelName(models[0]))")
            } else {
                parts.append("vllm · \(models.count) serving")
            }
        }

        // NVIDIA Sync SSH (and/or dashboard tunnel) is the real connection.
        // Missing vLLM is not "degraded" — inference is reported separately.
        let detail: String
        if hostUp {
            var d = parts.isEmpty ? "sync connected" : parts.joined(separator: " · ")
            if !inferenceOK {
                d += " · inference idle"
            }
            detail = d
        } else {
            detail = sshErr ?? "unreachable"
        }

        let health: NodeHealth
        if !hostUp {
            health = .offline
        } else if sshOK {
            // Full Sync path — treat as online regardless of vLLM
            health = .online
        } else if dashboardOK {
            // Tunnel only (SSH flaky) — still connected via Sync UI path
            health = .online
        } else {
            health = .offline
        }

        return ProbeResult(
            health: health,
            latencyMs: hostUp ? latency : nil,
            models: models,
            error: hostUp ? nil : (sshErr ?? "offline"),
            sshOK: sshOK,
            dashboardOK: dashboardOK,
            inferenceOK: inferenceOK,
            detail: detail
        )
    }

    private nonisolated static func probeHTTPOnly(node: LabNode, session: URLSession) async -> ProbeResult {
        let (ok, models, err, latency) = await checkInferenceDetailed(node: node, session: session)
        if ok {
            // Never treat a huge catalog as "loaded" — only report a tight list.
            let serving = models.count > 20 ? Array(models.prefix(5)) : models
            let health: NodeHealth = .online
            let detail: String
            if models.isEmpty {
                detail = "api up · nothing serving"
            } else if models.count == 1 {
                detail = "serving · \(shortModelName(models[0]))"
            } else if models.count > 20 {
                detail = "api up · catalog (\(models.count)) ignored — not loaded list"
            } else {
                detail = "serving · \(models.count) models"
            }
            return ProbeResult(
                health: health,
                latencyMs: latency,
                models: models.count > 20 ? [] : serving,
                error: nil,
                sshOK: false,
                dashboardOK: false,
                inferenceOK: true,
                detail: detail
            )
        }
        return ProbeResult(
            health: .offline,
            latencyMs: nil,
            models: [],
            error: err,
            sshOK: false,
            dashboardOK: false,
            inferenceOK: false,
            detail: err ?? "offline"
        )
    }

    // MARK: - Checks

    private nonisolated static func checkSSH(host: String) async -> (Bool, String?) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                process.arguments = [
                    "-o", "BatchMode=yes",
                    "-o", "ConnectTimeout=3",
                    "-o", "StrictHostKeyChecking=accept-new",
                    "-o", "ConnectionAttempts=1",
                    host,
                    "echo", "ok"
                ]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()
                do {
                    try process.run()
                    process.waitUntilExit()
                    let ok = process.terminationStatus == 0
                    cont.resume(returning: (ok, ok ? nil : "ssh exit \(process.terminationStatus)"))
                } catch {
                    cont.resume(returning: (false, error.localizedDescription))
                }
            }
        }
    }

    private nonisolated static func checkHTTPAlive(url: URL, session: URLSession) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2.5
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            // Dashboard may return 200; some tunnels reset on weird paths — any HTTP response counts
            return (200...499).contains(http.statusCode)
        } catch {
            return false
        }
    }

    private nonisolated static func checkInference(
        node: LabNode,
        session: URLSession
    ) async -> (Bool, [String], String?) {
        let (ok, models, err, _) = await checkInferenceDetailed(node: node, session: session)
        return (ok, models, err)
    }

    private nonisolated static func checkInferenceDetailed(
        node: LabNode,
        session: URLSession
    ) async -> (Bool, [String], String?, Double?) {
        var candidates = [modelsURL(for: node)]
        if node.id == "pc4080" {
            let base = node.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if let tags = URL(string: base + "/api/tags") {
                candidates.append(tags)
            }
        }

        var lastError: String?
        for target in candidates {
            let start = ContinuousClock.now
            var request = URLRequest(url: target)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 3
            do {
                let (data, response) = try await session.data(for: request)
                let elapsed = start.duration(to: .now)
                let latency = Double(elapsed.components.seconds) * 1000
                    + Double(elapsed.components.attoseconds) / 1e15
                guard let http = response as? HTTPURLResponse else {
                    lastError = "No HTTP response"
                    continue
                }
                if !(200...299).contains(http.statusCode) {
                    lastError = "HTTP \(http.statusCode)"
                    continue
                }
                let models = parseModels(data)
                return (true, models, nil, latency)
            } catch is CancellationError {
                return (false, [], nil, nil)
            } catch {
                lastError = shortError(error)
            }
        }
        return (false, [], lastError, nil)
    }

    private nonisolated static func parseModels(_ data: Data) -> [String] {
        struct ModelsResponse: Decodable {
            struct Item: Decodable { let id: String? }
            let data: [Item]?
            let models: [Item]?
        }
        struct OllamaResponse: Decodable {
            struct Item: Decodable {
                let name: String?
                let model: String?
            }
            let models: [Item]?
        }

        if let decoded = try? JSONDecoder().decode(ModelsResponse.self, from: data) {
            let ids = (decoded.data ?? decoded.models ?? []).compactMap(\.id)
            if !ids.isEmpty { return ids }
        }
        if let ollama = try? JSONDecoder().decode(OllamaResponse.self, from: data) {
            let names = (ollama.models ?? []).compactMap { $0.name ?? $0.model }
            if !names.isEmpty { return names }
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let arr = obj["data"] as? [[String: Any]] {
                return arr.compactMap { $0["id"] as? String }
            }
            if obj["object"] as? String == "list" {
                return []
            }
        }
        return []
    }

    private nonisolated static func shortModelName(_ id: String) -> String {
        let base = id.split(separator: "/").last.map(String.init) ?? id
        return base.count > 28 ? String(base.prefix(25)) + "…" : base
    }

    private nonisolated static func shortError(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut: return "timeout"
            case NSURLErrorCannotConnectToHost: return "connection refused"
            case NSURLErrorNetworkConnectionLost: return "connection lost"
            case NSURLErrorNotConnectedToInternet: return "no network"
            default: break
            }
        }
        return error.localizedDescription
    }
}
