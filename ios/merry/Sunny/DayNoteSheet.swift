import SwiftUI

/// The end-of-day note: say (or type) what got done that never became a
/// task, and anything tomorrow's work should know. The words are saved to
/// the Planner; Sunny reads them on its 04:30 run, logs the done work, adds
/// context to the tasks it is about, and reports back here.
struct DayNoteSheet: View {
    @EnvironmentObject var sunny: SunnyStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var recorder = VoiceNoteRecorder()
    /// Kept across launches until it is saved, so a failed save or a closed
    /// sheet never loses the words.
    @AppStorage(SunnyStore.dayNoteDraftKey) private var draft = ""
    @State private var saving = false
    @State private var saveError: String?
    @State private var justSaved = false
    @State private var deleting: DayNote?
    @FocusState private var typing: Bool

    private var shown: String { recorder.isRecording ? TranscriptAccumulator.join(draft, recorder.text) : draft }
    private var canSave: Bool { !shown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !saving }

    var body: some View {
        ZStack {
            Theme.c.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        editor
                        if let problem = recorder.problem ?? saveError {
                            Label(problem, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(Theme.c.attention)
                        }
                        earlier
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
                .scrollDismissesKeyboard(.interactively)
                controls
            }
        }
        .foregroundStyle(Theme.c.text)
        .tint(Theme.c.accent)
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(recorder.isRecording)
        .task {
            await sunny.loadDayNotes()
            if ProcessInfo.processInfo.arguments.contains("-UITestDayNoteDraft"), draft.isEmpty {
                draft = "Fixed the caravan sync on the desktop, it had been stuck since Tuesday. Talked to Anthony, he wants the scout to skip jobs under two thousand dollars. Still need to send Daksh the invoice."
            }
        }
        .onDisappear { if recorder.isRecording { draft = TranscriptAccumulator.join(draft, recorder.stop()) } }
        .confirmationDialog("Delete this note?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let note = deleting { Task { await sunny.deleteDayNote(note) } }
            }
        } message: {
            Text("Sunny hasn't read it yet, so nothing else changes.")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Day note").font(.title2.bold())
                Text(Self.dayTitle(DayNote.date(for: Date())))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { dismiss() }
                .font(.subheadline.weight(.medium))
                .frame(minWidth: 44, minHeight: 44)
                .buttonStyle(PressScale())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 6)
    }

    // MARK: - Words

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if recorder.isRecording {
                    // Read-only while listening: the transcript is still changing.
                    Text(shown.isEmpty ? "Listening…" : shown)
                        .foregroundStyle(shown.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                } else {
                    TextEditor(text: $draft)
                        .focused($typing)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 150)
                        .fixedSize(horizontal: false, vertical: true)
                    if draft.isEmpty {
                        Text("What got done today that isn't a task? What should tomorrow's work know?")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
            }
            .font(.body)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.c.surface))
            Text(justSaved
                 ? "Saved. Sunny reads it on tonight's run."
                 : "Sunny reads it overnight: done work is logged, context goes on the tasks it is about, and to-dos become tasks.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Record and save

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                typing = false
                if recorder.isRecording {
                    draft = TranscriptAccumulator.join(draft, recorder.stop())
                } else {
                    justSaved = false
                    Task { await recorder.start() }
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(Theme.c.accent.opacity(0.25))
                        .scaleEffect(recorder.isRecording && !reduceMotion ? 1 + recorder.level * 0.45 : 1)
                        .animation(.easeOut(duration: 0.12), value: recorder.level)
                    Circle().fill(recorder.isRecording ? Theme.c.attention : Theme.c.accent)
                    Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(recorder.isRecording ? Color.black : Theme.c.onAccent)
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: 60, height: 60)
                .contentShape(Circle())
            }
            .buttonStyle(PressScale())
            .accessibilityLabel(recorder.isRecording ? "Stop recording" : (draft.isEmpty ? "Record a note" : "Record more"))

            VStack(alignment: .leading, spacing: 2) {
                if let started = recorder.startedAt {
                    Text(started, style: .timer)
                        .font(.title3.monospacedDigit().weight(.semibold))
                    Text("Tap to stop").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(draft.isEmpty ? "Tap to talk" : "Tap to add more")
                        .font(.subheadline.weight(.semibold))
                    Text("Edit the words before saving").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button { save() } label: {
                Group {
                    if saving { ProgressView().tint(Theme.c.onAccent) } else { Text("Save") }
                }
                .font(.subheadline.weight(.semibold))
                .frame(width: 84, height: 44)
                .foregroundStyle(Theme.c.onAccent)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.c.accent))
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .opacity(canSave ? 1 : 0.4)
            }
            .buttonStyle(PressScale())
            .disabled(!canSave)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.c.panel.ignoresSafeArea(edges: .bottom))
    }

    private func save() {
        typing = false
        if recorder.isRecording { draft = TranscriptAccumulator.join(draft, recorder.stop()) }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        saving = true
        saveError = nil
        Task {
            do {
                try await sunny.saveDayNote(text)
                draft = ""
                justSaved = true
            } catch {
                saveError = "Not saved: \(error.localizedDescription) Your words are kept here; try again when the Planner is reachable."
            }
            saving = false
        }
    }

    // MARK: - Earlier notes

    @ViewBuilder
    private var earlier: some View {
        if !sunny.dayNotes.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("This week").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(sunny.dayNotes) { note in noteRow(note) }
            }
        }
    }

    private func noteRow(_ note: DayNote) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(Self.dayTitle(note.date)).font(.footnote.weight(.semibold))
                if let at = note.createdAt {
                    Text(at, style: .time).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                if note.isRead {
                    Label("Read by Sunny", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Waiting for tonight").font(.caption).foregroundStyle(Theme.c.attention)
                    Button { deleting = note } label: {
                        Image(systemName: "trash")
                            .font(.footnote)
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScale())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Delete this note")
                }
            }
            .frame(minHeight: 24)
            Text(note.text).font(.subheadline).textSelection(.enabled)
            if !note.lines.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(note.lines) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: line.icon).font(.footnote).foregroundStyle(.secondary).frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text([line.label, line.title].compactMap { $0 }.joined(separator: line.kind == "context" ? " " : ": "))
                                    .font(.footnote.weight(.medium))
                                Text(line.text).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.c.surface))
    }

    /// "Fri 20 Nov" for a `yyyy-MM-dd` day.
    private static func dayTitle(_ day: String) -> String {
        let parse = DateFormatter()
        parse.dateFormat = "yyyy-MM-dd"
        guard let date = parse.date(from: day) else { return day }
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_GB")
        out.dateFormat = "EEE d MMM"
        return out.string(from: date)
    }
}
