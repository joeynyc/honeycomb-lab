import SwiftUI

struct ChatPanel: View {
    @Bindable var chat: ChatService
    let node: LabNode?
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("PLAYGROUND")
                    .font(LabTheme.monoTiny)
                    .tracking(2)
                    .foregroundStyle(LabTheme.amber)
                Spacer()
                if let node {
                    Text("→ \(node.name)")
                        .font(LabTheme.monoTiny)
                        .foregroundStyle(LabTheme.phosphorDim)
                }
                Button("CLR") {
                    chat.clear()
                }
                .font(LabTheme.monoTiny)
                .foregroundStyle(LabTheme.textMuted)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().overlay(LabTheme.amberDim.opacity(0.35))

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if chat.messages.isEmpty {
                            Text("Select a live node and send a prompt.\nUses OpenAI-compatible /v1/chat/completions.")
                                .font(LabTheme.monoSmall)
                                .foregroundStyle(LabTheme.textMuted)
                                .padding(.top, 8)
                        }
                        ForEach(chat.messages) { msg in
                            messageBubble(msg)
                                .id(msg.id)
                        }
                    }
                    .padding(14)
                }
                .onChange(of: chat.messages.last?.content) { _, _ in
                    if let id = chat.messages.last?.id {
                        withAnimation {
                            proxy.scrollTo(id, anchor: .bottom)
                        }
                    }
                }
            }

            if let err = chat.streamError {
                Text(err)
                    .font(LabTheme.monoTiny)
                    .foregroundStyle(LabTheme.alert)
                    .padding(.horizontal, 14)
                    .lineLimit(2)
            }

            Divider().overlay(LabTheme.amberDim.opacity(0.35))

            HStack(spacing: 8) {
                TextField("prompt…", text: $draft, axis: .vertical)
                    .font(LabTheme.monoSmall)
                    .textFieldStyle(.plain)
                    .foregroundStyle(LabTheme.text)
                    .lineLimit(1...4)
                    .onSubmit { Task { await send() } }

                Button {
                    Task { await send() }
                } label: {
                    Text(chat.isStreaming ? "…" : "SEND")
                        .font(LabTheme.monoTiny)
                        .tracking(1)
                        .foregroundStyle(canSend ? LabTheme.bg : LabTheme.dim)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(canSend ? LabTheme.phosphor : LabTheme.amberDim.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
            .padding(12)
        }
        .background(LabTheme.panel)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(LabTheme.amberDim.opacity(0.45), lineWidth: 1)
        )
    }

    private var canSend: Bool {
        guard let node else { return false }
        return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !chat.isStreaming
            && node.canChat
    }

    private func send() async {
        guard let node else { return }
        let text = draft
        draft = ""
        await chat.send(prompt: text, to: node)
    }

    private func messageBubble(_ msg: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(msg.role.uppercased())
                .font(LabTheme.monoTiny)
                .foregroundStyle(msg.role == "user" ? LabTheme.amber : LabTheme.phosphorDim)
            Text(msg.content.isEmpty && msg.role == "assistant" ? "▍" : msg.content)
                .font(LabTheme.monoSmall)
                .foregroundStyle(LabTheme.text)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 2)
                .fill(LabTheme.bgElevated.opacity(0.8))
        )
    }
}
