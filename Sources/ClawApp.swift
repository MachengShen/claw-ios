import SwiftData
import SwiftUI

@main
struct ClawApp: App {
    @StateObject private var webSocketManager = WebSocketManager()
    @StateObject private var notificationManager = NotificationManager()
    let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try ModelContainer(
                for: [Channel.self, Message.self],
                configurations: ModelConfiguration(
                    "ClawData",
                    isStoredInMemoryOnly: false
                )
            )
        } catch {
            fatalError("Failed to create model container: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            TabRootView()
                .modelContainer(modelContainer)
                .environmentObject(webSocketManager)
                .environmentObject(notificationManager)
        }
    }
}

private struct TabRootView: View {
    @AppStorage("gateway_url") private var gatewayURL = "ws://host:18789"
    @AppStorage("local_notifications_enabled") private var notificationsEnabled = true

    @EnvironmentObject private var webSocketManager: WebSocketManager
    @EnvironmentObject private var notificationManager: NotificationManager
    @Environment(\.modelContext) private var modelContext

    @State private var seededDefaults = false

    var body: some View {
        TabView {
            NavigationStack {
                ChannelListView()
            }
            .tabItem {
                Label("Channels", systemImage: "bubble.left.and.text.bubble.fill")
            }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
        }
        .task {
            notificationManager.isEnabled = notificationsEnabled
            await notificationManager.requestAuthorizationIfNeeded()
            webSocketManager.connect(to: gatewayURL)
            webSocketManager.onIncomingMessage = { incoming in
                Task { @MainActor in
                    persistIncoming(incoming)
                }
            }
        }
        .onAppear(perform: seedDefaultChannels)
        .onChange(of: gatewayURL) { newValue in
            webSocketManager.connect(to: newValue)
        }
        .onChange(of: notificationsEnabled) { newValue in
            notificationManager.isEnabled = newValue
        }
    }

    @MainActor
    private func persistIncoming(_ incoming: SocketIncomingMessage) {
        let descriptor = FetchDescriptor<Channel>(
            predicate: #Predicate { $0.id == incoming.channelId }
        )
        let channels = (try? modelContext.fetch(descriptor)) ?? []
        guard let channel = channels.first else {
            return
        }

        let message = Message(
            id: incoming.id,
            text: incoming.text,
            senderName: incoming.senderName,
            isFromUser: incoming.isFromUser,
            sentAt: incoming.timestamp,
            channel: channel
        )
        modelContext.insert(message)
        try? modelContext.save()

        Task {
            await notificationManager.scheduleIncomingMessageNotification(
                from: incoming.senderName,
                body: incoming.text,
                urgent: incoming.urgent
            )
        }
    }

    @MainActor
    private func seedDefaultChannels() {
        guard !seededDefaults else { return }
        seededDefaults = true

        let channels = (try? modelContext.fetch(FetchDescriptor<Channel>())) ?? []
        guard channels.isEmpty else { return }

        modelContext.insert(
            Channel(
                name: "🔒 Private",
                isPrivate: true
            )
        )
        modelContext.insert(
            Channel(
                name: "👥 Group",
                isPrivate: false
            )
        )
        try? modelContext.save()
    }
}
