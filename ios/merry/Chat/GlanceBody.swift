import SwiftUI

/// The body of a small card or switcher tile: the one thing you scan a tile
/// for, at a size you can read. An agent tile says its state and one
/// sentence; a shell tile shows its last four lines, bottom-aligned so the
/// prompt and the latest result are what you see.
struct GlanceBody: View {
    enum Kind {
        case agent(Glance, agentName: String)
        case shell(String)
    }

    let kind: Kind

    /// An agent tile: its status row stands in for the notification ring.
    var isAgent: Bool {
        if case .agent = kind { return true }
        return false
    }

    var body: some View {
        switch kind {
        case .agent(let glance, let agentName):
            VStack(alignment: .leading, spacing: 6) {
                Text(ChatMarkdown.inline(glance.sentence))
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    GlanceStatusLabel(status: glance.status)
                    Text(agentName)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .layoutPriority(-1)
                    Spacer(minLength: 0)
                    if glance.added > 0 || glance.removed > 0 {
                        Text("+\(glance.added) −\(glance.removed)")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            // The numbers win over the agent name when a
                            // tile is narrow.
                            .fixedSize()
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 10)
            .accessibilityElement(children: .combine)
        case .shell(let text):
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)
                Text(Self.lastLines(text))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }

    /// The last four non-blank-trailing lines of a terminal mirror, each kept
    /// to one line so four lines means four rows.
    static func lastLines(_ text: String, count: Int = 4) -> String {
        var rows = text.components(separatedBy: "\n")
        while let last = rows.last, last.trimmingCharacters(in: .whitespaces).isEmpty { rows.removeLast() }
        return rows.suffix(count).map { $0.count > 80 ? String($0.prefix(80)) : $0 }.joined(separator: "\n")
    }
}

/// "Asks you", "Approve", "Waiting", "Working", "Done" as plain text after a
/// small dot. The dot is orange only when the session needs you; working
/// pulses softly in the secondary colour; done sits back in tertiary.
struct GlanceStatusLabel: View {
    let status: Glance.Status
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dotStyle)
                .frame(width: 6, height: 6)
                .opacity(status == .working && pulse ? 0.35 : 1)
                .animation(status == .working && !reduceMotion
                           ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default,
                           value: pulse)
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .fixedSize()
        .onAppear { pulse = status == .working && !reduceMotion }
        .onChange(of: status) { _, s in pulse = s == .working && !reduceMotion }
    }

    private var label: String {
        switch status {
        case .asks: return "Asks you"
        case .approve: return "Approve"
        case .waiting: return "Waiting"
        case .working: return "Working"
        case .done: return "Done"
        }
    }

    private var dotStyle: AnyShapeStyle {
        switch status {
        case .asks, .approve, .waiting: return AnyShapeStyle(Theme.c.attention)
        case .working: return AnyShapeStyle(.secondary)
        case .done: return AnyShapeStyle(.tertiary)
        }
    }
}

extension GlanceBody {
    /// The glance for a surface, or nil for a browser (which keeps its own
    /// body). An agent session with typed events gets the sentence; anything
    /// else, including an agent on a bridge without events, its last lines.
    @MainActor
    init?(surface: Surface, appState: AppState) {
        guard !surface.isBrowser else { return nil }
        if surface.hasTranscript, appState.transcriptEvents[surface.id] != nil {
            self.init(kind: .agent(appState.glance(for: surface), agentName: surface.agentKind ?? "agent"))
            return
        }
        let text = appState.cardText(for: surface)
        // Nothing read yet: let the card show its loading state.
        guard !text.isEmpty else { return nil }
        self.init(kind: .shell(text))
    }
}
