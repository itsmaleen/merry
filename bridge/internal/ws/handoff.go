package ws

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/itsmaleen/merry/bridge/internal/backend"
	"github.com/itsmaleen/merry/bridge/internal/handoff"
)

// HandoffConfig enables `session.handoff`: moving agent sessions between this
// machine's herdr and another herdr machine (see package handoff).
type HandoffConfig struct {
	// Machine is the herdr machine label sessions move to.
	Machine string `json:"machine"`
	// Bridge is the tailnet name of the bridge on that machine, so the phone
	// can switch to it once the sessions have landed.
	Bridge string `json:"bridge,omitempty"`
	// Synced are directories kept in sync by other means.
	Synced []string `json:"-"`
}

var (
	handoffCfg  *HandoffConfig
	handoffMu   sync.Mutex
	handoffBusy bool
)

// SetHandoff turns on `session.handoff`. Call before serving.
func SetHandoff(c HandoffConfig) { handoffCfg = &c }

// handleHandoff starts a move and answers at once; progress and the outcome
// arrive as `handoff.progress` and `handoff.done` pushes to every phone. The
// move runs detached from the connection on purpose: the phone asking is
// often the one leaving Wi-Fi.
//
// Params: direction "out" (default, here -> Machine) or "back" (Machine ->
// here); surface_id (one pane) or workspace_id (one workspace), else every
// agent; force (move mid-turn).
func handleHandoff(cmd commandRequest, be backend.Backend) commandResponse {
	if handoffCfg == nil {
		return errorResponse(cmd.ID, "unsupported", "session handoff is not set up on this bridge (needs herdr and a saved herdr machine)")
	}
	str := func(k string) string { s, _ := cmd.Params[k].(string); return s }
	force, _ := cmd.Params["force"].(bool)
	dir := str("direction")
	if dir == "" {
		dir = "out"
	}
	if dir != "out" && dir != "back" {
		return errorResponse(cmd.ID, "invalid_params", "direction must be out or back")
	}
	opts := handoff.Options{From: "local", To: handoffCfg.Machine, Force: force, Wait: 2 * time.Minute, Synced: handoffCfg.Synced}
	if dir == "back" {
		opts.From, opts.To = handoffCfg.Machine, "local"
	}
	// Ids from a phone address this bridge's herdr; "back" moves panes that
	// live on the other machine, which the phone cannot name from here.
	if id := str("surface_id"); id != "" {
		if dir == "back" {
			return errorResponse(cmd.ID, "invalid_params", "back moves whole workspaces or everything; open the other bridge to pick one pane")
		}
		p, err := herdrID(id)
		if err != nil {
			return errorResponse(cmd.ID, "invalid_params", err.Error())
		}
		opts.Panes = []string{p}
	}
	if id := str("workspace_id"); id != "" {
		w, err := herdrID(id)
		if err != nil {
			return errorResponse(cmd.ID, "invalid_params", err.Error())
		}
		opts.Workspace = w
	}
	if l := str("workspace_label"); l != "" {
		opts.Workspace = l
	}

	handoffMu.Lock()
	if handoffBusy {
		handoffMu.Unlock()
		return errorResponse(cmd.ID, "busy", "a handoff is already running")
	}
	handoffBusy = true
	handoffMu.Unlock()

	hub := be.Hub()
	opts.Log = func(f string, a ...any) {
		hub.Broadcast(backend.Event{Type: "handoff.progress", Data: map[string]any{"message": fmt.Sprintf(f, a...)}})
	}
	cfg := *handoffCfg
	go func() {
		defer func() { handoffMu.Lock(); handoffBusy = false; handoffMu.Unlock() }()
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Minute)
		defer cancel()
		res, err := handoff.Run(ctx, opts)
		data := map[string]any{"direction": dir, "machine": cfg.Machine, "results": res}
		if dir == "out" {
			data["bridge"] = cfg.Bridge
		}
		if err != nil {
			data["error"] = err.Error()
		}
		moved := 0
		for _, r := range res {
			if r.Status == "moved" {
				moved++
			}
		}
		data["moved"] = moved
		hub.Broadcast(backend.Event{Type: "handoff.done", Data: data})
	}()
	return commandResponse{ID: cmd.ID, OK: true, Result: mustJSON(map[string]any{"started": true, "direction": dir, "machine": cfg.Machine})}
}

// herdrID strips a composite bridge's runtime namespace.
func herdrID(id string) (string, error) {
	if rest, ok := strings.CutPrefix(id, "herdr:"); ok {
		return rest, nil
	}
	if strings.HasPrefix(id, "cmux:") {
		return "", fmt.Errorf("%s is a cmux surface; only herdr panes can be handed off", id)
	}
	return id, nil
}

func mustJSON(v any) json.RawMessage {
	b, _ := json.Marshal(v)
	return b
}
