# herdr as a second backend for the companion app

Investigation date: 2026-08-24. herdr 0.8.2 (protocol 20) probed live on this Mac
via `~/.config/herdr/herdr.sock`; source read from github.com/herdrdev/herdr.

## Status (2026-08-24): Phases 0–2 implemented and verified live

- **Phase 0** — `bridge/internal/backend` (`Backend` interface, `Hub`,
  `Capabilities`); today's cmux code wrapped as `backend/cmux`; `ws` dispatches
  through the interface; `connected` payload carries `backend`,
  `backend_connected`, `capabilities`, `protocol_version: 2`; push events
  renamed `backend.connected/disconnected`. Config `backend` (auto/cmux/herdr),
  `herdr_socket_path`, `herdr_session`; flags `--backend`, `--config-dir`.
- **Phase 1** — `backend/herdr`: per-request socket client, lifecycle event
  subscription + snapshot-seeded pane cache, **one `pane.agent_status_changed`
  subscription per pane** (herdr scopes that event to a single pane_id, and does
  not emit `pane.updated` for status changes — found live), notifications
  synthesised from blocked/done transitions, `surface.updated` pushes, the full
  translation table below, viewport clamp for agent reads, transcript via the
  existing resolver. Unit tests against a fake herdr socket; verified
  end-to-end against the real herdr with a WebSocket client
  (workspaces/surfaces/layout/read/transcript/errors, and the
  working→blocked→done notification chain).
- **Phase 2** — iOS: `BackendCapabilities` + `backend` from `connected`,
  `surface.updated` handled, runtime `agent_status` drives the working
  indicator when the backend has it, `backend.*` and `cmux.*` pushes both
  accepted, unknown pushes ignored (previously mis-parsed as
  `notification.cleared`), status bar names the runtime, Settings shows the
  backend per bridge, pairing URL carries `backend=`.
- **Composite (2026-08-26)** — `backend/multi`: one bridge fronts cmux *and*
  herdr at once. Ids namespaced `cmux:<uuid>` / `herdr:w1:p1` in results,
  params and pushes; `workspace.list`/`notification.list` merged, titles
  suffixed ` · cmux`/` · herdr`; id-less commands follow the last
  `workspace.select`; `backend.disconnected` only when both are down. Config
  `backend: auto` = every runtime that answers, `all` = both regardless.
  Verified live against both runtimes (6 cmux + 3 herdr workspaces).
  Phone side: `RuntimeFilter` (All / cmux / herdr, persisted in UserDefaults)
  filters `visibleWorkspaces`; switcher in the sidebar menu and in Settings;
  workspace titles labelled ` · <runtime>` in All mode; a tapped alert from a
  hidden runtime switches the filter to it.
- **Not done (Phase 3)**: herdr tabs beyond the active one; ANSI terminal
  frames; neutral wire vocabulary; `surface.paste_image` for herdr (the
  feature lives on the unmerged `feat/paste-image` branch — same path-paste
  approach applies).

## TL;DR

- herdr is the same *shape* of thing as cmux for our purposes: a local daemon
  owning terminals, driven over a Unix socket with newline-delimited JSON, with a
  workspace → tab → pane tree, per-pane agent detection, and an event stream.
- It exposes **nothing over the network** (remote is SSH-only), so the bridge
  daemon keeps its job: sit on the Mac, talk to the local socket, expose the
  WebSocket to the phone over LAN/Tailscale.
- The companion has **no backend abstraction today**. `bridge/internal/ws/handler.go`
  `proxyCommand` forwards every phone command verbatim to `socket.Client`
  (cmux), and the iOS app's ~19 call sites speak cmux method names directly.
  Adding herdr means introducing that seam.
- Recommended path: a Go `Backend` interface + a `herdr` implementation that
  **translates the existing phone vocabulary** (`workspace.list`,
  `surface.read_text`, …) onto herdr's API. The phone changes are small
  (backend kind + capability flags in `connected`, hide browser affordances,
  optionally consume herdr's real agent status). Everything the app does today
  maps cleanly — see the table below. Two real gotchas are called out.

## herdr facts that matter

| Topic | Fact | Verified how |
|---|---|---|
| Socket | `~/.config/herdr/herdr.sock` (named sessions: `~/.config/herdr/sessions/<name>/herdr.sock`); env override `HERDR_SOCKET_PATH`; mode 0600, no auth | `src/server/socket_paths.rs`, `src/session.rs`, live |
| Wire | NDJSON. Req `{"id","method","params"}` → `{"id","result":{"type":…}}` or `{"id","error":{"code","message"}}`. Server closes after one-shot responses → **one connection per request**, like herdr's own `ApiClient`. Subscriptions keep the connection open. | `src/api/client.rs`, live |
| Handshake | `ping` → `{"type":"pong","version":"0.8.2","protocol":20,"capabilities":{…}}` | live |
| Model | workspace `w1` → tab `w1:t1` → pane `w1:p1` (one terminal per pane). `terminal_id` is stable across pane moves; `pane_id` changes on cross-workspace `pane.move`. | `src/api/schema/*.rs`, live |
| Bootstrap | `session.snapshot` → workspaces, tabs, panes, per-tab layouts (pane rects in cells + tab `area`), agents, focused ids | live |
| Push | `events.subscribe` with a list of subscriptions. Global ones (`pane.updated`, `pane.created/closed/focused`, `workspace.*`, `tab.*`, `layout.updated`) need no filter; `pane.agent_status_changed` and `pane.scroll_changed` require a `pane_id`. First line is `{"type":"subscription_started"}`, then `{"event":"pane_updated","data":{…PaneInfo}}`. No replay. | `src/api/schema/events.rs`, live |
| **No output push** | `pane.output_changed` exists as an `EventKind` but is not subscribable and `events.wait` rejects it ("currently supports pane agent status matches"). `PaneInfo.revision` is a *state* revision, not an output counter (stayed 0 after 500 lines). ⇒ live text stays **poll-based**, as with cmux. | live |
| Read | `pane.read {pane_id, source, lines?, format?, strip_ansi?}` → `result.read.text`, `truncated`. Sources on the wire: `visible`, `recent`, `recent_unwrapped` (underscore! CLI spells it with a dash), `detection`. `recent` + `lines:N` includes host scrollback (400/500 lines came back; `scroll.max_offset_from_bottom` = 460). Default 80 rows. | live |
| **Alt-screen agents** | For an *idle* recognized agent (Claude Code, opencode…) a `recent` read with `lines` > viewport makes herdr **drive the agent's mouse-scroll to page history, then scroll back to bottom** — i.e. it visibly moves the user's live pane. While *working* it just returns the visible screen (got 40 lines for `lines:400`). ⇒ for agent panes the bridge must clamp `lines` to `scroll.viewport_rows` or use `source:"visible"`, and get history from the transcript (which the phone already prefers for Claude). | `docs/…/agent-automation.mdx`, live |
| Input | `pane.send_text {text}` literal; `pane.send_keys {keys:[…]}`; `pane.send_input {text, keys}`. Key names: `enter`/`return`, `esc`/`escape`, `tab`, `shift+tab`, `backspace`, `up/down/left/right`, `ctrl+x`, `alt+x`, `f1`, `space`, `minus`… (`src/config/keybinds.rs` `parse_key_combo`). `agent.prompt {target,text}` = text + Enter, bracketed-paste aware, returns `agent_blocked` instead of typing into an approval dialog. | schema, live |
| Agent status | Per pane/tab/workspace: `idle` / `working` / `blocked` / `done` / `unknown`. From hooks when an integration is installed, else from screen manifests. Rolls up to workspace. `done` = finished and not yet looked at. | `docs/concepts.mdx`, live |
| Agent kind | `PaneInfo.agent` (`"claude"`, `"codex"`, `"opencode"`, … 20+ kinds) | live |
| Session binding | `herdr integration install claude` installs `~/.claude/hooks/herdr-agent-state.sh` (+ `settings.json` hooks). It sends `pane.report_agent_session {agent_session_id, agent_session_path}` — but herdr **keeps only the id** for claude (`src/agent_resume.rs` `session_ref_from_report` drops the path). Exposed as `pane.agent_session: {source:"herdr:claude", agent:"claude", kind:"id", value:"<uuid>"}` on `pane.get/list`, `agent.get/list`. Not installed on this Mac yet (`herdr integration status`). | source, live |
| Notifications | None as a list. Derive from `pane.updated` / `pane.agent_status_changed` transitions to `blocked` / `done`. `notification.show` exists but is herdr→user toast, the wrong direction. | schema |
| Browser surfaces | None; terminal-only. | — |
| Image paste | herdr's own remote-attach does what our `feat/paste-image` does: write the image to a temp file on the host and paste the *path*. Same plan: bridge writes the file, `pane.send_text` the path. | `docs/persistence-remote.mdx` |
| Terminal frames (future) | `herdr terminal session observe w1:p1 --cols --rows` streams NDJSON `terminal.frame` records (base64 ANSI) "for third-party bridges that only need rendered terminal bytes"; `control` adds input/resize. This is the private client-socket protocol (`herdr-client.sock`, `src/protocol/wire.rs`), reachable via the CLI as a subprocess. It's the path to a real terminal emulator view on the phone later. | docs |
| Layout ops | `pane.split {target_pane_id, direction: right\|down, focus}`, `pane.close`, `pane.focus`, `workspace.focus/create/close`, `tab.create`. | schema |

## Companion facts that matter (from the code map)

- Bridge: `bridge/cmd/cmux-bridge/main.go` (`runDaemon` :287), `bridge/internal/socket/client.go` (concrete cmux client: socket detection, `auth.login`, `{ok,result,error}` envelope), `bridge/internal/ws/handler.go` (`proxyCommand` :219, `claude.transcript` special-case :119), `bridge/internal/poller/poller.go` (polls `notification.list` every 1s, `Broadcast` is the only fan-out seam), `bridge/internal/claude/` (transcript resolver; strategies `hook_store_surface`, `hook_store_session`, `projects_glob`, `cwd_latest`).
- Phone: `ios/cmux/App/AppState.swift` — models `Workspace {id,title}`, `Surface {id,title,type,workspace_id,is_focused,resume_binding.kind}`, `Pane {id,pixel_frame,container_frame,surface_ids,focused_surface_id,is_focused}`, `BridgeNotification {id,title,subtitle,body,workspace_id,surface_id}`. Working indicator is a diff-of-successive-reads heuristic (`setWorking`). Keys sent: `ctrl+c/d/l/z`, `enter`, `return`, `tab`, `esc`, `escape`, `up/down/left/right`, `space`, `cmd+shift+enter`.
- Identity: `PairingCredentials {host,port,token,tailscaleHost}` — no backend kind. `connected` push carries `cmux_connected`, no capabilities.
- Precedent for "two implementations behind one wire method": branch `worktree-opencode-sessions`, `bridge/internal/ws/transcript.go` (`agentTranscripts` if-chain).

## Plan

### Phase 0 — the seam (bridge only, no behavior change)

1. `bridge/internal/backend/backend.go`:
   ```go
   type Backend interface {
       Connect(ctx) error; Close() error
       Ping() error
       Handle(method string, params map[string]any) (json.RawMessage, *RPCError)  // phone vocabulary in, phone vocabulary out
       Events() <-chan Event   // notification.created, surface.updated, backend.connected/disconnected
       Info() Info             // Kind ("cmux"|"herdr"), Version, Capabilities{Browser, Tabs, AgentStatus, Notifications}
   }
   ```
2. Move today's behavior into `backend/cmux` (wraps `socket.Client` + `poller.Poller` unchanged).
3. `runDaemon` picks the backend from config `backend: "cmux"|"herdr"|"auto"` (auto: herdr if `~/.config/herdr/herdr.sock` connects, else cmux). New keys: `herdr_socket_path`, `herdr_session`.
4. `connected` payload gains `backend`, `backend_connected` (keep `cmux_connected` as an alias for one release), `capabilities`.

### Phase 1 — `backend/herdr`

Client: per-request Unix connection (`net.Dial("unix")`, write line, read line), plus one long-lived subscriber connection running `events.subscribe` on `pane.updated`, `pane.created`, `pane.closed`, `pane.focused`, `workspace.*`, `tab.*`, `layout.updated`; reconnect with backoff; `ping` health like today's 5s loop.

Translation table (phone method → herdr):

| Phone (unchanged) | herdr | Notes |
|---|---|---|
| `system.ping` | `ping` | |
| `workspace.list` | `workspace.list` | `{id: workspace_id, title: label}` |
| `workspace.current` | snapshot `focused_workspace_id` | |
| `workspace.select` | `workspace.focus` | |
| `workspace.create {name}` | `workspace.create {label, cwd:$HOME}` | |
| `workspace.close` | `workspace.close` | |
| `surface.list {workspace_id}` | `pane.list {workspace_id}` | surface = pane: `{id: pane_id, title: terminal_title_stripped ?? label ?? basename(foreground_cwd), type:"terminal", workspace_id, is_focused: focused, resume_binding: {kind: agent, checkpoint_id: agent_session.value}}` + new `agent_status` |
| `surface.focus` / `surface.close` | `pane.focus` / `pane.close` | |
| `surface.split {direction}` | `pane.split {target_pane_id, direction}` | left/up → right/down (herdr only splits right/down) |
| `surface.create {type:"terminal"}` | `tab.create` in the surface's workspace | browser → error `unsupported` |
| `surface.read_text {surface_id, lines}` | `pane.read {source:"recent", lines}` | **If `pane.agent != nil`: `lines = min(lines, scroll.viewport_rows)`** (gotcha above). Return `{text}`. |
| `surface.send_text {text}` | `pane.send_text` | |
| `surface.send_key {key}` | `pane.send_keys {keys:[map(key)]}` | `escape→esc`, `return→enter`, `cmd+shift+enter→enter`; else pass through |
| `surface.paste_image` | write temp file, `pane.send_text path` | reuse `internal/imagepaste` from `feat/paste-image` |
| `pane.list {workspace_id}` | snapshot/`pane.layout` for the workspace's **active tab** | `{id: pane_id, pixel_frame: rect, container_frame: {width,height} of tab area, surface_ids:[pane_id], focused_surface_id: pane_id, is_focused}`. Phone's `normalizedFrame` handles cell units. Non-active tabs: v2 (expose as extra "panes" or a tab strip). |
| `pane.focus` | `pane.focus` | |
| `notification.list` / `notification.clear` | in-memory list synthesized from event stream | see below |
| `claude.transcript` (`agent.transcript`) | `pane.get` → `agent_session.value` → `claude.Resolver` by session id (`projects_glob` under `~/.claude/projects/*/<id>.jsonl`) | Add a resolver entry point that takes a session id from the backend instead of the cmux hook store. Requires `herdr integration install claude` on the Mac; bridge should detect the missing `agent_session` and return `supported:false, reason:"install herdr claude integration"`. |

Notifications: keep a per-pane last `agent_status`; on `pane.updated` where status becomes `blocked` emit `notification.created {id: "<pane_id>:<state_change_seq>", title: terminal_title_stripped ?? agent, subtitle: workspace label, body: "needs your input", workspace_id, surface_id}`; on `done` emit "finished". `notification.clear` empties the list. This is strictly better than cmux's polled list — real push, sub-second.

### Phase 2 — phone

1. `ConnectedPayload`: `backend`, `capabilities`; `PairingCredentials`/`SavedBridge` show the kind in Settings; pairing URL keeps `cmux-bridge://` (rename later) but gains `kind=`.
2. Hide browser affordances (`Surface.isBrowser`, `browser.url.get`) when `capabilities.browser == false`.
3. Prefer `surface.agent_status` from herdr over the read-diff `setWorking` heuristic when present; show `blocked` as the attention state (it's what the "stuck one" badge in herdr's sidebar is).
4. `isClaudeAgent` already keys off `resume_binding.kind`, so the transcript button lights up unchanged once the bridge fills it in.

### Phase 3 — later

- Neutral bridge vocabulary (rename `surface.*` → `terminal.*` etc.) once both backends live; the herdr translation layer *is* that vocabulary in disguise.
- Tabs: herdr tabs have no cmux analogue; expose as a tab strip per workspace.
- Real terminal view via `herdr terminal session observe/control` (ANSI frames) instead of text polling.
- Multi-agent transcripts (`worktree-opencode-sessions`) plug straight into `pane.agent` + `agent_session` — herdr already normalizes both for 17 agents.

## Gotchas checklist

- `recent_unwrapped` (underscore) on the wire.
- Never send a deep `recent` read to an idle agent pane — it scrolls the user's screen. Clamp to `viewport_rows` or use `visible`.
- `pane_id` is not stable across cross-workspace moves; key phone state on `terminal_id` if we ever surface moves (`pane.moved` event carries both).
- One connection per request; don't reuse the subscription connection for requests.
- Socket is 0600 owner-only: the bridge must run as the same user as herdr (see the root-owned-artifacts memory for the launchd version of this failure).
- Named sessions each have their own socket; default to the default session, allow `herdr_session` in config.
- `agent_session` only appears after `herdr integration install claude` (or codex, etc.). Without it herdr still detects the agent kind by screen manifest, so `resume_binding.kind` works but the transcript binding does not.

## Effort

Bridge: ~700–900 lines Go (client 150, translation 350, events/notifications 150, transcript wiring 80, config/selection 60). Phone: ~100 lines. Docs: `shared/protocol.md` additions for `backend`, `capabilities`, `agent_status`, and the `notification.created` semantics under herdr.
