import SwiftUI

/// Sunny's morning digest as a deck: one decision at a time. Swipe right for
/// the card's main action (on a question, the answer field), left for
/// "later"; the buttons underneath do the rest. "Show more" opens the task
/// behind a card, and the Decided chip lists what has been answered so far.
/// Reached from the sidebar tab and from the pinned card in the surface
/// switcher, while Marlin decides which he prefers.
struct SunnyView: View {
    @EnvironmentObject var sunny: SunnyStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The digest page opens here, over Sunny (see SunnyDetailSheet.web).
    @State private var web: LinkSheetTarget?
    /// Set when shown over the switcher; shows a close button.
    var onClose: (() -> Void)? = nil

    @State private var filter: SunnyItem.Kind?
    @State private var drag: CGSize = .zero
    @State private var draft = ""
    /// The review card's text field is open (a follow-up or a redo).
    @State private var redoing = false
    @State private var replyIsRedo = false
    @State private var lastDone: (item: SunnyItem, outcome: String)?
    /// Cards on their way out while the decision saves; hidden at once so a
    /// slow Planner write doesn't leave the card hanging mid-swipe.
    @State private var leaving: Set<String> = []
    @State private var showingDecided = false
    @State private var detail: SunnyItem?
    @State private var showingDayNote = false
    @FocusState private var fieldFocused: Bool

    private var deck: [SunnyItem] { sunny.pending(filter).filter { !leaving.contains($0.id) } }

    var body: some View {
        ZStack {
            Theme.c.background.ignoresSafeArea()
            VStack(spacing: 12) {
                header
                if sunny.digest != nil { kindChips }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !showingDecided, let top = deck.first { actionBar(top) }
            }
            .padding(.top, 8)
        }
        .foregroundStyle(Theme.c.text)
        .tint(Theme.c.accent)
        // Swiping down anywhere puts the keyboard away.
        .simultaneousGesture(
            DragGesture(minimumDistance: 20).onEnded { value in
                let t = value.translation
                if fieldFocused, t.height > 40, t.height > abs(t.width) * 1.5 { fieldFocused = false }
            }
        )
        .sheet(item: $web) { target in
            SafariSheet(url: target.url) { web = nil }.ignoresSafeArea()
        }
        .sheet(item: $detail) { item in
            SunnyDetailSheet(item: item) { showingDecided = sunny.decided.count > 0 && showingDecided }
                .environmentObject(sunny)
        }
        .sheet(isPresented: $showingDayNote) {
            DayNoteSheet().environmentObject(sunny)
        }
        .task {
            if sunny.digest == nil { await sunny.load() }
            await runScreenshotHook()
        }
        // The dates on a card come from its Planner task; fetch as it surfaces.
        .task(id: deck.prefix(2).map(\.id)) {
            for item in deck.prefix(2) { await sunny.loadContext(for: item) }
        }
        .onChange(of: deck.first?.id) { _, _ in
            draft = ""
            redoing = false
            replyIsRedo = false
        }
    }

    /// Screenshots: `-UITestSunny detail` opens the first card's sheet,
    /// `-UITestSunny decided` decides two fixture cards and shows the list.
    private func runScreenshotHook() async {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-SunnyFixture"), let i = args.firstIndex(of: "-UITestSunny"), i + 1 < args.count else { return }
        switch args[i + 1] {
        case "detail": detail = deck.first
        case "daynote": showingDayNote = true
        case "saiddone": filter = .done
        case "reply":
            filter = args.contains("-UITestSunnyFind") ? .find : .review
            // After the deck change has cleared the field's state.
            try? await Task.sleep(for: .milliseconds(400))
            redoing = true
            if args.contains("-UITestSunnyKeyboard") { fieldFocused = true }
        case "decided", "decided-detail":
            if let q = sunny.pending(.question).first {
                _ = await sunny.perform(.answer("Go with the second option. I will send the photos on Monday."), on: q)
            }
            if let r = sunny.pending(.review).first { _ = await sunny.perform(.approve, on: r) }
            showingDecided = true
            if args[i + 1] == "decided-detail" { detail = sunny.decided.first?.item }
        default: break
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Sunny").font(.title2.bold())
                    if let d = sunny.digest {
                        Text(d.date + (d.dry == true ? " · dry run" : ""))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if sunny.digest != nil {
                    // Also the way back to what has been answered.
                    Button {
                        fieldFocused = false
                        showingDecided.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Text("\(sunny.total - sunny.pending.count) of \(sunny.total) decided")
                                .contentTransition(.numericText())
                            Image(systemName: showingDecided ? "chevron.down" : "chevron.right")
                                .font(.caption2.weight(.bold))
                        }
                        .font(.footnote)
                        .frame(minHeight: 28)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScale())
                    .foregroundStyle(.secondary)
                    .accessibilityHint("Shows what you have decided today")
                }
            }
            Spacer()
            iconButton("mic", label: "Leave a day note") {
                fieldFocused = false
                showingDayNote = true
            }
            if let page = sunny.pageURL {
                iconButton("doc.richtext", label: "Open the full digest") { web = LinkSheetTarget(url: page) }
            }
            iconButton("arrow.clockwise", label: "Reload") { Task { await sunny.load() } }
            if let onClose {
                iconButton("xmark", label: "Close", action: onClose)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        // Clear the floating sidebar button when shown as a tab.
        .padding(.top, onClose == nil ? 36 : 0)
    }

    private func iconButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .foregroundStyle(.secondary)
        .accessibilityLabel(label)
    }

    private var kindChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("All", count: sunny.pending.count, selected: !showingDecided && filter == nil) {
                    filter = nil; showingDecided = false
                }
                ForEach(SunnyItem.Kind.allCases) { kind in
                    let n = sunny.pending(kind).count
                    if n > 0 || filter == kind {
                        chip(kind.label, count: n, selected: !showingDecided && filter == kind) {
                            filter = kind; showingDecided = false
                        }
                    }
                }
                if !sunny.decided.isEmpty || showingDecided {
                    chip("Decided", count: sunny.decided.count, selected: showingDecided) {
                        fieldFocused = false
                        showingDecided = true
                    }
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 32)
    }

    private func chip(_ text: String, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(text).font(.subheadline.weight(.medium))
                Text("\(count)").font(.subheadline.monospacedDigit()).opacity(0.6)
            }
            .foregroundStyle(selected ? AnyShapeStyle(Theme.c.onAccent) : AnyShapeStyle(.primary))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule().fill(selected ? Theme.c.accent : Color.white.opacity(0.1)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
    }

    // MARK: - Deck

    @ViewBuilder
    private var content: some View {
        if sunny.digest == nil {
            VStack(spacing: 10) {
                if sunny.isLoading { ProgressView() }
                Text(sunny.error ?? "Loading Sunny's digest…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
        } else if showingDecided {
            decidedList
        } else if deck.isEmpty {
            doneState
        } else {
            ZStack {
                // The next card peeks out behind the top one.
                ForEach(Array(deck.prefix(2).enumerated().reversed()), id: \.element.id) { index, item in
                    card(item)
                        .scaleEffect(index == 0 ? 1 : 0.95, anchor: .bottom)
                        .offset(y: index == 0 ? 0 : 14)
                        .opacity(index == 0 ? 1 : 0.6)
                        .offset(index == 0 ? drag : .zero)
                        .rotationEffect(.degrees(index == 0 && !reduceMotion ? Double(drag.width / 28) : 0))
                        .gesture(index == 0 ? swipe(item) : nil)
                        .zIndex(index == 0 ? 1 : 0)
                        .transition(.asymmetric(
                            insertion: .opacity,
                            removal: reduceMotion ? .opacity : .opacity.combined(with: .offset(x: drag.width >= 0 ? 360 : -360))))
                }
            }
            .padding(.horizontal, 14)
            // The deck's order changing is what removes the top card.
            .animation(reduceMotion ? .easeOut(duration: 0.15) : .easeOut(duration: 0.22), value: deck.map(\.id))
            .overlay(alignment: .bottom) { toastOrError }
        }
    }

    private func swipe(_ item: SunnyItem) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                // Tracks the finger 1:1; only the release animates.
                drag = CGSize(width: value.translation.width, height: value.translation.height * 0.15)
            }
            .onEnded { value in
                // A slow drag past a third of the card, or a flick, counts.
                let dx = value.translation.width
                let flick = value.predictedEndTranslation.width
                let right = dx > 90 || (dx > 30 && flick > 260)
                let left = dx < -90 || (dx < -30 && flick < -260)
                if right, let action = primary(item) {
                    decide(action, item)
                } else if left {
                    decide(.later, item)
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { drag = .zero }
                    // A question has nothing to approve: right means "answer".
                    if right, item.kind == .question { fieldFocused = true }
                }
            }
    }

    /// What a release to the right will do, for the stamp on the card.
    private func rightLabel(_ item: SunnyItem) -> String {
        switch primary(item) {
        case .approve: return "Approve"
        case .complete: return "Complete"
        case .kill: return "Kill"
        case .keep: return "Keep"
        case .file: return "File in wiki"
        default: return "Answer"
        }
    }

    private func card(_ item: SunnyItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Label(item.kind.singular, systemImage: item.kind.icon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if let v = item.verdict { badge(v) }
                    Spacer()
                    if sunny.busy.contains(item.id) { ProgressView().controlSize(.small) }
                }
                Text(item.title)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let caption = item.caption {
                    Text(caption).font(.footnote).foregroundStyle(.secondary)
                }
                if let dates = item.taskId.flatMap({ sunny.contexts[$0]?.dateLine }), !dates.isEmpty {
                    Label(dates, systemImage: "calendar")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let detail = item.detail {
                    Text(detail).font(.body).foregroundStyle(.primary.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !item.lines.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        if item.kind == .question {
                            Text("Sunny needs").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        ForEach(item.lines, id: \.self) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Circle().fill(Theme.c.attention).frame(width: 5, height: 5)
                                Text(line).font(.callout).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .padding(18)
            // The card doesn't scroll (a scroll view here used to swallow the
            // swipe); what doesn't fit fades out and "Show more" has it all.
            // minHeight 0: with the keyboard up the card gives way instead of
            // pushing the header off the top and the field under the keys.
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { if fieldFocused { fieldFocused = false } }
            .mask(LinearGradient(stops: [.init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))

            Button { detail = item } label: {
                HStack(spacing: 6) {
                    Text(item.taskId == nil ? "Show more" : "Show more: brief and notes")
                    Image(systemName: "chevron.up")
                    Spacer()
                }
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 18)
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScale())
            .foregroundStyle(Theme.c.accent)
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.c.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(swipeTint.opacity(0.9), lineWidth: 2)
                )
        )
        .overlay(alignment: .top) { swipeStamp(item) }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.bottom, 16)
    }

    /// Names what letting go will do, once the drag is far enough to count.
    @ViewBuilder
    private func swipeStamp(_ item: SunnyItem) -> some View {
        if deck.first?.id == item.id, abs(drag.width) > 30 {
            let right = drag.width > 0
            let armed = abs(drag.width) > 90
            HStack {
                if !right { Spacer() }
                Label(right ? rightLabel(item) : "Later", systemImage: right ? "arrow.right" : "clock")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(armed ? Color.black : Color.primary)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(Capsule().fill(armed ? (right ? Color.green : Theme.c.attention) : Color.white.opacity(0.14)))
                if right { Spacer() }
            }
            .padding(12)
            .allowsHitTesting(false)
        }
    }

    /// The edge colour hints which way a release will go.
    private var swipeTint: Color {
        if drag.width > 90 { return .green }
        if drag.width < -90 { return Theme.c.attention }
        return Color.white.opacity(0.08)
    }

    private func badge(_ text: String) -> some View {
        let tone: Color = switch text {
        case "approve", "keep": .green
        case "redo", "kill": .red
        case "look", "merge": Theme.c.attention
        default: .secondary
        }
        return Text(text.uppercased())
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(tone)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(tone.opacity(0.8), lineWidth: 1))
    }

    @ViewBuilder
    private var toastOrError: some View {
        if let error = sunny.error {
            toast(error, icon: "exclamationmark.triangle.fill", tint: .red) { sunny.error = nil }
        } else if let last = lastDone {
            // Goes away by itself: the Decided chip keeps the record.
            toast("\(last.outcome.capitalized): \(last.item.title)", icon: "checkmark.circle.fill", tint: .green) { lastDone = nil }
                .task(id: last.item.id) {
                    try? await Task.sleep(for: .seconds(2.5))
                    withAnimation(.easeOut(duration: 0.2)) { lastDone = nil }
                }
        }
    }

    private func toast(_ text: String, icon: String, tint: Color, dismiss: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.footnote).lineLimit(2)
            Spacer(minLength: 4)
            Button(action: dismiss) { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.c.panel))
        .padding(.horizontal, 22)
        .padding(.bottom, 26)
        .transition(.opacity.combined(with: .offset(y: 8)))
    }

    // MARK: - Decided

    private var decidedList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if sunny.decided.isEmpty {
                    Text("Nothing decided yet today.")
                        .font(.callout).foregroundStyle(.secondary).padding(32)
                }
                ForEach(sunny.decided) { done in
                    Button { detail = done.item } label: { decidedRow(done) }
                        .buttonStyle(PressScale())
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 20)
        }
    }

    private func decidedRow(_ done: SunnyDecision) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label(done.item.kind.singular, systemImage: done.item.kind.icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(done.outcome.capitalized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
            }
            Text(done.item.title)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.leading)
                .lineLimit(2)
            if let note = done.note {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(0.85))
                    .multilineTextAlignment(.leading)
                    .lineLimit(4)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1).fill(Theme.c.accent).frame(width: 2)
                    }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.c.surface))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .foregroundStyle(Theme.c.text)
    }

    private var doneState: some View {
        VStack(spacing: 12) {
            SunnyBadge(size: 72)
            Text(filter == nil ? "All decided" : "No \(filter!.label.lowercased()) left")
                .font(.title3.weight(.semibold))
            if let d = sunny.digest {
                Text(d.headline).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if filter != nil {
                Button("Show everything") { filter = nil }.buttonStyle(PressScale())
            } else {
                Button { showingDayNote = true } label: {
                    Label("Leave a day note", systemImage: "mic")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .frame(height: 44)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressScale())
                .foregroundStyle(.primary)
                .padding(.top, 6)
            }
        }
        .padding(32)
    }

    // MARK: - Actions

    private func primary(_ item: SunnyItem) -> SunnyAction? {
        switch item.kind {
        case .question: return nil
        case .done: return .complete
        case .review: return .approve
        case .stale: return item.verdict == "kill" ? .kill : .keep
        case .proposal: return .keep
        case .find: return .file
        }
    }

    @ViewBuilder
    private func actionBar(_ item: SunnyItem) -> some View {
        let busy = sunny.busy.contains(item.id)
        VStack(spacing: 8) {
            if item.kind == .review || item.kind == .find, redoing {
                let isFind = item.kind == .find
                // Themed by hand: the system segmented control ignores the theme.
                HStack(spacing: 6) {
                    ForEach([false, true], id: \.self) { redo in
                        Button { replyIsRedo = redo } label: {
                            Text(redo ? (isFind ? "Make it a task" : "Redo") : "Follow up")
                                .font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .frame(height: 34)
                                .foregroundStyle(replyIsRedo == redo ? AnyShapeStyle(Theme.c.onAccent) : AnyShapeStyle(.primary))
                                .background(Capsule().fill(replyIsRedo == redo ? Theme.c.accent : Color.white.opacity(0.1)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(PressScale())
                        .accessibilityAddTraits(replyIsRedo == redo ? .isSelected : [])
                    }
                }
                if !fieldFocused { Text(isFind
                     ? (replyIsRedo
                        ? "Adds it to your Planner backlog as your own task, and an agent files it in the wiki. A note is optional."
                        : "An agent files it in the wiki, then does what you ask.")
                     : (replyIsRedo
                        ? "The work isn't right. The note goes on the brief and the task waits to be started again."
                        : "The work stands; ask for one more thing. The agent starts again on the desktop with your note."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading) }
            }
            if item.kind == .question || redoing {
                HStack(alignment: .bottom, spacing: 8) {
                    if fieldFocused {
                        Button { fieldFocused = false } label: {
                            Image(systemName: "keyboard.chevron.compact.down")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(Color.white.opacity(0.1)))
                                .contentShape(Circle())
                        }
                        .buttonStyle(PressScale())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Hide keyboard")
                    }
                    TextField(fieldPrompt(item), text: $draft, axis: .vertical)
                        .lineLimit(1...5)
                        .focused($fieldFocused)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.c.bubble))
                    Button {
                        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty || noteIsOptional(item) else { return }
                        fieldFocused = false
                        switch item.kind {
                        case .question: decide(.answer(text), item)
                        case .find: decide(replyIsRedo ? .makeTask(text) : .followUp(text), item)
                        default: decide(replyIsRedo ? .redo(text) : .followUp(text), item)
                        }
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Theme.c.onAccent)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Theme.c.accent))
                    }
                    .buttonStyle(PressScale())
                    .disabled(busy || (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !noteIsOptional(item)))
                    .accessibilityLabel(item.kind == .question ? "Send answer" : (replyIsRedo ? "Send back" : "Send follow-up"))
                }
            }
            if !fieldFocused { HStack(spacing: 8) {
                switch item.kind {
                case .question:
                    action("Later", icon: "clock", style: .quiet) { decide(.later, item) }
                case .done:
                    action("Later", icon: "clock", style: .quiet) { decide(.later, item) }
                    action("Not yet", icon: "tray", style: .quiet) { decide(.keep, item) }
                    action("Complete", icon: "checkmark", style: .primary) { decide(.complete, item) }
                case .review:
                    action("Later", icon: "clock", style: .quiet) { decide(.later, item) }
                    action(redoing ? "Cancel" : "Reply", icon: redoing ? "xmark" : "arrowshape.turn.up.left", style: .quiet) {
                        redoing.toggle()
                        fieldFocused = redoing
                    }
                    action("Approve", icon: "checkmark", style: .primary) { decide(.approve, item) }
                case .stale:
                    action("Later", icon: "clock", style: .quiet) { decide(.later, item) }
                    action("Keep", icon: "tray", style: .quiet) { decide(.keep, item) }
                    action("Kill", icon: "xmark", style: item.verdict == "kill" ? .primary : .quiet) { decide(.kill, item) }
                case .proposal:
                    action("Later", icon: "clock", style: .quiet) { decide(.later, item) }
                    action("Drop", icon: "trash", style: .quiet) { decide(.drop, item) }
                    action("Keep", icon: "checkmark", style: .primary) { decide(.keep, item) }
                case .find:
                    // Four across: icons only on the two quiet ones.
                    action("Later", icon: nil, style: .quiet) { decide(.later, item) }
                    action("Drop", icon: nil, style: .quiet) { decide(.drop, item) }
                    action(redoing ? "Cancel" : "Reply", icon: nil, style: .quiet) {
                        redoing.toggle()
                        fieldFocused = redoing && !replyIsRedo
                    }
                    action("File", icon: "books.vertical", style: .primary) { decide(.file, item) }
                }
            }
            .disabled(busy) }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .animation(.easeOut(duration: 0.18), value: fieldFocused)
    }

    private func fieldPrompt(_ item: SunnyItem) -> String {
        switch item.kind {
        case .question: return "Answer Sunny…"
        case .find: return replyIsRedo ? "A note for the task (optional)" : "What should the agent do with it?"
        default: return replyIsRedo ? "What should the agent change?" : "What should the agent do next?"
        }
    }

    /// "Make it a task" on a find can be sent with nothing typed.
    private func noteIsOptional(_ item: SunnyItem) -> Bool { item.kind == .find && replyIsRedo }

    private enum ActionStyle { case primary, quiet }

    private func action(_ title: String, icon: String?, style: ActionStyle, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Group { if let icon { Label(title, systemImage: icon) } else { Text(title) } }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .foregroundStyle(style == .primary ? AnyShapeStyle(Theme.c.onAccent) : AnyShapeStyle(.primary))
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(style == .primary ? Theme.c.accent : Color.white.opacity(0.08))
                )
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressScale())
    }

    private func decide(_ action: SunnyAction, _ item: SunnyItem) {
        if drag == .zero, !reduceMotion {
            // A button press throws the card the same way a swipe would.
            drag = CGSize(width: action == .later ? -1 : 1, height: 0)
        }
        // Next turn, so the card's exit direction above is rendered first.
        DispatchQueue.main.async {
            // The card leaves now; the save follows. If it fails the card
            // comes back with the error.
            withAnimation(.easeOut(duration: 0.22)) {
                leaving.insert(item.id)
                drag = .zero
            }
            Task {
                let ok = await sunny.perform(action, on: item)
                withAnimation(.easeOut(duration: 0.2)) {
                    leaving.remove(item.id)
                    lastDone = ok && action != .later ? (item, action.outcome) : nil
                }
            }
        }
    }
}

/// Everything behind one card: Sunny's note, what Marlin answered, and the
/// Planner task's brief, notes and agent state. Text is selectable.
struct SunnyDetailSheet: View {
    @EnvironmentObject var sunny: SunnyStore
    @Environment(\.dismiss) private var dismiss
    let item: SunnyItem
    var onPutBack: () -> Void = {}
    /// A web link opens here, over this sheet. The app's usual browser sheet
    /// belongs to the session view, which is underneath Sunny.
    @State private var web: LinkSheetTarget?

    private var context: SunnyTaskContext? { item.taskId.flatMap { sunny.contexts[$0] } }
    private var decision: SunnyDecision? { sunny.decided.first { $0.id == item.id } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Label(item.kind.singular, systemImage: item.kind.icon)
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        if let v = item.verdict {
                            Text(v.uppercased()).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Done") { dismiss() }.font(.subheadline.weight(.semibold))
                    }
                    Text(item.title).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    if let facts = context?.facts, !facts.isEmpty {
                        Text(facts).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                    } else if let caption = item.caption {
                        Text(caption).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                if let decision {
                    section(decision.note == nil ? "Decided" : (decision.outcome == "answered" ? "Your answer" : (decision.outcome == "follow-up sent" ? "Your follow-up" : "Your note"))) {
                        if let note = decision.note { prose(note) }
                        Text(decision.outcome.capitalized + " today").font(.footnote).foregroundStyle(.secondary)
                    }
                }

                if item.detail != nil || !item.lines.isEmpty {
                    section(item.kind == .question ? "Sunny needs" : "Sunny says") {
                        if let d = item.detail { prose(d) }
                        ForEach(item.lines, id: \.self) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Circle().fill(Theme.c.attention).frame(width: 5, height: 5)
                                prose(line)
                            }
                        }
                    }
                }

                if let link = item.link {
                    Button { open(link) } label: {
                        Label(link.host() ?? link.absoluteString, systemImage: "arrow.up.right.square")
                            .font(.footnote.weight(.medium))
                            .frame(minHeight: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScale())
                }

                if let id = item.taskId {
                    if let context {
                        if !context.timeline.isEmpty {
                            section("Timeline") {
                                ForEach(Array(context.timeline.enumerated()), id: \.offset) { _, event in
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                                            Text(SunnyDates.stamp(event.at))
                                                .font(.footnote.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                                .frame(width: 118, alignment: .leading)
                                            Text(event.label).font(.callout.weight(.medium))
                                        }
                                        if let text = event.text {
                                            Text(text)
                                                .font(.footnote)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(4)
                                                .padding(.leading, 126)
                                        }
                                    }
                                }
                                Text("The Planner started keeping this log on 20 Nov 2026; earlier steps were not recorded.")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        if let brief = context.brief { section("Brief") { prose(brief) } }
                        if let notes = context.notes { section("Task notes") { prose(notes) } }
                        if context.agentActivity != nil || context.agentSession != nil {
                            section("Agent") {
                                if let a = context.agentActivity { prose(a) }
                                if let s = context.agentSession {
                                    Text(s).font(.footnote.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if context.brief == nil, context.notes == nil {
                            Text("This task has no brief or notes yet.").font(.callout).foregroundStyle(.secondary)
                        }
                    } else if let error = sunny.contextErrors[id] {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(error).font(.callout).foregroundStyle(.secondary)
                            Button("Try again") { Task { await sunny.loadContext(for: item, force: true) } }
                                .font(.subheadline.weight(.semibold))
                        }
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading the brief…").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }

                if decision != nil {
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            sunny.unmark(item)
                            onPutBack()
                            dismiss()
                        } label: {
                            Label("Put back in the deck", systemImage: "arrow.uturn.backward")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.08)))
                                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(PressScale())
                        .foregroundStyle(.primary)
                        Text("This only brings the card back. What was already saved to the Planner stays.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.c.background.ignoresSafeArea())
        .foregroundStyle(Theme.c.text)
        .tint(Theme.c.accent)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .sheet(item: $web) { target in
            SafariSheet(url: target.url) { web = nil }.ignoresSafeArea()
        }
        .task { await sunny.loadContext(for: item) }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    /// Long-press selects a range, like the chat view.
    private func prose(_ text: String) -> some View {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var styled = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        Self.linkBareURLs(in: &styled)
        return SelectableProse(text: styled, onLink: { open($0) })
    }

    /// Web pages open in a browser over this sheet; anything else (a Folds
    /// link, say) goes to the system.
    private func open(_ url: URL) {
        if LinkRouter.isWeb(url) { web = LinkSheetTarget(url: url) } else { UIApplication.shared.open(url) }
    }

    /// Briefs are mostly plain text, so a pasted address isn't a link yet.
    private static func linkBareURLs(in text: inout AttributedString) {
        let plain = String(text.characters)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
        for match in detector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
            guard let url = match.url, LinkRouter.isWeb(url), let range = Range(match.range, in: plain) else { continue }
            let start = text.characters.index(text.startIndex, offsetBy: plain.distance(from: plain.startIndex, to: range.lowerBound))
            let end = text.characters.index(start, offsetBy: plain.distance(from: range.lowerBound, to: range.upperBound))
            if text[start..<end].link == nil { text[start..<end].link = url }
        }
    }
}

/// Buttons scale to 0.97 while pressed (ui-rules: feedback on press).
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The pinned card at the top of the surface switcher: Sunny's headline and
/// how many decisions are left. Tapping opens the deck.
struct SunnySwitcherCard: View {
    @EnvironmentObject var sunny: SunnyStore
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                SunnyBadge(size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Sunny").font(.headline)
                        if let d = sunny.digest { Text(d.date).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                    }
                    Text(sunny.digest?.headline ?? (sunny.error ?? "Loading the morning digest…"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                if sunny.digest != nil {
                    let left = sunny.pending.count
                    Text(left == 0 ? "Done" : "\(left) left")
                        .font(.footnote.weight(.semibold).monospacedDigit())
                        .foregroundStyle(left == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.black))
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(Capsule().fill(left == 0 ? Color.white.opacity(0.1) : Theme.c.attention))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.c.surface))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressScale())
        .foregroundStyle(.primary)
        .task { if sunny.digest == nil { await sunny.load() } }
        .accessibilityLabel("Sunny, \(sunny.digest?.headline ?? "loading")")
    }
}

/// Sunny's face (a lion-sun over crossed bones, drawn to match Merry's
/// icon; source in ios/design/sunny). Clipped like an app icon.
struct SunnyBadge: View {
    var size: CGFloat
    var body: some View {
        Image("SunnyIcon")
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            .accessibilityHidden(true)
    }
}
