# Session UI: chat inside the cards

Design and mockups: `~/wrinkles/wiki/articles/merry_session_ui_nov2026.md`, mockup source `~/wrinkles/output/viz/merry_session_ui/mockups.js` (screens: home, switcher, shell, expanded, approval, peek, question, resume).

Rule: a card's body follows what runs in the surface. Agent session (`agentKind` claude/opencode) = chat. Plain shell = terminal. Browser = unchanged.

Gestures on the open session: a long-press selects text (quick actions open from the header's ••• menu, "All Actions"); a swipe in from the left screen edge (the iOS back gesture) opens the grid, as do the header's grid button and a swipe up on the composer; volume-down cycles surfaces. There is no sideways swipe between surfaces: with full-screen sessions you can't see where it lands. While dictating, the left-edge swipe opens the transcript editor instead. Anything that doesn't need the keyboard (grid, menus, quick actions, chat buttons, switching surface) lowers it first. Web links open in an in-app Safari sheet.

## Several devices

With more than one paired bridge, the grid is where you move between them; Settings is only for pairing, renaming and removing.

- A row of device chips sits above the workspace chips. The device on screen is filled; tapping another shows that device in the grid. Another device's chip carries its session count, an attention dot when one of its agents is blocked, or "offline".
- Under the cards, each other device has a list of its sessions (needs you, then working, then other agents, then shells; four shown, "Show N more" for the rest). Tapping a row switches to that device and opens the session. The + on a device's heading opens a new tab or YOLO tab there.
- The header's ••• menu names the device and can switch it.
- The lists come from `DevicePeeker`: one extra connection per other device, open only while the grid is open, that calls `workspace.list` and `surface.list` every 10 s (at most 12 workspaces) and subscribes to nothing. No bridge change. Status is known only where the runtime reports it (herdr); a cmux session shows no status.

## Wire contract (bridge <-> iOS)

`claude.transcript` / `agent.transcript` take a new optional param `format`.

- absent or `"text"`: today's reply, unchanged (older app builds).
- `"events"`: the reply carries `events` and `pending` instead of `text`. All other fields (`supported`, `session_id`, `session_missing`, `fingerprint`, `unchanged`, `source`) behave as today. The fingerprint must differ between formats, and must change when `pending` changes.

### `events`: array, oldest first, capped to the last `max_messages` events and ~128 KiB

Every event has `id` (stable across polls for the same underlying item), `kind`, and optional `ts` (unix seconds).

| kind | fields |
|---|---|
| `user` | `text` |
| `text` | `text` (assistant prose, markdown) |
| `tool` | `tool` (name), `arg` (main argument, <= 200 runes, same key priority as `toolArgumentKeys`), `status` (`running`, `ok`, `error`), `output` (tail of the result: last 6 lines, <= 600 bytes; present for errors, optional otherwise), `added` / `removed` (line counts for Edit/Write/MultiEdit, optional) |
| `question` | `questions`: `[{question, header, multi, options: [{label, description}]}]`, `answered` (bool), `answer` (string, when answered) |

Notes:
- A tool call and its result are ONE `tool` event, joined by tool-use id. No result yet = `running`.
- `AskUserQuestion` tool calls become `question` events, not `tool` events.
- User lines that are only tool results, system reminders, or command wrappers are not `user` events.
- Thinking is dropped. Sidechain (subagent) lines are dropped; the parent's Agent/Task call is the `tool` event.

### Slash commands and scheduled runs (on `user` events)

A user line that is a slash command carries extra optional fields:

- `command`: the command name with its slash, e.g. `"/loop"`. When present, `text` holds only the args (may be empty), not the name.
- `skill_loaded`: true when the harness injected a prompt for it (the next line is an `isMeta` companion sharing the command line's `promptId`). The injected text itself is never sent.
- `scheduled`: true when the harness fired the line, not the human (the JSONL line has `scheduledTaskId`). Can also be set on a non-command user event.
- `run`: 1-based count of fires of that scheduled task so far in the session (the human's original command is not a run), counted over everything the bridge read, before capping.

```json
{"id": "u7", "kind": "user", "ts": 1794000900, "command": "/loop", "text": "5m check the deploy", "skill_loaded": true}
{"id": "u9", "kind": "user", "ts": 1794001200, "command": "/loop", "text": "5m check the deploy", "skill_loaded": true, "scheduled": true, "run": 1}
```

- `command_output`: what a local command printed (the `<local-command-stdout>` / `<local-command-stderr>` user line that follows it, same `promptId` or directly after it), ANSI codes stripped, trimmed, last 6 lines and at most 600 bytes. Example: `/model` → `"Set model to Opus 5 (1M context) (default) and saved as your default for new sessions"`. Absent when the command printed nothing. `command_error: true` when it came from stderr. The phone shows it as a quiet line under the chip.

A local command that opens a picker in the terminal (`/model`, `/config`, `/resume`, `/mcp`, `/agents`, `/permissions`, `/memory`, `/status`, `/login`, `/output-style`, `/hooks`, `/plugin`, `/statusline`, `/theme`, `/vim`, `/add-dir`, `/ide`, `/export`) writes nothing to the transcript until the human picks or cancels. The phone therefore detects the open dialog from the live screen, not from events, and shows the pending panel for it (see iOS pieces).

- `compacted`: true on the line where the harness replaced the earlier conversation with a summary (`isCompactSummary` in the JSONL). `text` is empty: the summary is never sent. The phone shows a quiet divider ("Earlier conversation summarized · 2:52 PM"), never a bubble from the human.

The phone shows a command as a chip (name + first line of args, tap to expand; "Loaded skill prompt" inside the expansion when `skill_loaded`), and a scheduled event as a quiet divider ("Loop run 4 · 2:15 PM"), never as a bubble from the human.

### Paging older events (continuous scroll, no history overlay)

Events-format replies carry `has_more` (bool): true when events older than the first one returned exist in what the bridge read.

A request with `before: "<event id>"` (events format only) returns the page that ends just before that event: up to `max_messages` events strictly older than it, oldest first, same byte cap (keeping the events nearest to `before`), with `has_more`. A page reply has `pending: null`, ignores `known_fingerprint`, and never answers `unchanged`. If the id is not found (it fell out of the window the bridge reads, or the session changed), the reply is `events: []`, `has_more: false`.

The phone keeps one ordered list per surface. A tail poll replaces the list from the tail's first id onward (if that id is not in the list, the list becomes the tail). A page is prepended. Scrolling near the top requests the next page; there is no separate history screen for agent sessions.

### Queued messages (sent while the agent is working)

Claude Code records these outside normal user lines: a top-level `{"type":"queue-operation","operation":"enqueue","timestamp","content"}` when the human sends, later a `dequeue` / `remove` (with `reason`, e.g. `absorbed_mid_turn`) / `popAll`, and delivery mid-turn as a line whose `attachment` is `{"type":"queued_command","prompt":…}` instead of a `type:"user"` message.

- A message delivered mid-turn (a `queued_command` attachment) is a normal `user` event at that position, `id` = that line's `uuid`.
- A message enqueued and not yet dequeued/removed is a `user` event with `queued: true`, placed after all other events, in enqueue order, `id` = `"q:" + <enqueue timestamp>`, `ts` = enqueue time. It never counts toward `pending`, and a trailing `queued` event does not stop the event before it from being "the last event" for `pending`.
- Enqueued content that is harness noise (task notifications, command output, system reminders: the same filter as user lines) is never an event. A slash command in the queue gets `command` like any other.
- No duplicates: once a queued message is delivered (as a user line or an attachment), only the delivered event remains.

The phone shows a queued event as a normal user bubble at the bottom with a `.footnote` "Queued" label under it, and shows a message it has just sent the same way at once (labelled "Sending") until an event with the same text arrives.

### `pending`: object or null

What the session is waiting on from the human, for the approval sheet and the live-screen peek.

```json
{"kind": "approval", "event_id": "toolu_…", "tool": "Bash", "arg": "rm -rf build"}
{"kind": "question", "event_id": "toolu_…"}
{"kind": "unknown"}
```

- `question`: the last event is an unanswered `question`.
- `approval`: the backend reports the surface blocked (herdr `agent_status == "blocked"`) and the last event is a `running` tool.
- `unknown`: the backend reports blocked and neither of the above fits. The phone shows the live-screen peek.
- On a backend with no agent status (cmux), only `question` can be reported; otherwise null.

The phone answers an approval by sending the TUI's own keys through `surface.send_key`: `1` allow, `2` allow all edits, `3` no. A typed reply is "no, do this instead".

### Example

```json
{"supported": true, "session_id": "abc", "fingerprint": "…", "source": "binding",
 "events": [
  {"id": "u1", "kind": "user", "ts": 1794000000, "text": "fix the flaky poller test"},
  {"id": "a1", "kind": "text", "text": "I'll look at the poller first."},
  {"id": "toolu_1", "kind": "tool", "tool": "Read", "arg": "bridge/internal/poller/poller.go", "status": "ok"},
  {"id": "toolu_2", "kind": "tool", "tool": "Bash", "arg": "go test ./internal/poller", "status": "error", "output": "--- FAIL: TestDedup (0.01s)\nFAIL"},
  {"id": "toolu_3", "kind": "tool", "tool": "Edit", "arg": "bridge/internal/poller/poller.go", "status": "ok", "added": 4, "removed": 1},
  {"id": "a2", "kind": "text", "text": "The dedup map was reset on every poll. Fixed."},
  {"id": "toolu_4", "kind": "question", "questions": [{"question": "Also fix the cmux path?", "header": "Scope", "multi": false, "options": [{"label": "Yes", "description": "Same bug there"}, {"label": "No", "description": "Leave it"}]}], "answered": false}
 ],
 "pending": {"kind": "question", "event_id": "toolu_4"}}
```

## iOS pieces

- `ChatCardBody`: focused agent card. 16pt sans prose, no bubble for the assistant, user turns in a bubble. Tool runs between prose fold into one work row ("Worked 2m · read 4 files, ran 2 commands"); tap expands to one line per tool call; a failed command shows its output tail inline.
- `GlanceBody`: small cards and switcher tiles. Agent: status pill (asks, approve, working, done), one sentence at 13pt, +/−. Shell: last four lines at 10.5pt, bottom-aligned.
- Approval sheet pinned to the bottom of the card (Allow, All edits, No). Question choices tappable. Unknown block = live-screen peek (bottom rows of the real terminal at 11pt with 1, 2, 3, esc, arrows, return) and a "terminal ›" flip.
- Chat/Terminal toggle in an agent card's title bar, remembered per surface.
- Input bar key row in chat: Stop (esc), mode (shift-tab), `/`, `@`, "keys" for the full row.
- Switcher: orange dot on the 2/N button when any surface needs you; "needs you" filter chip. Surface order never changes.
- Resume header: on focusing a card not opened since its last turn ended: what you asked and when, where the agent stopped, files changed. Dismissible.
- Pull-up history shows the conversation as chat.
