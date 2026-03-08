import SwiftUI

struct SettingsView: View {
    @AppStorage("gateway_url") private var gatewayURL = "ws://127.0.0.1:18790"
    @AppStorage("gateway_token") private var gatewayToken = "82f8b644977c488228b67f843e5ad0530535d7520f6f2d5a"
    @AppStorage("default_session_key") private var defaultSessionKey = "agent:main:main"
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

                    SecureField("Gateway Token", text: $gatewayToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Default Session Key", text: $defaultSessionKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
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
