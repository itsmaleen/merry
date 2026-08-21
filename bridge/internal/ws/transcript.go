package ws

import (
	"encoding/json"
	"sync"
	"time"

	"github.com/itsmaleen/cmux-companion/bridge/internal/claude"
	"github.com/itsmaleen/cmux-companion/bridge/internal/opencode"
	"github.com/itsmaleen/cmux-companion/bridge/internal/socket"
)

// terminalsCacheTTL bounds how often cmux is asked for its terminal table. The
// focused surface polls every few seconds and the table is large (every field
// cmux knows about every surface); which agent runs where changes far more
// slowly than that.
const terminalsCacheTTL = 2 * time.Second

// agentTranscripts answers "what conversation is this surface showing" across
// every agent the bridge understands.
//
// Agents differ in both halves of that question. Claude Code is bound by cmux
// itself (a resume_binding naming the session) and stores its transcript as
// JSONL; opencode is bound by nothing cmux exposes and stores its conversation
// in SQLite. Keeping the dispatch here means the client asks one question and
// the per-agent packages stay ignorant of each other.
type agentTranscripts struct {
	claude   *claude.Resolver
	opencode *opencode.Store

	mu          sync.Mutex
	terminals   []map[string]any
	terminalsAt time.Time
}

func newAgentTranscripts() *agentTranscripts {
	return &agentTranscripts{
		claude:   claude.NewResolver(),
		opencode: opencode.NewStore(),
	}
}

// transcriptResult is the wire shape shared by every agent.
type transcriptResult struct {
	Supported      bool   `json:"supported"`
	AgentKind      string `json:"agent_kind,omitempty"`
	Text           string `json:"text"`
	SessionID      string `json:"session_id"`
	SessionTitle   string `json:"session_title,omitempty"`
	SessionMissing bool   `json:"session_missing"`
	Fingerprint    string `json:"fingerprint,omitempty"`
	Unchanged      bool   `json:"unchanged"`
	Source         string `json:"source,omitempty"`
}

// handle answers one transcript request.
func (a *agentTranscripts) handle(cmd commandRequest, client *socket.Client) commandResponse {
	surfaceID, _ := cmd.Params["surface_id"].(string)
	if surfaceID == "" {
		return errorResponse(cmd.ID, "invalid_params", "surface_id is required")
	}

	maxMessages := 200
	if v, ok := cmd.Params["max_messages"].(float64); ok && v > 0 {
		maxMessages = int(v)
		if maxMessages > 2000 {
			maxMessages = 2000 // bound client-supplied work
		}
	}
	knownFingerprint, _ := cmd.Params["known_fingerprint"].(string)

	resumeBinding, err := a.resumeBinding(cmd, client, surfaceID)
	if err != nil {
		return errorResponse(cmd.ID, "transcript_error", err.Error())
	}

	// Claude Code first: it is the only agent cmux binds for us, so when a
	// resume_binding names it there is nothing to infer.
	if kind, _ := resumeBinding["kind"].(string); kind == "claude" {
		res, err := a.claude.Render(claude.Request{
			SurfaceID:        surfaceID,
			ResumeBinding:    resumeBinding,
			MaxMessages:      maxMessages,
			KnownFingerprint: knownFingerprint,
		})
		if err != nil {
			return errorResponse(cmd.ID, "transcript_error", err.Error())
		}
		return okResponse(cmd.ID, transcriptResult{
			Supported:      res.Supported,
			AgentKind:      "claude",
			Text:           res.Text,
			SessionID:      res.SessionID,
			SessionMissing: res.SessionMissing,
			Fingerprint:    res.Fingerprint,
			Unchanged:      res.Unchanged,
			Source:         res.Source,
		})
	}

	if result, ok := a.openCodeTranscript(client, surfaceID, maxMessages, knownFingerprint); ok {
		return okResponse(cmd.ID, result)
	}

	// Not an agent surface, or an agent this bridge doesn't read.
	return okResponse(cmd.ID, transcriptResult{})
}

// openCodeTranscript answers for a surface running opencode, reporting false
// when this surface isn't one.
func (a *agentTranscripts) openCodeTranscript(
	client *socket.Client, surfaceID string, maxMessages int, knownFingerprint string,
) (transcriptResult, bool) {
	if !a.opencode.Available() {
		return transcriptResult{}, false
	}
	terminal := a.terminal(client, surfaceID)
	if terminal == nil {
		return transcriptResult{}, false
	}
	tty := opencode.NormalizeTTY(stringField(terminal, "tty"))
	if tty == "" {
		return transcriptResult{}, false
	}
	// The process on the surface's own terminal decides whether this is an
	// opencode surface — not the title, which a shell can be made to say
	// anything with.
	if _, running := a.opencode.TTYs()[tty]; !running {
		return transcriptResult{}, false
	}

	title := stringField(terminal, "surface_title")
	directory := stringField(terminal, "current_directory")
	if directory == "" {
		directory = stringField(terminal, "requested_working_directory")
	}

	session, ok := a.opencode.ResolveSession(title, directory)
	if !ok {
		// opencode is running, but nothing identifies WHICH conversation. Say
		// so rather than showing whichever session in this directory was
		// touched last — several opencode surfaces routinely share one.
		return transcriptResult{
			Supported: true,
			AgentKind: "opencode",
			Source:    "opencode_unidentified",
		}, true
	}

	fingerprint, err := a.opencode.Fingerprint(session.ID, maxMessages)
	if err != nil {
		return transcriptResult{}, false
	}
	result := transcriptResult{
		Supported:    true,
		AgentKind:    "opencode",
		SessionID:    session.ID,
		SessionTitle: session.Title,
		Fingerprint:  fingerprint,
		Source:       "opencode_title_cwd",
	}
	if knownFingerprint != "" && knownFingerprint == fingerprint {
		result.Unchanged = true
		return result, true
	}
	text, err := a.opencode.Render(session.ID, maxMessages)
	if err != nil {
		return transcriptResult{}, false
	}
	result.Text = text
	return result, true
}

// resumeBinding fetches the surface's cmux binding, which says whether Claude
// Code is running there.
func (a *agentTranscripts) resumeBinding(
	cmd commandRequest, client *socket.Client, surfaceID string,
) (map[string]any, error) {
	listParams := map[string]any{}
	if wsID, ok := cmd.Params["workspace_id"]; ok {
		listParams["workspace_id"] = wsID
	}
	binding, found, err := surfaceBinding(client, listParams, surfaceID)
	if err != nil || found {
		return binding, err
	}

	// surface.list answers for ONE workspace — the current one when the caller
	// named none. A surface in any other workspace simply isn't in the reply,
	// and reporting "no agent here" for it would be wrong rather than empty.
	// cmux's terminal table spans every workspace, so it can say which one to
	// ask about.
	terminal := a.terminal(client, surfaceID)
	if terminal == nil {
		return nil, nil
	}
	workspaceID := stringField(terminal, "workspace_id")
	if workspaceID == "" || workspaceID == stringField(listParams, "workspace_id") {
		return nil, nil
	}
	binding, _, err = surfaceBinding(client, map[string]any{"workspace_id": workspaceID}, surfaceID)
	return binding, err
}

// surfaceBinding fetches one surface's resume_binding from a surface.list call,
// reporting whether the surface was in the reply at all — an absent surface and
// a surface with no binding are different answers.
func surfaceBinding(
	client *socket.Client, params map[string]any, surfaceID string,
) (map[string]any, bool, error) {
	result, err := client.Send("surface.list", params)
	if err != nil {
		return nil, false, err
	}
	var payload struct {
		Surfaces []map[string]any `json:"surfaces"`
	}
	if err := json.Unmarshal(result, &payload); err != nil {
		return nil, false, err
	}
	for _, s := range payload.Surfaces {
		if id, _ := s["id"].(string); id == surfaceID {
			binding, _ := s["resume_binding"].(map[string]any)
			return binding, true, nil
		}
	}
	return nil, false, nil
}

// terminal returns cmux's terminal-table entry for a surface, which is the only
// place the surface's tty is exposed.
func (a *agentTranscripts) terminal(client *socket.Client, surfaceID string) map[string]any {
	for _, t := range a.terminalTable(client) {
		if id, _ := t["surface_id"].(string); id == surfaceID {
			return t
		}
	}
	return nil
}

func (a *agentTranscripts) terminalTable(client *socket.Client) []map[string]any {
	a.mu.Lock()
	defer a.mu.Unlock()
	if time.Since(a.terminalsAt) < terminalsCacheTTL {
		return a.terminals
	}
	a.terminalsAt = time.Now()
	result, err := client.Send("debug.terminals", map[string]any{})
	if err != nil {
		a.terminals = nil
		return nil
	}
	var payload struct {
		Terminals []map[string]any `json:"terminals"`
	}
	if err := json.Unmarshal(result, &payload); err != nil {
		a.terminals = nil
		return nil
	}
	a.terminals = payload.Terminals
	return a.terminals
}

func stringField(row map[string]any, key string) string {
	if v, ok := row[key].(string); ok {
		return v
	}
	return ""
}

func errorResponse(id, code, message string) commandResponse {
	return commandResponse{ID: id, OK: false, Error: &rpcError{Code: code, Message: message}}
}

func okResponse(id string, result transcriptResult) commandResponse {
	encoded, err := json.Marshal(result)
	if err != nil {
		return errorResponse(id, "transcript_error", err.Error())
	}
	return commandResponse{ID: id, OK: true, Result: json.RawMessage(encoded)}
}
