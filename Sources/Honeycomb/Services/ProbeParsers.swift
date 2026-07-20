import Foundation

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
    /// Looks for a peer block: "- <name>" then "Status: connected".
    static func lmLinkPeerConnected(in text: String, name: String) -> Bool {
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

    /// The handful of vLLM Prometheus gauges the map cares about.
    static func vllmMetrics(
        fromPrometheus text: String
    ) -> (kvCachePct: Double?, running: Int?, genTotal: Double?) {
        func value(_ metric: String) -> Double? {
            for line in text.components(separatedBy: .newlines)
            where line.hasPrefix(metric) {
                if let raw = line.split(separator: " ").last {
                    return Double(raw)
                }
            }
            return nil
        }
        let kv = value("vllm:kv_cache_usage_perc").map { $0 * 100 }
        let running = value("vllm:num_requests_running").map { Int($0) }
        let genTotal = value("vllm:generation_tokens_total")
        return (kv, running, genTotal)
    }

    /// Model ids from a models-listing response: OpenAI `/v1/models`
    /// (`data[].id`), LM Studio (`models[].id`), or Ollama `/api/tags`
    /// (`models[].name` / `models[].model`).
    static func models(from data: Data) -> [String] {
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
            let isInference = ["vllm", "sglang", "llama"].contains { image.contains($0) }
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
    /// An explicit `--port` always wins; otherwise the recognized engine's default
    /// port is used (vLLM 8000, SGLang 30000, llama.cpp 8080). Both nil when no
    /// known serve command is visible — callers keep the configured baseURL then.
    static func inferenceServe(fromDockerInspect text: String) -> (engine: String?, port: Int?) {
        let lowered = text.lowercased()
        let engine: String?
        let defaultPort: Int?
        if lowered.contains("sglang") {
            engine = "sglang"
            defaultPort = 30000
        } else if lowered.contains("vllm") {
            engine = "vllm"
            defaultPort = 8000
        } else if lowered.contains("llama") {
            // llama-server / llama.cpp / llamacpp images and binaries
            engine = "llama.cpp"
            defaultPort = 8080
        } else {
            engine = nil
            defaultPort = nil
        }

        let pattern = #/--port[="',\\ \t]+([0-9]{1,5})/#
        if let match = text.firstMatch(of: pattern),
           let port = Int(match.1), (1...65535).contains(port) {
            return (engine, port)
        }
        return (engine, defaultPort)
    }
}
