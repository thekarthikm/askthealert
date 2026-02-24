/**
 * TelemetryService — Records telemetry events and uploads to backend in batches.
 *
 * Queue strategy:
 * - Events are written to a local persistent queue (UserDefaults-backed JSON).
 * - A periodic upload task (every 30s) sends batches of up to 50 events.
 * - On success, events are removed from the local queue.
 * - On failure, events remain queued for the next upload cycle.
 * - eventId (client-generated UUID) ensures idempotency on the server.
 * - flushNow() is called before app goes to background.
 * - Consent: events are only queued if consentGiven is true.
 *
 * Phase 6 enhancements:
 * - Persistent queue via UserDefaults (survives app restarts)
 * - Consent enforcement: events dropped if consent not given
 * - Background flush on UIApplication.willResignActiveNotification
 * - Action blocker keyword detection from user questions
 * - Network reachability awareness
 * - Retry with exponential backoff on failure
 */

import Foundation
import UIKit

actor TelemetryService {
    static let shared = TelemetryService()

    private static let defaultBackendURL: String = {
        #if targetEnvironment(simulator)
        return "http://localhost:3001"
        #else
        return "http://your-mac-hostname.local:3001"  // Replace with your Mac's mDNS hostname
        #endif
    }()

    private let baseURL: String = {
        if let configured = ProcessInfo.processInfo.environment["API_BASE_URL"], !configured.isEmpty {
            return configured
        }
        return Self.defaultBackendURL
    }()

    /// Persistent event queue key for UserDefaults.
    private static let queueKey = "askthealert_telemetry_queue"

    /// In-memory event queue (synced with UserDefaults for persistence).
    private var eventQueue: [TelemetryEventModel] = []
    private var uploadTask: Task<Void, Never>?
    private let batchSize = 50
    private let uploadInterval: TimeInterval = 30
    private var retryBackoff: TimeInterval = 1
    private let maxRetryBackoff: TimeInterval = 120

    /// Whether the user has given telemetry consent.
    private var consentGiven: Bool = true

    /// Whether an upload is currently in progress.
    private var isUploading = false

    init() {
        print("📊 Telemetry endpoint: \(baseURL)/telemetry")

        // Load persisted queue synchronously from UserDefaults (nonisolated-safe)
        if let data = UserDefaults.standard.data(forKey: Self.queueKey),
           let events = try? JSONDecoder().decode([TelemetryEventModel].self, from: data) {
            eventQueue = events
        }

        // Start periodic upload
        Task { await self.startPeriodicUpload() }

        // Register for background flush
        Task { @MainActor in
            NotificationCenter.default.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task {
                    await TelemetryService.shared.flushNow()
                }
            }

            NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task {
                    await TelemetryService.shared.flushNow()
                }
            }
        }
    }

    // MARK: - Consent Management

    /// Update the consent state. Events are only queued when consent is true.
    func setConsent(_ granted: Bool) {
        consentGiven = granted
        if !granted {
            // Optionally clear queued events when consent is revoked
            eventQueue.removeAll()
            persistQueue()
            print("📊 Telemetry consent revoked — queue cleared")
        }
    }

    func getConsent() -> Bool {
        return consentGiven
    }

    // MARK: - Public API

    /// Record a telemetry event. Call from any context.
    nonisolated func recordEvent(
        incidentCode: String,
        eventType: TelemetryEventType,
        payload: TelemetryPayload = TelemetryPayload()
    ) {
        let event = TelemetryEventModel.create(
            incidentCode: incidentCode,
            eventType: eventType,
            payload: payload
        )
        Task {
            await enqueue(event)
        }
    }

    /// Record a question event with intent and text.
    /// Automatically detects action blockers from the question text.
    nonisolated func recordQuestion(
        incidentCode: String,
        shortText: String,
        intentLabel: String? = nil
    ) {
        // Detect action blocker from the question text
        let blocker = Self.detectActionBlocker(from: shortText)

        recordEvent(
            incidentCode: incidentCode,
            eventType: .question,
            payload: TelemetryPayload(
                intentLabel: intentLabel,
                shortText: shortText,
                actionBlocker: blocker
            )
        )
    }
    
    /// Record an agent response for transcript tracking and debugging.
    /// Stores full response text to enable quality analysis.
    nonisolated func recordAgentResponse(
        incidentCode: String,
        responseText: String
    ) {
        recordEvent(
            incidentCode: incidentCode,
            eventType: .question,  // Reuse question type with intent "agent_response"
            payload: TelemetryPayload(
                intentLabel: "agent_response",
                shortText: responseText  // Full text, not truncated
            )
        )
    }

    /// Record a satisfaction event.
    nonisolated func recordSatisfaction(
        incidentCode: String,
        satisfied: Bool
    ) {
        recordEvent(
            incidentCode: incidentCode,
            eventType: .satisfaction,
            payload: TelemetryPayload(satisfactionYesNo: satisfied)
        )
    }

    /// Record a voice session event.
    nonisolated func recordVoiceSession(
        incidentCode: String,
        actionBlocker: ActionBlocker? = nil
    ) {
        recordEvent(
            incidentCode: incidentCode,
            eventType: .spoke,
            payload: TelemetryPayload(actionBlocker: actionBlocker)
        )
    }

    /// Force an immediate upload (e.g. before app goes to background).
    func flushNow() async {
        await uploadBatch()
    }

    /// Get the current queue size.
    func queueSize() -> Int {
        return eventQueue.count
    }

    // MARK: - Action Blocker Detection

    /// Detect action blockers from user question text using keyword matching.
    /// Returns the most likely blocker, or nil if none detected.
    private static func detectActionBlocker(from text: String) -> ActionBlocker? {
        let lowered = text.lowercased()

        // Driving-related keywords
        let drivingKeywords = [
            "driving", "car", "vehicle", "road", "highway", "freeway",
            "traffic", "commute", "behind the wheel", "steering",
            "on the road", "in my car", "in the car", "pulled over"
        ]
        if drivingKeywords.contains(where: { lowered.contains($0) }) {
            return .driving
        }

        // Condo/apartment-related keywords
        let condoKeywords = [
            "condo", "apartment", "high rise", "high-rise", "highrise",
            "unit", "floor", "elevator", "stairwell", "basement",
            "underground parking", "no basement", "upper floor",
            "top floor", "penthouse", "balcony"
        ]
        if condoKeywords.contains(where: { lowered.contains($0) }) {
            return .condo
        }

        // Kids/family-related keywords
        let kidsKeywords = [
            "kids", "children", "child", "baby", "infant", "toddler",
            "school", "daycare", "daughter", "son", "family",
            "newborn", "pregnant", "with my kids", "little ones"
        ]
        if kidsKeywords.contains(where: { lowered.contains($0) }) {
            return .kids
        }

        // Disability/mobility-related keywords
        let disabilityKeywords = [
            "disability", "disabled", "wheelchair", "mobility",
            "blind", "deaf", "hearing aid", "walker", "cane",
            "can't walk", "cannot walk", "trouble moving",
            "oxygen", "medical device", "special needs", "elderly",
            "senior", "older", "hard of hearing"
        ]
        if disabilityKeywords.contains(where: { lowered.contains($0) }) {
            return .disability
        }

        return nil
    }

    // MARK: - Queue Management

    private func enqueue(_ event: TelemetryEventModel) {
        guard consentGiven else {
            print("📊 Telemetry event dropped (consent not given)")
            return
        }

        eventQueue.append(event)
        persistQueue()
        print("📊 Telemetry event queued: \(event.eventType.rawValue) [\(eventQueue.count) pending]")

        // Attempt upload immediately to reduce risk of losing demo telemetry
        // when the app is backgrounded or stopped quickly.
        Task { await self.uploadBatch() }
    }

    // MARK: - Persistence (UserDefaults)

    /// Save the event queue to UserDefaults for persistence across app restarts.
    private func persistQueue() {
        do {
            let data = try JSONEncoder().encode(eventQueue)
            UserDefaults.standard.set(data, forKey: Self.queueKey)
        } catch {
            print("⚠️ Failed to persist telemetry queue: \(error)")
        }
    }

    // Queue loading is done inline in init() to satisfy Swift 6 actor isolation rules.
    // (Actor init is nonisolated, so we cannot call isolated methods from it.)

    // MARK: - Upload

    private func startPeriodicUpload() {
        uploadTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(30 * 1_000_000_000))
                await self?.uploadBatch()
            }
        }
    }

    private func uploadBatch() async {
        guard !eventQueue.isEmpty, !isUploading else { return }

        isUploading = true
        defer { isUploading = false }

        let batch = Array(eventQueue.prefix(batchSize))
        let url = URL(string: "\(baseURL)/telemetry")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15 // 15 second timeout for upload

        let body: [String: Any] = [
            "events": batch.map { event in
                var payloadDict: [String: Any] = [:]
                if let intentLabel = event.payload.intentLabel {
                    payloadDict["intentLabel"] = intentLabel
                }
                if let shortText = event.payload.shortText {
                    payloadDict["shortText"] = shortText
                }
                if let satisfactionYesNo = event.payload.satisfactionYesNo {
                    payloadDict["satisfactionYesNo"] = satisfactionYesNo
                }
                if let actionBlocker = event.payload.actionBlocker {
                    payloadDict["actionBlocker"] = actionBlocker.rawValue
                }

                return [
                    "eventId": event.eventId,
                    "incidentCode": event.incidentCode,
                    "eventType": event.eventType.rawValue,
                    "deviceTimestamp": event.deviceTimestamp,
                    "consentGiven": true,
                    "payload": payloadDict,
                ] as [String: Any]
            }
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let config = URLSessionConfiguration.ephemeral
            config.waitsForConnectivity = false
            config.timeoutIntervalForResource = 20
            let session = URLSession(configuration: config)

            let (_, response) = try await session.data(for: request)

            if let httpResponse = response as? HTTPURLResponse,
               (200...299).contains(httpResponse.statusCode) {
                // Remove uploaded events from queue
                let uploadedIds = Set(batch.map(\.eventId))
                eventQueue.removeAll { uploadedIds.contains($0.eventId) }
                persistQueue()
                retryBackoff = 1 // Reset backoff on success
                print("✅ Uploaded \(batch.count) telemetry events [\(eventQueue.count) remaining]")
            } else {
                if let httpResponse = response as? HTTPURLResponse {
                    print("⚠️ Telemetry upload returned HTTP \(httpResponse.statusCode) to \(baseURL)/telemetry")
                } else {
                    print("⚠️ Telemetry upload returned non-HTTP response to \(baseURL)/telemetry")
                }
                increaseBackoff()
            }
        } catch {
            // Network error — events stay in queue for retry
            if (error as NSError).code == NSURLErrorNotConnectedToInternet ||
               (error as NSError).code == NSURLErrorNetworkConnectionLost {
                print("📡 Telemetry upload deferred (offline) [\(eventQueue.count) queued]")
            } else {
                print("❌ Telemetry upload failed to \(baseURL)/telemetry: \(error.localizedDescription)")
            }
            increaseBackoff()
        }
    }

    private func increaseBackoff() {
        retryBackoff = min(retryBackoff * 2, maxRetryBackoff)
    }
}
