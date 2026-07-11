import Foundation
import Observation

/// One-shot gateway diagnostic: fires a tiny prompt through :4000 using the
/// node's alias, so the ping travels the same wire as any real client and
/// the node's hex goes LIT.
@MainActor
@Observable
final class PingService {
    struct Result: Equatable {
        var nodeID: String
        var summary: String
        var isError: Bool
    }

    private(set) var isPinging = false
    private(set) var result: Result?

    private let session: URLSession
    private let gatewayURL = URL(string: "http://127.0.0.1:4000/v1/chat/completions")!


    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        self.session = URLSession(configuration: config)
    }

    func clear() {
        result = nil
    }

    func ping(node: LabNode) async {
        guard !isPinging, let alias = node.pingAlias else { return }
        isPinging = true
        defer { isPinging = false }
        result = nil

        var request = URLRequest(url: gatewayURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Generous budget: reasoning models (e.g. Qwen3.6) spend tokens
        // thinking before emitting content.
        let body: [String: Any] = [
            "model": alias,
            "messages": [["role": "user", "content": "Reply with the single word: pong"]],
            "max_tokens": 256,
            "stream": false,
        ]

        let start = ContinuousClock.now
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await session.data(for: request)
            let elapsed = start.duration(to: .now)
            let ms = Double(elapsed.components.seconds) * 1000
                + Double(elapsed.components.attoseconds) / 1e15

            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                let detail = String(data: data, encoding: .utf8)?.prefix(120) ?? ""
                result = Result(nodeID: node.id, summary: "HTTP \(code) \(detail)", isError: true)
                return
            }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = (json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
            // Reasoning models may put all tokens in "reasoning" and leave content null.
            let content = (message?["content"] as? String)
                ?? (message?["reasoning"] as? String)
                ?? ""
            let completionTokens = (json?["usage"] as? [String: Any])?["completion_tokens"] as? Int

            var parts = [String(format: "%.0f ms", ms)]
            if let toks = completionTokens, ms > 0 {
                parts.append(String(format: "%.1f tok/s", Double(toks) / (ms / 1000)))
            }
            let snippet = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !snippet.isEmpty {
                parts.append("“\(snippet.count > 40 ? String(snippet.prefix(37)) + "…" : snippet)”")
            }
            result = Result(nodeID: node.id, summary: parts.joined(separator: " · "), isError: false)
        } catch {
            result = Result(nodeID: node.id, summary: error.localizedDescription, isError: true)
        }
    }
}
