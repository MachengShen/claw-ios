import SwiftData
import SwiftUI

struct ChannelListView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var webSocketManager: WebSocketManager
    @Query(sort: \Channel.createdAt, order: .forward) private var channels: [Channel]

    @State private var creatingChannel = false
    @State private var newChannelName = ""

    var body: some View {
        List {
            if channels.isEmpty {
                Text("No channels yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(channels) { channel in
                    NavigationLink(destination: ChatView(channel: channel)) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(channel.name)
                                    .font(.headline)
                                Spacer()
                                if channel.unreadCount > 0 {
                                    Text(String(channel.unreadCount))
                                        .font(.caption.bold())
                                        .padding(6)
                                        .background(Color.red)
                                        .foregroundStyle(.white)
                                        .clipShape(.capsule)
                                }
                            }

                            if let last = channel.lastMessage {
                                Text(last.text)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Text(last.sentAt.formatted(.dateTime.hour().minute()))
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            } else {
                                Text("Tap to start chatting")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle("Channels")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    creatingChannel = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .alert("New Channel", isPresented: $creatingChannel) {
            TextField("Channel name", text: $newChannelName)
            Button("Create") {
                let trimmed = newChannelName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                modelContext.insert(Channel(name: trimmed, isPrivate: false))
                newChannelName = ""
                try? modelContext.save()
            }
            Button("Cancel", role: .cancel) {
                newChannelName = ""
            }
        } message: {
            Text("Create a new chat channel")
        }
        .overlay(alignment: .bottomTrailing) {
            if webSocketManager.connectionState != .connected {
                Label(webSocketManager.connectionState.rawValue, systemImage: webSocketManager.connectionState.icon)
                    .font(.caption)
                    .padding(8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding()
            }
        }
    }
}
