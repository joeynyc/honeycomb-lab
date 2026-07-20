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
    /// Recent gateway requests, newest first (traffic feed)
    private(set) var feed: [FeedEntry] = []
    var selectedNodeID: String?

    private var pollTask: Task<Void, Never>?
    /// Last seen vLLM generation-token counter per node, for tok/s deltas
    private var lastGenTokens: [String: (Date, Double)] = [:]
    /// Rolling health/latency history + state-change notifications
    let history = HealthHistory()
    /// Remote start/stop of inference containers
    let control = NodeControl()
    /// spark-doctor diagnostics for nodes that configure a doctorCommand
    let doctor = DoctorService()
    /// Starts the gateway bundled inside the .app when it isn't running
    let launcher = GatewayLauncher()
    private let session: URLSession
    private let pollInterval: Duration
    private let gatewayURL = URL(string: "http://127.0.0.1:4000/health")!

    /// Fleet description loaded from fleet.json (title, nodes, extra links)
    let fleet: FleetStore.Fleet

    init(fleet: FleetStore.Fleet = FleetStore.load(), pollInterval: Duration = .seconds(4)) {
        self.fleet = fleet
        self.nodes = fleet.nodes
        self.selectedNodeID = fleet.nodes.first(where: { !$0.isHub })?.id
            ?? fleet.nodes.first?.id
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
        async let recentRequests: [FeedEntry] = Self.fetchFeed(session: session)

        let results = await nodeResults
        let gateway = await gw
        feed = await recentRequests

        gatewayOK = gateway.ok
        gatewayDetail = gateway.detail

        for (id, result) in results {
            guard let idx = nodes.firstIndex(where: { $0.id == id }) else { continue }
            let inferenceDied = nodes[idx].inferenceOK && !result.inferenceOK
                && nodes[idx].lastChecked != nil
            nodes[idx].health = result.health
            nodes[idx].latencyMs = result.latencyMs
            nodes[idx].models = result.models
            nodes[idx].lastError = result.error
            nodes[idx].sshOK = result.sshOK
            nodes[idx].dashboardOK = result.dashboardOK
            nodes[idx].inferenceOK = result.inferenceOK
            nodes[idx].discoveredPort = result.discoveredPort
            nodes[idx].discoveredEngine = result.discoveredEngine
            nodes[idx].statusDetail = result.detail
            nodes[idx].lastChecked = Date()
            nodes[idx].metrics = computeTokRate(id: id, metrics: result.metrics)

            // Doctor overlay: online but with fresh critical findings = degraded.
            if nodes[idx].health == .online,
               let report = doctor.freshReport(for: id), report.hasCritical {
                nodes[idx].health = .degraded
            }

            let transitioned = history.record(
                nodeID: id,
                nodeName: nodes[idx].name,
                health: nodes[idx].health,
                latencyMs: result.latencyMs
            )
            // Auto-diagnose when the node can explain itself: vLLM died while
            // the host is still reachable, or the whole node just dropped
            // (the scan may still get through on a flapping link).
            let shouldDiagnose = (inferenceDied && result.sshOK)
                || (transitioned && nodes[idx].health == .offline)
            if shouldDiagnose, nodes[idx].doctorCommand != nil, nodes[idx].sshHost != nil {
                let node = nodes[idx]
                Task { await self.doctor.scan(node) }
            }
            // Lit = gateway saw traffic to this node's backend recently
            // (litAliases narrows shared backends, e.g. hub vs LM Link peer)
            nodes[idx].isStreaming = {
                guard let bid = nodes[idx].gatewayBackend,
                      let act = gateway.backendActivity[bid], act.active
                else { return false }
                if let filter = nodes[idx].litAliases, !filter.isEmpty {
                    return act.lastAlias.map { filter.contains($0) } ?? false
                }
                return true
            }()
        }
    }

    /// Turn the raw generation-token counter into tok/s using the previous poll.
    private func computeTokRate(id: String, metrics: NodeMetrics?) -> NodeMetrics? {
        guard var m = metrics else {
            lastGenTokens[id] = nil
            return nil
        }
        if let total = m.genTokensTotal {
            if let (prevDate, prevTotal) = lastGenTokens[id], total >= prevTotal {
                let dt = Date().timeIntervalSince(prevDate)
                if dt > 0.5 {
                    m.genTokPerSec = (total - prevTotal) / dt
                }
            }
            lastGenTokens[id] = (Date(), total)
        }
        return m
    }

    private struct BackendActivity: Sendable {
        var active: Bool
        var lastAlias: String?
    }

    private struct GatewaySnapshot: Sendable {
        var ok: Bool
        var detail: String
        var backendActivity: [String: BackendActivity]
    }

    /// One row of the gateway's /requests ring buffer.
    struct FeedEntry: Identifiable, Equatable, Sendable {
        var id: Double { ts }
        var ts: Double
        var alias: String?
        var backend: String
        var model: String
        var stream: Bool
        var status: Int?
        var durationMs: Double?
        var completionTokens: Int?

        var date: Date { Date(timeIntervalSince1970: ts) }
    }

    private nonisolated static func fetchFeed(session: URLSession) async -> [FeedEntry] {
        guard let url = URL(string: "http://127.0.0.1:4000/requests") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = obj["requests"] as? [[String: Any]]
        else { return [] }
        return items.compactMap { item in
            guard let ts = item["ts"] as? Double,
                  let backend = item["backend"] as? String,
                  let model = item["model"] as? String
            else { return nil }
            return FeedEntry(
                ts: ts,
                alias: item["alias"] as? String,
                backend: backend,
                model: model,
                stream: item["stream"] as? Bool ?? false,
                status: item["status"] as? Int,
                durationMs: item["duration_ms"] as? Double,
                completionTokens: item["completion_tokens"] as? Int
            )
        }
    }

    private nonisolated static func probeAll(nodes: [LabNode], session: URLSession) async -> [(String, ProbeResult)] {
        let peerNames = nodes.compactMap(\.lmLinkPeer)
        return await withTaskGroup(of: (String, ProbeResult).self) { group in
            for node in nodes {
                group.addTask {
                    let result = await Self.probe(node: node, session: session, peerNames: peerNames)
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
        // Headroom over the gateway's own worst case (one cold backend probe)
        // so a slow backend never reads as "gateway down".
        request.timeoutInterval = 4
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return GatewaySnapshot(ok: false, detail: "gateway HTTP error", backendActivity: [:])
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return GatewaySnapshot(ok: true, detail: "gateway up", backendActivity: [:])
            }
            // Generic backend activity — nodes map themselves onto it via
            // gatewayBackend / litAliases from fleet.json.
            var activity: [String: BackendActivity] = [:]
            var up = 0
            if let backends = obj["backends"] as? [String: Any] {
                for (bid, raw) in backends {
                    guard let be = raw as? [String: Any] else { continue }
                    if be["healthy"] as? Bool == true { up += 1 }
                    activity[bid] = BackendActivity(
                        active: be["active"] as? Bool ?? false,
                        lastAlias: be["last_alias"] as? String
                    )
                }
            }
            return GatewaySnapshot(
                ok: true,
                detail: "gateway :4000 · \(up) backends up",
                backendActivity: activity
            )
        } catch {
            return GatewaySnapshot(ok: false, detail: "gateway down · start gateway/start.sh", backendActivity: [:])
        }
    }

    /// Open Ghostty: SSH to remote nodes, local shell on the hub (Mac mini).
    func openSSH(_ node: LabNode) {
        if let host = node.sshHost, !host.isEmpty {
            openGhostty(arguments: ["-e", "ssh", host])
            return
        }
        if node.isHub {
            // Local interactive shell on this Mac mini
            openGhostty(arguments: ["-e", "/bin/zsh", "-i"])
            return
        }
    }

    /// Prefer Ghostty; fall back to Terminal.app if Ghostty is missing.
    private func openGhostty(arguments: [String]) {
        let ghosttyApp = "/Applications/Ghostty.app"
        if FileManager.default.fileExists(atPath: ghosttyApp) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            // -n: new instance/window · -a: app · --args forwarded to Ghostty
            process.arguments = ["-na", ghosttyApp, "--args"] + arguments
            try? process.run()
            return
        }
        // Fallback: Terminal.app
        let cmd: String
        if arguments.count >= 2, arguments[0] == "-e" {
            cmd = arguments.dropFirst().map { Self.shellEscape($0) }.joined(separator: " ")
        } else {
            cmd = ""
        }
        let script: String
        if cmd.isEmpty {
            script = "tell application \"Terminal\" to activate"
        } else {
            script = """
            tell application "Terminal"
              activate
              do script "\(cmd)"
            end tell
            """
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    private nonisolated static func shellEscape(_ s: String) -> String {
        if s.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) == nil {
            return s
        }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
        var metrics: NodeMetrics?
        var discoveredPort: Int?
        var discoveredEngine: InferenceEngine?

        init(
            health: NodeHealth,
            latencyMs: Double?,
            models: [String],
            error: String?,
            sshOK: Bool,
            dashboardOK: Bool,
            inferenceOK: Bool,
            detail: String,
            metrics: NodeMetrics? = nil,
            discoveredPort: Int? = nil,
            discoveredEngine: InferenceEngine? = nil
        ) {
            self.health = health
            self.latencyMs = latencyMs
            self.models = models
            self.error = error
            self.sshOK = sshOK
            self.dashboardOK = dashboardOK
            self.inferenceOK = inferenceOK
            self.detail = detail
            self.metrics = metrics
            self.discoveredPort = discoveredPort
            self.discoveredEngine = discoveredEngine
        }
    }

    private nonisolated static func modelsURL(for node: LabNode) -> URL {
        let base = node.inferenceBaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = node.modelsPath.hasPrefix("/") ? node.modelsPath : "/" + node.modelsPath
        return URL(string: base + path) ?? node.baseURL.appendingPathComponent("v1/models")
    }

    private nonisolated static func probe(
        node: LabNode,
        session: URLSession,
        peerNames: [String]
    ) async -> ProbeResult {
        switch node.probe {
        case .lmlinkPeer:
            return await probeLMLinkPeer(node: node, session: session)
        case .lmstudioHub:
            return await probeHub(node: node, session: session, peerNames: peerNames)
        case .vllmSSH:
            if node.sshHost != nil {
                return await probeDGX(node: node, session: session)
            }
            return await probeHTTPOnly(node: node, session: session)
        case .httpOnly:
            return await probeHTTPOnly(node: node, session: session)
        }
    }

    /// The hub — the machine the app runs on. Never list huge catalogs.
    /// Online always (we're running here). Models = currently *loaded* in LM Studio (`lms ps`).
    private nonisolated static func probeHub(
        node: LabNode,
        session: URLSession,
        peerNames: [String]
    ) async -> ProbeResult {
        let start = ContinuousClock.now

        async let server: (Bool, _, _) = checkInference(node: node, session: session)
        async let loaded: [String] = listLMStudioLoadedModels(
            deviceFilter: nil,
            excludeDevices: peerNames // local only — skip LM Link peer rows
        )
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
    private nonisolated static func listLMStudioLoadedModels(
        deviceFilter: String?,
        excludeDevices: [String] = []
    ) async -> [String] {
        let text = await lmsOutput(["ps"], cacheKey: "lms-ps")
        return ProbeParsers.lmStudioLoadedModels(
            in: text,
            deviceFilter: deviceFilter,
            excludeDevices: excludeDevices
        )
    }

    private nonisolated static func checkLMLinkSelf() async -> (Bool, String) {
        let text = await lmsOutput(["link", "status"], cacheKey: "lms-link-status")
        let online = text.localizedCaseInsensitiveContains("Status: Online")
        return (online, online ? "link self online" : "lm link offline on mini")
    }

    /// Remote GPU behind LM Link — the Link peer connection is the real path.
    /// The hub's LM Studio exposes an OpenAI API including remote Link models.
    private nonisolated static func probeLMLinkPeer(node: LabNode, session: URLSession) async -> ProbeResult {
        let start = ContinuousClock.now
        let peerName = node.lmLinkPeer ?? node.hostname

        async let ssh: (Bool, String?) = {
            guard let host = node.sshHost else { return (false, nil) }
            return await checkSSH(host: host)
        }()
        async let link: (Bool, String) = checkLMLinkPeer(name: peerName)
        async let lmsServer: (Bool, [String], String?) = checkInference(node: node, session: session)
        // Disk inventory on peer is noisy; prefer *loaded* on the peer if any.
        async let remoteLoaded: [String] = listLMStudioLoadedModels(deviceFilter: peerName)
        async let remoteDisk: [String] = listLMStudioModelsOnDevice(device: peerName)

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
            parts.append("\(loadedOnPC.count) loaded on \(peerName)")
        } else if !diskOnPC.isEmpty {
            parts.append("\(diskOnPC.count) on disk · none loaded")
        } else {
            parts.append("no model loaded on \(peerName)")
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

    /// Parse `lms link status` for a named peer.
    private nonisolated static func checkLMLinkPeer(name: String) async -> (Bool, String) {
        let text = await lmsOutput(["link", "status"], cacheKey: "lms-link-status")
        let connected = ProbeParsers.lmLinkPeerConnected(in: text, name: name)
        return (connected, connected ? "\(name) connected" : "\(name) not in link mesh")
    }

    /// Models listed under a remote device in `lms ls` (DEVICE column).
    private nonisolated static func listLMStudioModelsOnDevice(device: String) async -> [String] {
        let text = await lmsOutput(["ls"], cacheKey: "lms-ls")
        return ProbeParsers.lmStudioModelsOnDevice(in: text, device: device)
    }

    /// One SSH spawn, cached: GPU util + unified memory, plus the engine and
    /// API port of whatever inference container is actually running (vLLM,
    /// SGLang, llama.cpp) from its command line. Serves can move ports and
    /// swap engines between restarts; the configured baseURL is only a
    /// fallback when nothing can be discovered.
    /// GB10 nvidia-smi reports memory as N/A, so system memory is the truth.
    private nonisolated static func fetchHostProbe(
        host: String,
        preferredContainer: String?
    ) async -> (metrics: NodeMetrics?, engine: InferenceEngine?, port: Int?) {
        let marker = "==HONEYCOMB-DOCKER=="
        // Host-network serves publish no ports, so match by name/image instead.
        let engineTokens = InferenceEngine.allMatchTokens.joined(separator: "|")
        let cmd = "free -m | awk '/^Mem:/{print $3, $2}'; "
            + "nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits; "
            + "echo \(marker); "
            + "docker ps --format '{{.Names}} {{.Image}}'"
            + " | awk -v pref=\(shellEscape(preferredContainer ?? "")) 'tolower($0) ~ /\(engineTokens)/ || (pref != \"\" && $1 == pref) {print $1}'"
            + " | head -n 3"
            + " | xargs -r docker inspect --format '{{json .Config.Entrypoint}} {{json .Config.Cmd}}' 2>/dev/null"
            + " || true"
        let result = await SubprocessCache.shared.value(key: "hw:\(host)", ttl: 8) {
            await Subprocess.run(
                "/usr/bin/ssh",
                ["-o", "BatchMode=yes", "-o", "ConnectTimeout=3", "--", host, cmd],
                timeout: 6
            )
        }
        guard let result, result.status == 0 else { return (nil, nil, nil) }
        let parts = result.output.components(separatedBy: marker)
        let metrics = ProbeParsers.hardwareMetrics(fromFreeAndSMI: parts[0])
        let serve = parts.count > 1
            ? ProbeParsers.inferenceServe(fromDockerInspect: parts[1])
            : (engine: nil, port: nil)
        return (metrics, serve.engine, serve.port)
    }

    /// Parse the handful of engine Prometheus gauges the map cares about
    /// (vLLM, SGLang, or llama.cpp /metrics).
    private nonisolated static func fetchInferenceMetrics(
        node: LabNode,
        session: URLSession
    ) async -> (kvCachePct: Double?, running: Int?, genTotal: Double?) {
        // Trim a trailing slash — "http://host:8000/" + "/metrics" would 404
        // and silently blank the metrics bars.
        let base = node.inferenceBaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/metrics") else {
            return (nil, nil, nil)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8)
        else { return (nil, nil, nil) }

        return ProbeParsers.inferenceMetrics(fromPrometheus: text)
    }

    /// DGX-style node — SSH is the ground truth for "is the host connected?"
    private nonisolated static func probeDGX(node: LabNode, session: URLSession) async -> ProbeResult {
        let start = ContinuousClock.now

        async let ssh: (Bool, String?) = checkSSH(host: node.sshHost!)
        async let dash: Bool = {
            guard let url = node.dashboardURL else { return false }
            return await checkHTTPAlive(url: url, session: session)
        }()
        async let hostProbe: (metrics: NodeMetrics?, engine: InferenceEngine?, port: Int?) =
            fetchHostProbe(host: node.sshHost!, preferredContainer: node.container)

        // Inference is checked wherever the running serve actually listens —
        // configured baseURL is only the fallback when discovery comes up empty.
        var effective = node
        let discovered = await hostProbe
        effective.discoveredPort = discovered.port
        effective.discoveredEngine = discovered.engine
        let inference = await checkInference(node: effective, session: session)

        let (sshOK, sshErr) = await ssh
        let dashboardOK = await dash
        let (inferenceOK, models, _) = inference
        var metrics = discovered.metrics
        if inferenceOK {
            let serve = await fetchInferenceMetrics(node: effective, session: session)
            if metrics == nil { metrics = NodeMetrics() }
            metrics?.kvCachePct = serve.kvCachePct
            metrics?.runningRequests = serve.running
            metrics?.genTokensTotal = serve.genTotal
        }

        let elapsed = start.duration(to: .now)
        let latency = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15

        let hostUp = sshOK || dashboardOK
        var parts: [String] = []
        if sshOK { parts.append("ssh") }
        if dashboardOK { parts.append("sync-dashboard") }
        if inferenceOK {
            let engine = (effective.discoveredEngine ?? .vllm).rawValue
            if models.isEmpty {
                parts.append("\(engine) idle")
            } else if models.count == 1 {
                parts.append("\(engine) · \(shortModelName(models[0]))")
            } else {
                parts.append("\(engine) · \(models.count) serving")
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
            detail: detail,
            metrics: hostUp ? metrics : nil,
            discoveredPort: effective.discoveredPort,
            discoveredEngine: effective.discoveredEngine
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

    // MARK: - Subprocess helpers (shared runner lives in Subprocess.swift)

    /// `lms` CLI location — invoked directly, never via a login shell.
    private nonisolated static let lmsPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.lmstudio/bin/lms",
            "/opt/homebrew/bin/lms",
            "/usr/local/bin/lms",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "/usr/bin/false"
    }()

    private nonisolated static func lmsOutput(_ args: [String], cacheKey: String) async -> String {
        let result = await SubprocessCache.shared.value(key: cacheKey, ttl: 15) {
            await Subprocess.run(lmsPath, args, timeout: 8, mergeStderr: true)
        }
        return result?.output ?? ""
    }

    // MARK: - Checks

    private nonisolated static func checkSSH(host: String) async -> (Bool, String?) {
        let result = await SubprocessCache.shared.value(key: "ssh:\(host)", ttl: 10) {
            await Subprocess.run(
                "/usr/bin/ssh",
                [
                    "-o", "BatchMode=yes",
                    "-o", "ConnectTimeout=3",
                    "-o", "StrictHostKeyChecking=accept-new",
                    "-o", "ConnectionAttempts=1",
                    "--",
                    host,
                    "echo", "ok",
                ],
                timeout: 6
            )
        }
        guard let result else { return (false, "ssh timeout") }
        let ok = result.status == 0
        return (ok, ok ? nil : "ssh exit \(result.status)")
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
        if node.probe == .lmlinkPeer {
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
                let models = ProbeParsers.models(from: data)
                return (true, models, nil, latency)
            } catch is CancellationError {
                return (false, [], nil, nil)
            } catch {
                lastError = shortError(error)
            }
        }
        return (false, [], lastError, nil)
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
