import Foundation
import Observation

struct ChatMessage: Identifiable, Equatable, Sendable {
    let id: UUID
    let role: String
    var content: String
    let nodeID: String?

    init(id: UUID = UUID(), role: String, content: String, nodeID: String? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.nodeID = nodeID
    }
}

@MainActor
@Observable
final class ChatService {
    private(set) var messages: [ChatMessage] = []
    private(set) var isStreaming = false
    private(set) var streamError: String?

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    func clear() {
        messages = []
        streamError = nil
    }

    func send(prompt: String, to node: LabNode) async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }

        messages.append(ChatMessage(role: "user", content: trimmed, nodeID: node.id))
        let assistantID = UUID()
        messages.append(ChatMessage(id: assistantID, role: "assistant", content: "", nodeID: node.id))
        isStreaming = true
        streamError = nil
        defer { isStreaming = false }

        let model = node.models.first ?? "default"
        let url = node.baseURL.appending(path: "v1/chat/completions")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": [
                ["role": "user", "content": trimmed]
            ]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (bytes, response) = try await session.bytes(for: request)

            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                var errData = Data()
                for try await b in bytes { errData.append(b) }
                let msg = String(data: errData, encoding: .utf8) ?? "HTTP \(http.statusCode)"
                streamError = msg
                updateAssistant(id: assistantID, append: "⚠️ \(msg)")
                return
            }

            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let data = payload.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let first = choices.first
                else { continue }

                var token = ""
                if let delta = first["delta"] as? [String: Any],
                   let content = delta["content"] as? String {
                    token = content
                } else if let message = first["message"] as? [String: Any],
                          let content = message["content"] as? String {
                    token = content
                } else if let text = first["text"] as? String {
                    token = text
                }

                if !token.isEmpty {
                    updateAssistant(id: assistantID, append: token)
                }
            }

            if let idx = messages.firstIndex(where: { $0.id == assistantID }),
               messages[idx].content.isEmpty {
                updateAssistant(id: assistantID, append: "(empty response)")
            }
        } catch {
            streamError = error.localizedDescription
            updateAssistant(id: assistantID, append: "\n⚠️ \(error.localizedDescription)")
        }
    }

    private func updateAssistant(id: UUID, append: String) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].content += append
    }
}
