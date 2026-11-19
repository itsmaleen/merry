import SwiftUI

/// The focused agent card's body: the whole loaded conversation as one
/// continuous chat (older events page in as you scroll up, like Messages),
/// with whatever the session is waiting on pinned to the bottom.
///
/// The third body of `PaneCardView`, beside the terminal and browser ones.
/// It adds one gesture, tap (a work row, a choice, a button, a link).
/// Long-press stays the card's (quick actions).
struct ChatCardBody: View {
    let events: [TranscriptEvent]
    /// `events` grouped into rows, once per change (AppState.chatItems).
    let items: [ChatItem]
    let pending: PendingState?
    /// A dialog open on the live screen (ScreenDialog), shown only when the
    /// transcript reports nothing pending: `pending` always wins.
    var screenDialog: ScreenDialog? = nil
    let isWorking: Bool
    /// The surface's live screen, for the peek; nil falls back to `screenText`.
    let screen: ScreenModel?
    let screenText: String
    /// Older events exist on the bridge, and a page of them is on its way.
    var hasMore = false
    var isLoadingOlder = false
    let onSendKey: (String) -> Void
    let onShowTerminal: () -> Void
    /// Records the newest event as seen; drives the next visit's marker.
    let onMarkViewed: (String) -> Void
    var onNearTop: () -> Void = {}
    var scrollToBottomRequest: Int = 0
    var onJumpToBottom: () -> Void = {}
    /// Find (••• → Find) over the loaded conversation.
    var searchQuery = ""
    var currentMatchIndex = 0
    var onSearchMatchCount: (Int) -> Void = { _ in }
    /// Screenshot fixture: open every work row.
    var expandAllWork = false
    /// Screenshot fixture: open every command chip and run divider.
    var expandCommands = false
    /// Screenshot fixture: open at the top or half way instead.
    var fixtureOpen: ChatScrollView<ChatTranscriptView>.OpenPosition? = nil
    /// A tap that doesn't need the keyboard (a work row, a chip): the
    /// layout lowers it.
    var onInteract: () -> Void = {}

    /// The last event seen on the previous visit and when, captured once per
    /// focus: the marker is fixed for the whole visit.
    @State private var baselineSeen: String?
    @State private var baselineAt: Double?
    @State private var markerDecided = false
    @State private var markerID: String?
    @State private var expanded: Set<String> = []
    @State private var farFromBottom = false
    @State private var scrollable = false
    @State private var markerY: CGFloat?
    @State private var findRows: [String] = []
    @State private var scrollTarget: ChatScrollView<ChatTranscriptView>.ScrollTarget?
    @State private var revealedMatch: String?
    /// The first mounted row while the reader is scrolled up; nil while
    /// following the bottom (ChatPaging.windowStart).
    @State private var windowAnchor: String?

    init(events: [TranscriptEvent], items: [ChatItem], pending: PendingState?, screenDialog: ScreenDialog? = nil,
         isWorking: Bool, screen: ScreenModel?,
         screenText: String, hasMore: Bool = false, isLoadingOlder: Bool = false,
         lastViewedEventID: String?, lastViewedAt: Double?,
         onSendKey: @escaping (String) -> Void, onShowTerminal: @escaping () -> Void,
         onMarkViewed: @escaping (String) -> Void, onNearTop: @escaping () -> Void = {},
         scrollToBottomRequest: Int = 0, onJumpToBottom: @escaping () -> Void = {},
         searchQuery: String = "", currentMatchIndex: Int = 0, onSearchMatchCount: @escaping (Int) -> Void = { _ in },
         expandAllWork: Bool = false, expandCommands: Bool = false,
         fixtureOpen: ChatScrollView<ChatTranscriptView>.OpenPosition? = nil,
         onInteract: @escaping () -> Void = {}) {
        self.events = events
        self.items = items
        self.pending = pending
        self.screenDialog = screenDialog
        self.isWorking = isWorking
        self.screen = screen
        self.screenText = screenText
        self.hasMore = hasMore
        self.isLoadingOlder = isLoadingOlder
        self.onSendKey = onSendKey
        self.onShowTerminal = onShowTerminal
        self.onMarkViewed = onMarkViewed
        self.onNearTop = onNearTop
        self.scrollToBottomRequest = scrollToBottomRequest
        self.onJumpToBottom = onJumpToBottom
        self.searchQuery = searchQuery
        self.currentMatchIndex = currentMatchIndex
        self.onSearchMatchCount = onSearchMatchCount
        self.expandAllWork = expandAllWork
        self.expandCommands = expandCommands
        self.fixtureOpen = fixtureOpen
        self.onInteract = onInteract
        _baselineSeen = State(initialValue: lastViewedEventID)
        _baselineAt = State(initialValue: lastViewedAt)
        // The screenshot fixture's top / half-way opens mount everything, so
        // they show the conversation's real top.
        _windowAnchor = State(initialValue: fixtureOpen != nil ? items.first?.id : nil)
    }

    var body: some View {
        let marker = currentMarker
        let currentMatch = findRows.isEmpty ? nil : findRows[TextSearch.clamp(currentMatchIndex, to: findRows.count)]
        let ids = items.map(\.id)
        let start = ChatPaging.windowStart(
            ids: ids, anchorID: windowAnchor,
            mustInclude: [marker, currentMatch].compactMap { id in id.flatMap { ids.firstIndex(of: $0) } }
        )
        let shown = start == 0 ? items : Array(items[start...])
        let conversationRows = shown.filter { !$0.isOutbox }
        let top = start > 0 ? (isLoadingOlder ? ChatTranscriptView.Top.loading : .more) : self.top
        VStack(spacing: 0) {
            ChatScrollView(
                content: ChatTranscriptView(
                    items: shown,
                    expanded: expandedIDs(currentMatch: currentMatch),
                    onToggle: toggle,
                    showsWorking: showsWorkingLine,
                    hiddenQuestionID: sheetQuestionID,
                    top: top,
                    markerBeforeID: marker,
                    markerLabel: markerLabel,
                    highlightID: currentMatch,
                    trackedID: currentMatch,
                    onMarkerY: { y in if markerY == nil { markerY = y } },
                    onTrackedY: { id, y in revealMatch(id, y: y) }
                ),
                topToken: "\(conversationRows.first?.id ?? "")|\(top)",
                tailToken: conversationRows.last?.id ?? "",
                hasContent: !items.isEmpty,
                openPosition: fixtureOpen ?? (marker != nil ? .anchor : .bottom),
                openAnchorY: markerY,
                canPage: start > 0 || (hasMore && !isLoadingOlder),
                onNearTop: { nearTop(ids: ids, start: start) },
                onAtBottomChanged: { atBottom in
                    // Following again: back to the small window. Scrolled up:
                    // freeze the window's top so new rows can't move it.
                    let frozen = start < ids.count ? ids[start] : nil
                    DispatchQueue.main.async {
                        if atBottom { windowAnchor = nil } else if windowAnchor == nil { windowAnchor = frozen }
                    }
                },
                onFarFromBottomChanged: { far in
                    if ChatPerf.jumpLog { print("[Jump] far=\(far)") }
                    farFromBottom = far
                },
                onScrollableChanged: { scrollable = $0 },
                scrollToBottomRequest: scrollToBottomRequest,
                scrollTarget: scrollTarget
            )
            .overlay(alignment: .bottom) {
                if farFromBottom && searchQuery.isEmpty {
                    jumpButton.padding(.bottom, 8).transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }
            .animation(.easeInOut(duration: 0.18), value: farFromBottom)

            pendingPanel
        }
        .onAppear { settleMarker() }
        .onChange(of: lastConversationID) { _, _ in settleMarker() }
        .onDisappear { if let id = lastConversationID { onMarkViewed(id) } }
        .onChange(of: findKey, initial: true) { _, _ in recomputeFind() }
    }

    // MARK: - Top of the list

    /// Near the top of what is mounted: mount more rows if this phone holds
    /// them, else ask the bridge for older events. Deferred a turn: it is
    /// called from inside the scroll view's update.
    private func nearTop(ids: [String], start: Int) {
        guard start > 0 else { onNearTop(); return }
        let anchor = ChatPaging.grownAnchor(ids: ids, start: start)
        DispatchQueue.main.async { if windowAnchor != anchor { windowAnchor = anchor } }
    }

    private var top: ChatTranscriptView.Top {
        if isLoadingOlder { return .loading }
        if hasMore { return ChatPaging.isAtCap(count: ChatPaging.conversationCount(events), hasMore: true) ? .capped : .more }
        // A list too short to scroll needs no "start" line.
        return scrollable ? .start : .none
    }

    // MARK: - Pending

    @ViewBuilder
    private var pendingPanel: some View {
        switch pending?.kind {
        case .approval:
            let event = events.last(where: { $0.id == pending?.eventID })
            ApprovalSheet(
                tool: pending?.tool ?? event?.tool ?? "",
                arg: pending?.arg ?? event?.arg ?? "",
                since: event?.ts,
                onKey: onSendKey
            )
        case .question:
            if let event = events.last(where: { $0.id == pending?.eventID }) ?? events.last(where: { $0.kind == .question }),
               ChatGrouping.canAnswerByKey(event) {
                QuestionSheet(event: event, onKey: onSendKey)
                    .id(event.id)
            } else {
                // Several questions or multi-select: answer on the real screen.
                PeekPanel(caption: "Question", screen: screen, fallbackText: screenText,
                          onKey: onSendKey, onShowTerminal: onShowTerminal)
            }
        case .unknown:
            PeekPanel(caption: "Waiting on you", screen: screen, fallbackText: screenText,
                      onKey: onSendKey, onShowTerminal: onShowTerminal)
        case nil:
            if let dialog = screenDialog {
                if dialog.options.isEmpty {
                    PeekPanel(caption: dialog.title ?? "Choose in terminal", screen: screen, fallbackText: screenText,
                              onKey: onSendKey, onShowTerminal: onShowTerminal)
                } else {
                    ScreenDialogSheet(dialog: dialog, onKey: onSendKey, onShowTerminal: onShowTerminal)
                }
            }
        }
    }

    /// The question the sheet answers by key, if that's what is pending.
    private var sheetQuestionID: String? {
        guard pending?.kind == .question,
              let event = events.last(where: { $0.id == pending?.eventID }) ?? events.last(where: { $0.kind == .question }),
              ChatGrouping.canAnswerByKey(event) else { return nil }
        return event.id
    }

    private var showsWorkingLine: Bool {
        guard isWorking, pending == nil else { return false }
        if case .work(let g) = items.last(where: { !$0.isOutbox }), g.isRunning { return false }
        return true
    }

    private func expandedIDs(currentMatch: String?) -> Set<String> {
        if expandAllWork { return Set(items.map(\.id)) }
        var ids = expanded
        if expandCommands {
            for item in items {
                switch item {
                case .command(let e), .scheduled(let e): ids.insert(e.id)
                default: break
                }
            }
        }
        // A match inside a work row's calls, or past a long message's
        // preview, opens the row.
        if let currentMatch {
            switch items.first(where: { $0.id == currentMatch }) {
            case .work?, .user?: ids.insert(currentMatch)
            default: break
            }
        }
        return ids
    }

    private func toggle(_ id: String) {
        onInteract()
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    // MARK: - New since you were here

    private var lastConversationID: String? { events.last(where: { !$0.queued })?.id }

    /// The marker for this visit: decided the first time events are on hand
    /// (read live until then so the first layout already has it), then fixed.
    private var currentMarker: String? {
        markerDecided ? markerID : ChatPaging.markerItemID(items: items, events: events, lastSeenID: baselineSeen)
    }

    private var markerLabel: String {
        let at = baselineAt ?? events.first(where: { $0.id == baselineSeen })?.ts
        guard let at, let ago = ChatTime.ago(at), ago != "now" else { return "New since you were here" }
        return "New since you were here · \(ago) ago"
    }

    /// Fixes the marker once, then marks what's on screen as seen.
    private func settleMarker() {
        guard let last = lastConversationID else { return }
        if !markerDecided {
            markerDecided = true
            markerID = ChatPaging.markerItemID(items: items, events: events, lastSeenID: baselineSeen)
        }
        onMarkViewed(last)
    }

    // MARK: - Find

    /// Changes when the query or the rows do (cheap: no full compare).
    private var findKey: String {
        guard !searchQuery.isEmpty else { return "" }
        return "\(searchQuery)|\(items.count)|\(items.first?.id ?? "")|\(items.last?.id ?? "")|\(events.last?.text.count ?? 0)"
    }

    private func recomputeFind() {
        let rows = ChatGrouping.matchRows(items, query: searchQuery, matcher: { q, t in
            TextSearch.matches(of: q, in: t).count
        }, cap: TextSearch.maxMatches)
        if rows != findRows { findRows = rows }
        onSearchMatchCount(rows.count)
        if rows.isEmpty { revealedMatch = nil }
    }

    /// Scrolls to a match the first time its row reports where it is.
    private func revealMatch(_ id: String, y: CGFloat) {
        let key = "\(id)#\(currentMatchIndex)"
        guard revealedMatch != key else { return }
        revealedMatch = key
        scrollTarget = .init(y: y, token: (scrollTarget?.token ?? 0) + 1)
    }

    // MARK: - Chrome

    /// Chevron-down over the bottom of the chat, while more than a screen up.
    /// Neutral; a small orange dot when an approval or question waits below.
    private var jumpButton: some View {
        Button(action: onJumpToBottom) {
            Image(systemName: "chevron.down")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
                .overlay(alignment: .topTrailing) {
                    if pending != nil || screenDialog != nil {
                        Circle().fill(Theme.c.attention).frame(width: 9, height: 9).offset(x: -1, y: 1)
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pending != nil ? "Jump to latest, waiting on you" : "Jump to latest")
    }
}
