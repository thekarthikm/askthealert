# Ask the Alert

**Ask the Alert** transforms emergency alerts into intelligent, voice-first conversations that work even offline. Citizens ask questions and get instant, accurate safety guidance. Authorities see what people need in real-time and publish targeted updates based on actual citizen questions.

## 🎯 Built with RunAnywhere.ai

This project deeply integrates **RunAnywhere SDK** for on-device AI, enabling:
- **Offline voice agent**: Full STT → LLM → TTS pipeline runs locally on iPhone
- **1.2B parameter model**: Fast, efficient responses even without internet
- **Privacy-first**: All voice processing happens on-device, no cloud dependency
- **Sub-second latency**: Real-time conversational experience during emergencies

RunAnywhere powers the entire voice interaction pipeline, making Ask the Alert reliable when networks are congested or unavailable during disasters.

## ✨ Features

### For Citizens
- **Voice-first interaction**: Ask questions naturally, get spoken answers immediately
- **Works offline**: RunAnywhere SDK enables full STT, LLM, and TTS on-device
- **Contextual guidance**: Hybrid RAG system combines offline corpus with real-time authority updates
- **Personalized answers**: System adapts to user context (e.g., high-rise vs. house, with pets, etc.)
- **Immediate safety info**: Sub-second response times during critical emergencies

### For Authorities
- **Real-time intelligence**: See what citizens are asking as it happens
- **Intent clustering**: Questions auto-grouped by topic (shelter, evacuation, family safety, etc.)
- **Targeted updates**: Publish updates that address actual citizen needs
- **Session transcripts**: Full voice conversation logs for quality analysis
- **Metrics dashboard**: Track engagement, satisfaction, and response quality

### Technical Highlights
- **Hybrid RAG**: Offline BM25 keyword search + online pgvector semantic search
- **Fallback safety guidance**: Critical tornado instructions trigger when RAG fails
- **PII redaction**: Server-side text sanitization before storage
- **Telemetry pipeline**: Batch uploads with retry logic, persisted queue
- **Push notifications**: APNs for alert delivery, silent updates for new authority messages

## Architecture

| Component | Tech | Location |
|-----------|------|----------|
| iOS App | SwiftUI, RunAnywhere SDK | `ios/` |
| Backend | Node.js, Express 5, TypeScript | `backend/` |
| Authority Console | Next.js 16, React 19, Tailwind CSS 4 | `authority-console/` |
| Shared Types | TypeScript | `shared/` |
| Database | Supabase Postgres (pgvector) | Hosted |

## Quick Start

### Prerequisites

- Node.js 22+ (`node --version`)
- Xcode 15.2+ (for iOS development)
- Supabase project (for backend database)
- Apple Developer account (for APNs)

### 1. Install Dependencies

```bash
npm install          # Installs all workspaces (shared, backend, console)
npm run build:shared # Build shared types (must be done first)
```

### 2. Backend

```bash
cp backend/.env.example backend/.env
# Edit backend/.env with your Supabase and APNs credentials

npm run dev:backend  # Starts backend on http://localhost:3001
```

### 3. Authority Console

```bash
cp authority-console/.env.local.example authority-console/.env.local
# Edit .env.local with your backend URL and auth secret

npm run dev:console  # Starts console on http://localhost:3000
```

### 4. iOS App

**Important**: The app uses RunAnywhere SDK for on-device AI. Models are downloaded automatically on first launch (requires ~2GB storage).

1. Open `ios/AskTheAlert.xcodeproj` in Xcode
2. Edit the Run scheme → Arguments → Environment Variables:
   - `API_BASE_URL` = `http://YOUR_MAC_IP:3001` (for physical device testing)
   - Use `http://localhost:3001` for simulator
   - Or use mDNS: `http://YOUR-HOSTNAME.local:3001` for stable connectivity
3. Select your signing team (requires Apple Developer account)
4. Build and run on a physical device (simulator works but device is recommended for voice testing)

**First Launch**: RunAnywhere will download models (~2GB). This takes 5-10 minutes on first run. Subsequent launches are instant.

## Project Structure

```
askthealert/
├── ios/                              # iOS app (SwiftUI)
│   ├── AskTheAlert/
│   │   ├── AskTheAlertApp.swift      # App entry point
│   │   ├── AppDelegate.swift         # APNs registration + push handling
│   │   ├── AppState.swift            # Observable global state
│   │   ├── ContentView.swift         # Root view
│   │   ├── Models/
│   │   │   ├── AlertModel.swift      # Alert type (Swift mirror)
│   │   │   ├── UpdateModel.swift     # Update type
│   │   │   ├── TelemetryEvent.swift  # Telemetry event type
│   │   │   └── Incident.swift        # Incident aggregate
│   │   ├── Views/
│   │   │   ├── IncidentView.swift    # Voice-first incident screen
│   │   │   ├── VoiceWaveformView.swift # Audio waveform visualisation
│   │   │   └── TranscriptView.swift  # Conversation transcript
│   │   ├── ViewModels/
│   │   │   └── IncidentViewModel.swift
│   │   ├── Services/
│   │   │   ├── PushNotificationService.swift
│   │   │   ├── TelemetryService.swift
│   │   │   ├── RAGService.swift      # Hybrid offline + online retrieval
│   │   │   ├── VoiceAgentService.swift
│   │   │   └── RunAnywhereManager.swift # SDK init & model management
│   │   └── Resources/
│   │       └── tornado_guidance.json # Offline RAG corpus (45 chunks, tornado safety)
│   └── AskTheAlert.xcodeproj
│
├── backend/                          # Node.js/Express backend
│   ├── src/
│   │   ├── server.ts                 # Express app + routes
│   │   ├── config/
│   │   │   └── env.ts               # Zod-validated env vars
│   │   ├── routes/
│   │   │   ├── alerts.ts            # POST /alerts (send push)
│   │   │   ├── updates.ts           # POST /updates (publish update)
│   │   │   ├── telemetry.ts         # POST /telemetry (ingest events)
│   │   │   ├── devices.ts           # POST /devices (register token)
│   │   │   └── retrieve.ts          # POST /retrieve (online RAG)
│   │   ├── services/
│   │   │   ├── apns.ts              # APNs push sender
│   │   │   ├── database.ts          # Supabase Postgres client
│   │   │   └── intentGrouping.ts    # Rule-based intent classification
│   │   └── middleware/
│   │       └── auth.ts              # Console auth middleware
│   ├── certs/                        # APNs .p8 key (gitignored)
│   └── package.json
│
├── authority-console/                # React/Next.js web app
│   ├── app/
│   │   ├── page.tsx                 # Main dashboard
│   │   ├── layout.tsx               # Root layout with nav
│   │   ├── incidents/page.tsx       # Incident list
│   │   ├── alerts/new/page.tsx      # Alert composer
│   │   └── updates/page.tsx         # Update publisher
│   ├── components/
│   │   ├── MetricsDashboard.tsx     # Telemetry metrics display
│   │   └── QuestionClusters.tsx     # Intent cluster display
│   ├── lib/
│   │   └── api.ts                   # Backend API client
│   └── package.json
│
├── shared/                           # Shared TypeScript types
│   ├── src/
│   │   ├── index.ts                 # Barrel export
│   │   ├── alert.ts                 # Alert, AlertSeverity, AlertPushPayload
│   │   ├── update.ts               # Update, UpdateSource, UpdatePushPayload
│   │   ├── telemetry-event.ts      # TelemetryEvent, StoredTelemetryEvent
│   │   ├── intent.ts               # IntentCategory, INTENT_LABELS, IntentCluster
│   │   ├── device.ts               # Device, DeviceRegistrationRequest
│   │   └── incident.ts             # Incident, IncidentStatus
│   └── package.json
│
└── package.json                      # Root workspace config
```

## 🚀 RunAnywhere SDK Integration

### Voice Agent Pipeline
The entire voice interaction is powered by RunAnywhere:

1. **Speech-to-Text (STT)**: User speech → text transcription on-device
2. **RAG Context Injection**: Hybrid retrieval injects safety guidance into prompt
3. **LLM Response**: 1.2B parameter model generates contextual answer locally
4. **Text-to-Speech (TTS)**: Response spoken back to user immediately

### Key Implementation Details

**Model Management** (`RunAnywhereManager.swift`)
- Auto-downloads models on first launch (~2GB, one-time)
- Manages model lifecycle and status monitoring
- Handles offline-first operation with graceful degradation

**Voice Agent Service** (`VoiceAgentService.swift`)
- Integrates RunAnywhere STT, LLM, and TTS pipelines
- Implements conversation state management
- Builds dynamic system prompts with RAG context
- Handles VAD (Voice Activity Detection) for natural turn-taking

**RAG Service** (`RAGService.swift`)
- Offline: BM25 scoring over 45-chunk tornado corpus
- Online: pgvector semantic search for authority updates
- Hybrid merge strategy prioritizes fresh authority content
- Fallback safety guidance when retrieval fails

### Why RunAnywhere?

Traditional cloud-based voice agents fail during emergencies when:
- Networks are congested or down
- Cell towers are overloaded
- Internet infrastructure is damaged

RunAnywhere enables **offline-first emergency response** with zero cloud dependency for voice interactions.

## Key Design Decisions

- **On-device AI**: RunAnywhere SDK for complete offline voice agent capability
- **Backend DB**: Supabase Postgres only (pgvector for online RAG). SQLite is not used on the server.
- **Offline corpus**: Bundled JSON in iOS app bundle, loaded at startup, keyword + synonym retrieval over in-memory chunks.
- **Telemetry queue**: Persistent queue with retry logic, uploads when network available
- **Shared types**: npm workspace (`@askthealert/shared`) imported by backend and console.
- **APNs auth**: Token-based (`.p8` key), supports dev/prod environments.
- **mDNS networking**: Stable device-to-Mac connectivity using `.local` hostnames

## 📱 How It Works: Demo Flow

### 1. Alert Delivery
Authority sends tornado warning via console → Backend sends APNs push → User receives alert notification

### 2. Voice Conversation (100% Offline with RunAnywhere)
User opens alert → Taps microphone → Asks: "What should I do now?"

**Behind the scenes:**
- VAD detects speech end
- RunAnywhere STT transcribes question on-device
- RAG retrieves relevant tornado safety chunks (offline BM25 + online semantic)
- System prompt built with RAG context
- RunAnywhere LLM generates answer locally (1.2B model)
- RunAnywhere TTS speaks response immediately
- Telemetry logged and queued for upload

### 3. Authority Intelligence
Backend receives telemetry → Classifies intent (shelter_guidance, evacuation, pets, etc.) → Groups similar questions → Authority sees real-time dashboard with question clusters and session transcripts

### 4. Targeted Updates
Authority publishes update addressing common questions → Push notification → Users get updated guidance in next conversation turn

## 🧪 Testing

### Send a Test Alert
```bash
curl -X POST http://localhost:3001/alerts \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer Ata-waterloo-26" \
  -d '{
    "incidentCode": "TOR-2026-TEST-001",
    "title": "Tornado Warning",
    "body": "Tornado warning issued for Waterloo Region. Take shelter immediately.",
    "severity": "critical",
    "hazardType": "tornado",
    "affectedArea": "Waterloo Region"
  }'
```

### Test Questions to Ask
1. "What should I do now?" → Basic shelter guidance
2. "I don't have a basement, I live in a high-rise building" → High-rise specific instructions
3. "Should I leave now?" → Clarifies to go to shelter area immediately
4. "Should I take my dog with me to the shelter area?" → Pet safety guidance

### Check Telemetry
Open Authority Console at `http://localhost:3000` → View incidents → See session transcripts and intent clusters

## 🏆 AI Agents Hackathon Sponsor Integration

This project uses **RunAnywhere.ai** as the foundation for the entire voice agent pipeline. The integration is deep and essential:

- **Core functionality**: All voice interactions require RunAnywhere
- **Offline capability**: RunAnywhere enables the emergency-critical offline mode
- **Performance**: Sub-second STT/LLM/TTS latency for real-time conversation
- **Privacy**: On-device processing means no voice data leaves the iPhone

Without RunAnywhere, this project would require cloud APIs that fail during emergencies when networks are unavailable.

## 📄 License

MIT License - see LICENSE file for details

## 🙏 Acknowledgments

- **RunAnywhere.ai** for enabling offline-first voice AI
- Environment Canada for tornado safety guidance
- Region of Waterloo Emergency Management for local context
