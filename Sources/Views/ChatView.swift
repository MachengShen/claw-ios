import SwiftData
import SwiftUI

struct ChatView: View {
    let channel: Channel

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var webSocketManager: WebSocketManager
    @Query private var messages: [Message]

    init(channel: Channel) {
        self.channel = channel
        let channelId = channel.id
        _messages = Query(
            filter: #Predicate<Message> { message in
                message.channel?.id == channelId
            },
            sort: \Message.sentAt
        )
    }

    @State private var draft = ""
    @State private var isSubmitting = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(.systemBackground))
                .onAppear {
                    if let last = messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...6)

                Button {
                    sendMessage()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.title3)
                        .foregroundStyle(isSubmitting ? Color.secondary : Color.white)
                        .padding(10)
                        .background(isSubmitting ? Color.gray : Color.accentColor)
                        .clipShape(Circle())
                }
                .disabled(isSubmitting || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
        }
        .navigationTitle(channel.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sendMessage() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        isSubmitting = true

        let outgoing = Message(text: text, senderName: "You", isFromUser: true, channel: channel)
        modelContext.insert(outgoing)
        webSocketManager.send(text: text, to: channel.id, senderName: "You")
        isSubmitting = false
        try? modelContext.save()
    }
}

private struct MessageBubble: View {
    let message: Message

    var body: some View {
        let isOwn = message.isFromUser
        HStack {
            if isOwn { Spacer(minLength: 80) }

            VStack(alignment: .leading, spacing: 4) {
                if !isOwn {
                    Text(message.senderName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                let rendered = (try? AttributedString(markdown: message.text)) ?? AttributedString(message.text)
                Text(rendered)
                    .foregroundStyle(isOwn ? .white : .primary)
            }
            .padding(12)
            .background(isOwn ? Color.blue : Color(.secondarySystemFill))
            .foregroundStyle(isOwn ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            if !isOwn { Spacer(minLength: 80) }
        }
    }
}
