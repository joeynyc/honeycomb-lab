import Foundation

/// Engines the fleet can serve — the single source for container match
/// tokens, default API ports, and display names. Case order is detection
/// priority (a vLLM serve of a llama model must match vllm, not llama.cpp).
enum InferenceEngine: String, CaseIterable, Sendable {
    case sglang
    case vllm
    case llamaCpp = "llama.cpp"

    /// Substrings that mark a container image/command as this engine.
    var matchTokens: [String] {
        switch self {
        case .sglang: return ["sglang"]
        case .vllm: return ["vllm"]
        case .llamaCpp: return ["llama"]
        }
    }

    /// Port the engine binds when launched without an explicit --port.
    var defaultPort: Int {
        switch self {
        case .sglang: return 30000
        case .vllm: return 8000
        case .llamaCpp: return 8080
        }
    }

    var displayLabel: String {
        switch self {
        case .sglang: return "SGLang"
        case .vllm: return "vLLM"
        case .llamaCpp: return "llama.cpp"
        }
    }

    /// Prometheus gauge/counter names on the engine's /metrics endpoint.
    /// kv is a 0–1 usage ratio for all three engines.
    var metricNames: (kv: String, running: String, genTotal: String) {
        switch self {
        case .sglang:
            return ("sglang:token_usage",
                    "sglang:num_running_reqs",
                    "sglang:generation_tokens_total")
        case .vllm:
            return ("vllm:kv_cache_usage_perc",
                    "vllm:num_requests_running",
                    "vllm:generation_tokens_total")
        case .llamaCpp:
            return ("llamacpp:kv_cache_usage_ratio",
                    "llamacpp:requests_processing",
                    "llamacpp:tokens_predicted_total")
        }
    }

    static let allMatchTokens = allCases.flatMap(\.matchTokens)

    static func detect(in text: String) -> InferenceEngine? {
        let lowered = text.lowercased()
        return allCases.first { engine in
            engine.matchTokens.contains { lowered.contains($0) }
        }
    }
}

/// Pure text/JSON parsers for probe output, split out of HealthMonitor so
/// they can be unit-tested against fixtures without SSH or a live fleet.
enum ProbeParsers {
    /// Loaded models from `lms ps` output, optionally filtered by DEVICE column.
    static func lmStudioLoadedModels(
        in text: String,
        deviceFilter: String?,
        excludeDevices: [String] = []
    ) -> [String] {
        if text.localizedCaseInsensitiveContains("No models are currently loaded") {
            return []
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
            } else if excludeDevices.contains(where: { line.localizedCaseInsensitiveContains($0) }) {
                // Local hub: skip rows that belong to a remote LM Link peer
                continue
            }
            let parts = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if let id = parts.first, id.count > 2 {
                found.append(id)
            }
        }
        return found
    }

    /// Whether `lms link status` output shows the named peer as connected.
    /// Looks for a peer block: "- <name>" then "Status: connected". The
    /// status value must *start* with connected/online so "disconnected"
    /// doesn't count.
    static func lmLinkPeerConnected(in text: String, name: String) -> Bool {
        let needle = name.lowercased()
        let lines = text.components(separatedBy: .newlines)
        var inPeer = false
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("- ") {
                let label = t.dropFirst(2).trimmingCharacters(in: .whitespaces).lowercased()
                inPeer = isPeerLabel(label, name: needle)
            } else if inPeer && t.lowercased().hasPrefix("status:") {
                let value = t.dropFirst("status:".count)
                    .trimmingCharacters(in: .whitespaces).lowercased()
                return value.hasPrefix("connected") || value.hasPrefix("online")
            }
        }
        // fallback: name + the word "connected" anywhere
        return text.localizedCaseInsensitiveContains(name)
            && text.range(of: #"\bconnected\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// "- <label>" names the peer: exact, or name then a non-name character
    /// ("gaming-pc (Windows)"), so peer "pc" doesn't claim "gaming-pc".
    private static func isPeerLabel(_ label: String, name: String) -> Bool {
        guard label.hasPrefix(name) else { return false }
        guard let next = label.dropFirst(name.count).first else { return true }
        return !(next.isLetter || next.isNumber || "-_.".contains(next))
    }

    /// Models listed under a remote device in `lms ls` (DEVICE column).
    static func lmStudioModelsOnDevice(in text: String, device: String) -> [String] {
        var found: [String] = []
        for line in text.components(separatedBy: .newlines) {
            guard line.localizedCaseInsensitiveContains(device) else { continue }
            // First column-ish token is model id
            let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if let first = parts.first, first.count > 2, !first.hasPrefix("LLM") {
                found.append(first)
            }
        }
        return found
    }

    /// Output of `free -m | awk '/^Mem:/{print $3, $2}'` followed by
    /// `nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits`.
    static func hardwareMetrics(fromFreeAndSMI output: String) -> NodeMetrics? {
        let lines = output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var metrics = NodeMetrics()
        if let memLine = lines.first {
            let parts = memLine.split(separator: " ").compactMap { Int($0) }
            if parts.count == 2 {
                metrics.memUsedMB = parts[0]
                metrics.memTotalMB = parts[1]
            }
        }
        if lines.count > 1, let util = Int(lines[1]) {
            metrics.gpuUtilPct = util
        }
        return metrics
    }

    /// The handful of engine Prometheus gauges the map cares about — vLLM,
    /// SGLang, and llama.cpp names are all tried; the sets are disjoint.
    static func inferenceMetrics(
        fromPrometheus text: String
    ) -> (kvCachePct: Double?, running: Int?, genTotal: Double?) {
        func value(_ metrics: [String]) -> Double? {
            for line in text.components(separatedBy: .newlines) {
                for metric in metrics where line.hasPrefix(metric) {
                    if let raw = line.split(separator: " ").last {
                        return Double(raw)
                    }
                }
            }
            return nil
        }
        let engines = InferenceEngine.allCases
        let kv = value(engines.map(\.metricNames.kv)).map { $0 * 100 }
        let running = value(engines.map(\.metricNames.running)).map { Int($0) }
        let genTotal = value(engines.map(\.metricNames.genTotal))
        return (kv, running, genTotal)
    }

    /// Parsed models-listing JSON. `loadedOnly` is true when the payload
    /// is LM Studio's native `/api/v0/models` (items have a `state` field)
    /// so callers can show an empty list as "nothing loaded" instead of
    /// falling through to a disk catalog.
    struct ModelListing: Equatable, Sendable {
        var ids: [String]
        var loadedOnly: Bool
    }

    /// Model ids from a models-listing response: OpenAI `/v1/models`
    /// (`data[].id`), LM Studio (`models[].id` or `/api/v0/models` with
    /// `state`), or Ollama `/api/tags` (`models[].name` / `models[].model`).
    static func models(from data: Data) -> [String] {
        modelListing(from: data).ids
    }

    static func modelListing(from data: Data) -> ModelListing {
        struct ModelsResponse: Decodable {
            struct Item: Decodable {
                let id: String?
                let state: String?
            }
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
            let items = decoded.data ?? decoded.models ?? []
            let hasState = items.contains { $0.state != nil }
            if hasState {
                let loaded = items.compactMap { item -> String? in
                    guard item.state?.caseInsensitiveCompare("loaded") == .orderedSame else {
                        return nil
                    }
                    return item.id
                }
                return ModelListing(ids: loaded, loadedOnly: true)
            }
            let ids = items.compactMap(\.id)
            if !ids.isEmpty { return ModelListing(ids: ids, loadedOnly: false) }
        }
        if let ollama = try? JSONDecoder().decode(OllamaResponse.self, from: data) {
            let names = (ollama.models ?? []).compactMap { $0.name ?? $0.model }
            if !names.isEmpty { return ModelListing(ids: names, loadedOnly: false) }
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let arr = obj["data"] as? [[String: Any]] {
                return ModelListing(ids: arr.compactMap { $0["id"] as? String }, loadedOnly: false)
            }
            if obj["object"] as? String == "list" {
                return ModelListing(ids: [], loadedOnly: false)
            }
        }
        return ModelListing(ids: [], loadedOnly: false)
    }

    /// Running inference container names from `docker ps --format '{{.Names}}\t{{.Image}}'`.
    ///
    /// Picks containers whose image looks like an inference engine (vLLM, SGLang,
    /// llama.cpp — host-network boxes publish no ports, so we can't filter on
    /// publish=8000). Also includes `preferred` when that name is
    /// present and running — so a non-vLLM configured serve target still stops cleanly.
    static func runningInferenceContainers(
        dockerPs: String,
        preferred: String? = nil
    ) -> [String] {
        var names: [String] = []
        var seen = Set<String>()
        for line in dockerPs.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: "\t", maxSplits: 1).map(String.init)
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !seen.contains(name) else { continue }
            let image = parts.count > 1 ? parts[1].lowercased() : ""
            let isInference = InferenceEngine.allMatchTokens.contains { image.contains($0) }
            let isPreferred = preferred.map { name == $0 } ?? false
            if isInference || isPreferred {
                seen.insert(name)
                names.append(name)
            }
        }
        return names
    }

    /// Inference engine + API port from `docker inspect --format
    /// '{{json .Config.Entrypoint}} {{json .Config.Cmd}}'` output for the
    /// running inference container(s).
    ///
    /// Handles both arg-array form (`"--port","8888"`) and a `bash -lc "... vllm serve
    /// ... --port 8888 ..."` wrapper (the flag lives inside one escaped string).
    /// An explicit `--port` always wins; otherwise the recognized engine's
    /// default port is used. Both nil when no known serve command is visible —
    /// callers keep the configured baseURL then.
    static func inferenceServe(fromDockerInspect text: String) -> (engine: InferenceEngine?, port: Int?) {
        let engine = InferenceEngine.detect(in: text)
        if let match = text.firstMatch(of: portFlagPattern),
           let port = Int(match.1), (1...65535).contains(port) {
            return (engine, port)
        }
        return (engine, engine?.defaultPort)
    }

    // Regex isn't Sendable, but this one is immutable after init — safe to share.
    nonisolated(unsafe) private static let portFlagPattern = #/--port[="',\\ \t]+([0-9]{1,5})/#
}
