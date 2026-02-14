/**
 * NotificationPermissionView — Full-screen permission request UX.
 *
 * Shown when notification permission is denied or undetermined.
 * Explains why notifications are critical for emergency alerts.
 * Provides a button to open Settings (if denied) or request permission (if undetermined).
 */

import SwiftUI
import UserNotifications

struct NotificationPermissionView: View {
    @Binding var isPresented: Bool
    @State private var permissionStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Icon
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 60))
                .foregroundStyle(.red)

            // Title
            Text("Enable Notifications")
                .font(.title2)
                .fontWeight(.bold)

            // Description
            Text("Ask the Alert uses push notifications to deliver emergency alerts. Without notifications, you won't receive critical safety information in real time.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            // Benefits
            VStack(alignment: .leading, spacing: 12) {
                PermissionBenefit(
                    icon: "exclamationmark.triangle.fill",
                    color: .red,
                    text: "Receive emergency alerts instantly"
                )
                PermissionBenefit(
                    icon: "speaker.wave.2.fill",
                    color: .blue,
                    text: "Voice AI starts automatically on alert"
                )
                PermissionBenefit(
                    icon: "arrow.clockwise",
                    color: .orange,
                    text: "Get real-time updates from authorities"
                )
            }
            .padding(.horizontal, 40)

            Spacer()

            // Action button
            if permissionStatus == .denied {
                Button(action: openSettings) {
                    HStack {
                        Image(systemName: "gear")
                        Text("Open Settings")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.red)
                    .foregroundColor(.white)
                    .cornerRadius(14)
                }
                .padding(.horizontal, 32)

                Text("Tap to enable notifications in Settings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button(action: requestPermission) {
                    HStack {
                        Image(systemName: "bell.fill")
                        Text("Enable Notifications")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.red)
                    .foregroundColor(.white)
                    .cornerRadius(14)
                }
                .padding(.horizontal, 32)
            }

            Button("Not Now") {
                isPresented = false
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.bottom, 16)
        }
        .task {
            await checkPermissionStatus()
        }
    }

    private func checkPermissionStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        permissionStatus = settings.authorizationStatus
    }

    private func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            DispatchQueue.main.async {
                if granted {
                    UIApplication.shared.registerForRemoteNotifications()
                    isPresented = false
                } else {
                    // Update status to show "Open Settings" button
                    Task {
                        await checkPermissionStatus()
                    }
                }
            }
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

private struct PermissionBenefit: View {
    let icon: String
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 24)
            Text(text)
                .font(.subheadline)
        }
    }
}

#Preview {
    NotificationPermissionView(isPresented: .constant(true))
}
