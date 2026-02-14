# iOS Capabilities and Entitlements Checklist

## Required Capabilities

### 1. Push Notifications
- [x] **Capability added**: Push Notifications enabled in Xcode project
- [x] **Entitlement**: `aps-environment` set to `development` in `AskTheAlert.entitlements`
- [ ] **Apple Developer Portal**: App ID registered with Push Notifications capability
- [ ] **Provisioning Profile**: Development profile includes Push Notifications

### 2. Background Modes
- [x] **Remote Notifications**: `UIBackgroundModes` includes `remote-notification` in `Info.plist`
  - Allows the app to receive silent push notifications and wake for processing

### 3. Microphone Access
- [x] **Usage Description**: `NSMicrophoneUsageDescription` in `Info.plist`
  - Text: "Ask the Alert needs microphone access so you can ask questions about the emergency alert using your voice."

### 4. Speech Recognition
- [x] **Usage Description**: `NSSpeechRecognitionUsageDescription` in `Info.plist`
  - Text: "Ask the Alert uses speech recognition to understand your questions about the emergency alert."

### 5. URL Scheme (Deep Links)
- [x] **URL Scheme**: `askthealert://` registered in `Info.plist` → `CFBundleURLTypes`
  - Used for deep linking from push notifications to specific incidents
  - Format: `askthealert://incident/{incidentCode}`

## Bundle ID Configuration

| Setting | Value |
|---------|-------|
| Bundle Identifier | `com.askthealert.app` |
| APNs Topic | `com.askthealert.app` (must match bundle ID) |
| Minimum iOS Version | 17.0 |
| Swift Version | 6.0 |

## Hackathon Day Setup Steps

1. **Xcode Signing**:
   - Open `ios/AskTheAlert.xcodeproj`
   - Select the `AskTheAlert` target → Signing & Capabilities
   - Choose your Apple Developer team
   - Xcode will automatically create/update the provisioning profile

2. **Enable Push Notifications** (if not already):
   - In Signing & Capabilities, click `+ Capability`
   - Add `Push Notifications`
   - Xcode will register the App ID with Apple if needed

3. **Verify Entitlements**:
   - `AskTheAlert.entitlements` should show:
     - `aps-environment` = `development` (for debug)
   - For TestFlight/production, change to `production`

4. **APNs Key**:
   - Follow instructions in `backend/certs/README.md`
   - Ensure `APNS_TEAM_ID` matches the team selected in Xcode

5. **Test Push**:
   - Build and run on a **physical device** (simulator cannot receive real pushes)
   - Check the Xcode console for the device token log: `📱 APNs device token: ...`
   - Use the Authority Console to send a test alert

## Verified in Project

- `Info.plist`: All keys present and correct
- `AskTheAlert.entitlements`: `aps-environment = development`
- `project.yml`: Entitlements path, Info.plist path, bundle ID all configured
- `AppDelegate.swift`: Requests notification permission, handles token registration and push delivery
- `PushNotificationService.swift`: Registers token with backend including environment flag
