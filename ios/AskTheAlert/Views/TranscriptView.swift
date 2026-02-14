/**
 * TranscriptView — Scrollable, minimal transcript of the voice conversation.
 *
 * Shows alternating user (citizen) and agent (AI) messages.
 * Auto-scrolls to the newest entry.
 */

import SwiftUI

/// A single transcript entry.
struct TranscriptEntry: Identifiable, Equatable {
    let id: UUID
    let role: Role
    let text: String
    let timestamp: Date

    enum Role: String {
        case user = "You"
        case agent = "Alert AI"
    }

    init(role: Role, text: String) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.timestamp = Date()
    }
}

struct TranscriptView: View {
    let entries: [TranscriptEntry]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(entries) { entry in
                        TranscriptBubble(entry: entry)
                            .id(entry.id)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 8)
            }
            .onChange(of: entries.count) { _, _ in
                if let last = entries.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemBackground))
        )
    }
}

private struct TranscriptBubble: View {
    let entry: TranscriptEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.role.rawValue)
                .font(.caption2)
                .foregroundStyle(entry.role == .agent ? .blue : .secondary)
                .fontWeight(.semibold)

            Text(entry.text)
                .font(.callout)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

#Preview {
    TranscriptView(entries: [
        TranscriptEntry(role: .agent, text: "A Tornado Warning has been issued for Waterloo Region. How can I help you stay safe?"),
        TranscriptEntry(role: .user, text: "Where should I go? I'm in a condo."),
        TranscriptEntry(role: .agent, text: "Go to the lowest interior room away from windows. A bathroom or closet in your condo is safest."),
    ])
    .frame(height: 200)
    .padding()
}
