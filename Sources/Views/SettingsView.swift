import SwiftUI

struct SettingsView: View {
    @AppStorage("gateway_url") private var gatewayURL = "ws://host:18789"
    @AppStorage("local_notifications_enabled") private var notificationsEnabled = true

    @EnvironmentObject private var webSocketManager: WebSocketManager
    @EnvironmentObject private var notificationManager: NotificationManager

    var body: some View {
        NavigationStack {
            Form {
                Section("Gateway") {
                    TextField("Gateway WebSocket URL", text: $gatewayURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }

                Section("Notifications") {
                    Toggle("Enable local notifications", isOn: $notificationsEnabled)
                        .tint(.blue)
                        .onChange(of: notificationsEnabled) { enabled in
                            notificationManager.isEnabled = enabled
                            if enabled {
                                Task {
                                    await notificationManager.requestAuthorizationIfNeeded()
                                }
                            }
                        }

                    if !notificationManager.isAuthorized {
                        Button("Allow notifications") {
                            Task {
                                await notificationManager.requestAuthorizationIfNeeded()
                            }
                        }
                    }
                }

                Section("Connection") {
                    Label(webSocketManager.connectionState.rawValue, systemImage: webSocketManager.connectionState.icon)
                        .foregroundStyle(webSocketManager.connectionState == .connected ? .green : .orange)
                    if let errorMessage = webSocketManager.errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
