# Ask the Alert

Ask the Alert turns an alert into action by voice, even offline, and turns citizen questions into real-time signal so authorities can publish better updates and improve procedures based on what people actually need.

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

1. Open `ios/AskTheAlert.xcodeproj` in Xcode
2. Select your signing team
3. Build and run on a simulator or device

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
│   │       └── tornado_guidance.json # Offline RAG corpus (12 chunks)
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

## Key Design Decisions

- **Backend DB**: Supabase Postgres only (pgvector for online RAG). SQLite is not used on the server.
- **Offline corpus**: Bundled JSON in iOS app bundle, loaded at startup, keyword + synonym retrieval over in-memory chunks.
- **Telemetry queue**: CoreData for local event queue (SQLite-backed under the hood).
- **Shared types**: npm workspace (`@askthealert/shared`) imported by backend and console.
- **APNs auth**: Token-based (`.p8` key), supports dev/prod environments.
