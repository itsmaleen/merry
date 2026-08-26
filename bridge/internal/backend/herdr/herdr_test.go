package herdr

import (
	"bufio"
	"context"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/itsmaleen/cmux-companion/bridge/internal/backend"
)

// fakeHerdr answers herdr's socket protocol from a table of canned results
// and records every request it saw.
type fakeHerdr struct {
	t        *testing.T
	ln       net.Listener
	mu       sync.Mutex
	results  map[string]any // method → result object
	requests []map[string]any
}

func newFakeHerdr(t *testing.T) *fakeHerdr {
	t.Helper()
	// Unix socket paths are capped at ~104 bytes on macOS; t.TempDir is too
	// deep, so use a short dir under /tmp.
	dir, err := os.MkdirTemp("/tmp", "hb")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	ln, err := net.Listen("unix", filepath.Join(dir, "h.sock"))
	if err != nil {
		t.Fatal(err)
	}
	f := &fakeHerdr{t: t, ln: ln, results: map[string]any{}}
	go f.serve()
	t.Cleanup(func() { ln.Close() })
	return f
}

func (f *fakeHerdr) path() string { return f.ln.Addr().String() }

func (f *fakeHerdr) serve() {
	for {
		conn, err := f.ln.Accept()
		if err != nil {
			return
		}
		go func() {
			defer conn.Close()
			line, err := bufio.NewReader(conn).ReadString('\n')
			if err != nil {
				return
			}
			var req map[string]any
			if err := json.Unmarshal([]byte(line), &req); err != nil {
				return
			}
			f.mu.Lock()
			f.requests = append(f.requests, req)
			res, ok := f.results[req["method"].(string)]
			f.mu.Unlock()
			var out []byte
			if ok {
				out, _ = json.Marshal(map[string]any{"id": req["id"], "result": res})
			} else {
				out, _ = json.Marshal(map[string]any{"id": req["id"], "error": map[string]any{
					"code": "unknown_method", "message": "no canned result for " + req["method"].(string)}})
			}
			conn.Write(append(out, '\n'))
		}()
	}
}

func (f *fakeHerdr) set(method string, result any) {
	f.mu.Lock()
	f.results[method] = result
	f.mu.Unlock()
}

func (f *fakeHerdr) last(method string) map[string]any {
	f.mu.Lock()
	defer f.mu.Unlock()
	for i := len(f.requests) - 1; i >= 0; i-- {
		if f.requests[i]["method"] == method {
			return f.requests[i]["params"].(map[string]any)
		}
	}
	return nil
}

func connectedBackend(t *testing.T, f *fakeHerdr) *Backend {
	t.Helper()
	b := New(Config{SocketPath: f.path()})
	b.connected.Store(true)
	// Per-pane status streams are exercised separately; keep them inert here.
	b.dialStatus = func(ctx context.Context, paneID string) (subscription, error) {
		<-ctx.Done()
		return nil, ctx.Err()
	}
	return b
}

func handle(t *testing.T, b *Backend, method string, params map[string]any) map[string]any {
	t.Helper()
	raw, err := b.Handle(method, params)
	if err != nil {
		t.Fatalf("%s: %v", method, err)
	}
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatalf("%s: decode: %v", method, err)
	}
	return out
}

var claudePane = map[string]any{
	"pane_id": "w1:p1", "terminal_id": "term_1", "workspace_id": "w1", "tab_id": "w1:t1",
	"focused": true, "cwd": "/repo", "foreground_cwd": "/repo/sub",
	"agent": "claude", "agent_status": "working",
	"terminal_title": "◑ Fix auth", "terminal_title_stripped": "Fix auth",
	"agent_session": map[string]any{"source": "herdr:claude", "agent": "claude", "kind": "id", "value": "0d9d5b2e-1111-4222-8333-444455556666"},
	"scroll":        map[string]any{"offset_from_bottom": 0, "max_offset_from_bottom": 12, "viewport_rows": 40},
	"revision":      2,
}

var shellPane = map[string]any{
	"pane_id": "w1:p2", "terminal_id": "term_2", "workspace_id": "w1", "tab_id": "w1:t1",
	"focused": false, "cwd": "/repo", "foreground_cwd": "/repo",
	"agent_status": "unknown",
	"scroll":       map[string]any{"offset_from_bottom": 0, "max_offset_from_bottom": 460, "viewport_rows": 40},
	"revision":     0,
}

func TestSurfaceListTranslatesPanes(t *testing.T) {
	f := newFakeHerdr(t)
	f.set("pane.list", map[string]any{"type": "pane_list", "panes": []any{claudePane, shellPane}})
	b := connectedBackend(t, f)

	out := handle(t, b, "surface.list", map[string]any{"workspace_id": "w1"})
	if got := f.last("pane.list")["workspace_id"]; got != "w1" {
		t.Fatalf("pane.list workspace_id = %v, want w1", got)
	}
	surfaces := out["surfaces"].([]any)
	if len(surfaces) != 2 {
		t.Fatalf("got %d surfaces, want 2", len(surfaces))
	}
	claude := surfaces[0].(map[string]any)
	if claude["id"] != "w1:p1" || claude["title"] != "Fix auth" || claude["type"] != "terminal" ||
		claude["is_focused"] != true || claude["agent_status"] != "working" {
		t.Fatalf("claude surface = %v", claude)
	}
	binding := claude["resume_binding"].(map[string]any)
	if binding["kind"] != "claude" || binding["checkpoint_id"] != "0d9d5b2e-1111-4222-8333-444455556666" || binding["cwd"] != "/repo/sub" {
		t.Fatalf("resume_binding = %v", binding)
	}
	shell := surfaces[1].(map[string]any)
	if _, has := shell["resume_binding"]; has {
		t.Fatalf("shell pane must not carry a resume_binding: %v", shell)
	}
	if shell["title"] != "repo" {
		t.Fatalf("shell title = %v, want directory basename", shell["title"])
	}
}

func TestReadTextClampsAgentPanesToViewport(t *testing.T) {
	f := newFakeHerdr(t)
	f.set("pane.list", map[string]any{"panes": []any{claudePane, shellPane}})
	f.set("pane.read", map[string]any{"type": "pane_read", "read": map[string]any{
		"pane_id": "w1:p1", "source": "recent", "format": "text", "text": "hello\n", "truncated": false}})
	b := connectedBackend(t, f)
	handle(t, b, "surface.list", nil) // primes the pane cache

	out := handle(t, b, "surface.read_text", map[string]any{"surface_id": "w1:p1", "lines": float64(2000)})
	if out["text"] != "hello\n" {
		t.Fatalf("text = %v", out["text"])
	}
	req := f.last("pane.read")
	if req["source"] != "recent" || req["lines"] != float64(40) || req["pane_id"] != "w1:p1" {
		t.Fatalf("agent pane read = %v, want lines clamped to viewport 40", req)
	}

	handle(t, b, "surface.read_text", map[string]any{"surface_id": "w1:p2", "lines": float64(2000)})
	if req := f.last("pane.read"); req["lines"] != float64(2000) {
		t.Fatalf("shell pane read = %v, want the full 2000 rows (scrollback)", req)
	}
}

func TestReadTextFetchesUnknownPane(t *testing.T) {
	f := newFakeHerdr(t)
	f.set("pane.get", map[string]any{"type": "pane_info", "pane": claudePane})
	f.set("pane.read", map[string]any{"read": map[string]any{"text": "x", "truncated": false}})
	b := connectedBackend(t, f)

	handle(t, b, "surface.read_text", map[string]any{"surface_id": "w1:p1", "lines": float64(500)})
	if f.last("pane.get") == nil {
		t.Fatal("expected a pane.get for an uncached pane")
	}
	if req := f.last("pane.read"); req["lines"] != float64(40) {
		t.Fatalf("read after pane.get = %v, want clamped", req)
	}
}

func TestSendTextTrailingNewlineBecomesEnter(t *testing.T) {
	f := newFakeHerdr(t)
	f.set("pane.send_input", map[string]any{"type": "ok"})
	b := connectedBackend(t, f)

	handle(t, b, "surface.send_text", map[string]any{"surface_id": "w1:p1", "text": "ls -la\n"})
	req := f.last("pane.send_input")
	if req["text"] != "ls -la" {
		t.Fatalf("text = %v", req["text"])
	}
	if keys, _ := req["keys"].([]any); len(keys) != 1 || keys[0] != "enter" {
		t.Fatalf("keys = %v, want [enter]", req["keys"])
	}

	handle(t, b, "surface.send_text", map[string]any{"surface_id": "w1:p1", "text": "partial"})
	req = f.last("pane.send_input")
	if req["text"] != "partial" || req["keys"] != nil {
		t.Fatalf("plain text request = %v", req)
	}
}

func TestSendKeyMapping(t *testing.T) {
	f := newFakeHerdr(t)
	f.set("pane.send_keys", map[string]any{"type": "ok"})
	f.set("pane.zoom", map[string]any{"type": "pane_zoom", "changed": true})
	b := connectedBackend(t, f)

	cases := map[string]string{
		"escape": "esc", "esc": "esc", "return": "enter", "enter": "enter",
		"ctrl+c": "ctrl+c", "shift+tab": "shift+tab", "up": "up", "tab": "tab", "space": "space",
	}
	for in, want := range cases {
		handle(t, b, "surface.send_key", map[string]any{"surface_id": "w1:p1", "key": in})
		keys := f.last("pane.send_keys")["keys"].([]any)
		if len(keys) != 1 || keys[0] != want {
			t.Errorf("key %q sent as %v, want [%s]", in, keys, want)
		}
	}

	handle(t, b, "surface.send_key", map[string]any{"surface_id": "w1:p1", "key": "cmd+shift+enter"})
	if req := f.last("pane.zoom"); req == nil || req["mode"] != "toggle" || req["pane_id"] != "w1:p1" {
		t.Fatalf("cmd+shift+enter should toggle zoom, got %v", req)
	}

	if _, err := b.Handle("surface.send_key", map[string]any{"surface_id": "w1:p1", "key": "cmd+k"}); err == nil {
		t.Fatal("cmd+k should be rejected")
	}
}

func TestPaneListUsesActiveTabLayout(t *testing.T) {
	f := newFakeHerdr(t)
	f.set("session.snapshot", map[string]any{"type": "session_snapshot", "snapshot": map[string]any{
		"version": "0.8.2", "protocol": 20, "focused_workspace_id": "w1",
		"workspaces": []any{map[string]any{"workspace_id": "w1", "label": "repo", "focused": true, "active_tab_id": "w1:t2"}},
		"panes":      []any{claudePane, shellPane},
		"layouts": []any{
			map[string]any{"workspace_id": "w1", "tab_id": "w1:t1", "area": map[string]any{"x": 26, "y": 1, "width": 148, "height": 42},
				"focused_pane_id": "w1:p1", "panes": []any{map[string]any{"pane_id": "w1:p1", "focused": true, "rect": map[string]any{"x": 26, "y": 1, "width": 148, "height": 42}}}},
			map[string]any{"workspace_id": "w1", "tab_id": "w1:t2", "area": map[string]any{"x": 26, "y": 1, "width": 148, "height": 42},
				"focused_pane_id": "w1:p3", "panes": []any{
					map[string]any{"pane_id": "w1:p3", "focused": true, "rect": map[string]any{"x": 26, "y": 1, "width": 74, "height": 42}},
					map[string]any{"pane_id": "w1:p4", "focused": false, "rect": map[string]any{"x": 100, "y": 1, "width": 74, "height": 42}},
				}},
		},
	}})
	b := connectedBackend(t, f)

	out := handle(t, b, "pane.list", nil)
	panes := out["panes"].([]any)
	if len(panes) != 2 {
		t.Fatalf("got %d panes, want the active tab's 2: %v", len(panes), panes)
	}
	second := panes[1].(map[string]any)
	pf := second["pixel_frame"].(map[string]any)
	if pf["x"] != float64(74) || pf["y"] != float64(0) || pf["width"] != float64(74) {
		t.Fatalf("pixel_frame = %v, want origin relative to the tab area", pf)
	}
	cf := second["container_frame"].(map[string]any)
	if cf["width"] != float64(148) || cf["height"] != float64(42) {
		t.Fatalf("container_frame = %v", cf)
	}
	if ids := second["surface_ids"].([]any); len(ids) != 1 || ids[0] != "w1:p4" {
		t.Fatalf("surface_ids = %v", ids)
	}
}

func TestWorkspaceListAndCurrent(t *testing.T) {
	f := newFakeHerdr(t)
	f.set("workspace.list", map[string]any{"workspaces": []any{
		map[string]any{"workspace_id": "w1", "number": 1, "label": "repo", "focused": false, "agent_status": "working"},
		map[string]any{"workspace_id": "w2", "number": 2, "label": "other", "focused": true, "agent_status": "unknown"},
	}})
	b := connectedBackend(t, f)

	out := handle(t, b, "workspace.list", nil)
	list := out["workspaces"].([]any)
	if len(list) != 2 || list[0].(map[string]any)["id"] != "w1" || list[0].(map[string]any)["title"] != "repo" {
		t.Fatalf("workspaces = %v", list)
	}
	cur := handle(t, b, "workspace.current", nil)
	if cur["id"] != "w2" {
		t.Fatalf("current = %v, want the focused w2", cur)
	}
}

func TestUnsupportedAndOffline(t *testing.T) {
	f := newFakeHerdr(t)
	b := connectedBackend(t, f)
	_, err := b.Handle("browser.url.get", map[string]any{"surface_id": "w1:p1"})
	var berr *backend.Error
	if err == nil || !asBackendError(err, &berr) || berr.Code != "unsupported" {
		t.Fatalf("browser.url.get err = %v, want unsupported", err)
	}
	_, err = b.Handle("surface.create", map[string]any{"type": "browser"})
	if err == nil || !asBackendError(err, &berr) || berr.Code != "unsupported" {
		t.Fatalf("browser surface.create err = %v, want unsupported", err)
	}

	b.connected.Store(false)
	_, err = b.Handle("workspace.list", nil)
	if err == nil || !asBackendError(err, &berr) || berr.Code != "backend_unavailable" {
		t.Fatalf("offline err = %v, want backend_unavailable", err)
	}
}

func asBackendError(err error, target **backend.Error) bool {
	e, ok := err.(*backend.Error)
	if ok {
		*target = e
	}
	return ok
}

// Notifications come from agent-status transitions observed on the event
// stream, never from the initial snapshot.
func TestEventsSynthesiseNotifications(t *testing.T) {
	f := newFakeHerdr(t)
	b := connectedBackend(t, f)
	events := b.Hub().Subscribe()
	defer b.Hub().Unsubscribe(events)

	drain := func() []backend.Event {
		var out []backend.Event
		for {
			select {
			case ev := <-events:
				out = append(out, ev)
			case <-time.After(50 * time.Millisecond):
				return out
			}
		}
	}
	pane := func(status string) []byte {
		p := map[string]any{}
		for k, v := range claudePane {
			p[k] = v
		}
		p["agent_status"] = status
		line, _ := json.Marshal(map[string]any{"event": "pane_updated", "data": map[string]any{"type": "pane_updated", "pane": p}})
		return line
	}

	// First sight of the pane (already blocked): a surface.updated, no notification.
	b.applyEvent(pane("blocked"))
	evs := drain()
	if len(evs) != 1 || evs[0].Type != "surface.updated" {
		t.Fatalf("first observation events = %v, want just surface.updated", evs)
	}

	b.applyEvent(pane("working"))
	drain()
	b.applyEvent(pane("blocked"))
	evs = drain()
	var notif *notification
	for _, ev := range evs {
		if ev.Type == "notification.created" {
			n := ev.Data.(notification)
			notif = &n
		}
	}
	if notif == nil {
		t.Fatalf("working→blocked produced %v, want a notification", evs)
	}
	if notif.SurfaceID != "w1:p1" || notif.WorkspaceID != "w1" || notif.Title != "Fix auth" || notif.Body != "Needs your input" {
		t.Fatalf("notification = %+v", *notif)
	}

	// Same status again: nothing.
	b.applyEvent(pane("blocked"))
	if evs := drain(); len(evs) != 0 {
		t.Fatalf("repeat status produced %v", evs)
	}

	b.applyEvent(pane("done"))
	evs = drain()
	found := false
	for _, ev := range evs {
		if ev.Type == "notification.created" && ev.Data.(notification).Body == "Finished" {
			found = true
		}
	}
	if !found {
		t.Fatalf("blocked→done produced %v, want a Finished notification", evs)
	}

	out := handle(t, b, "notification.list", nil)
	if list := out["notifications"].([]any); len(list) != 2 {
		t.Fatalf("notification.list = %v, want 2", list)
	}
	handle(t, b, "notification.clear", nil)
	out = handle(t, b, "notification.list", nil)
	if list := out["notifications"].([]any); len(list) != 0 {
		t.Fatalf("after clear = %v", list)
	}
}

func TestPaneMovedCarriesStatusAcross(t *testing.T) {
	f := newFakeHerdr(t)
	b := connectedBackend(t, f)
	events := b.Hub().Subscribe()
	defer b.Hub().Unsubscribe(events)

	first, _ := json.Marshal(map[string]any{"event": "pane_updated", "data": map[string]any{"pane": claudePane}})
	b.applyEvent(first)
	moved := map[string]any{}
	for k, v := range claudePane {
		moved[k] = v
	}
	moved["pane_id"] = "w2:p1"
	moved["workspace_id"] = "w2"
	moved["agent_status"] = "blocked"
	line, _ := json.Marshal(map[string]any{"event": "pane_moved", "data": map[string]any{
		"previous_pane_id": "w1:p1", "previous_workspace_id": "w1", "pane": moved}})
	b.applyEvent(line)

	b.mu.Lock()
	_, oldThere := b.panes["w1:p1"]
	_, newThere := b.panes["w2:p1"]
	b.mu.Unlock()
	if oldThere || !newThere {
		t.Fatalf("cache after move: old=%v new=%v", oldThere, newThere)
	}
	// working→blocked across the move is a real transition and must notify
	// under the NEW id.
	deadline := time.After(200 * time.Millisecond)
	for {
		select {
		case ev := <-events:
			if ev.Type == "notification.created" {
				if n := ev.Data.(notification); n.SurfaceID != "w2:p1" || n.WorkspaceID != "w2" {
					t.Fatalf("notification after move = %+v", n)
				}
				return
			}
		case <-deadline:
			t.Fatal("no notification after move to blocked")
		}
	}
}

// Run against a fake stream: connected on subscription ack + snapshot,
// disconnected when the stream ends.
func TestRunConnectsFromSubscription(t *testing.T) {
	f := newFakeHerdr(t)
	f.set("session.snapshot", map[string]any{"snapshot": map[string]any{
		"workspaces": []any{}, "panes": []any{claudePane}, "layouts": []any{}}})
	b := New(Config{SocketPath: f.path()})
	events := b.Hub().Subscribe()
	defer b.Hub().Unsubscribe(events)

	stream := make(chan []byte, 4)
	b.dial = func(ctx context.Context) (subscription, error) {
		return &chanSubscription{lines: stream}, nil
	}
	statusStream := make(chan []byte, 4)
	var statusDials []string
	var statusMu sync.Mutex
	b.dialStatus = func(ctx context.Context, paneID string) (subscription, error) {
		statusMu.Lock()
		statusDials = append(statusDials, paneID)
		statusMu.Unlock()
		return &chanSubscription{lines: statusStream}, nil
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go b.Run(ctx)

	select {
	case ev := <-events:
		if ev.Type != "backend.connected" {
			t.Fatalf("first event = %v", ev)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("no backend.connected")
	}
	if !b.Connected() {
		t.Fatal("Connected() false after connect")
	}
	b.mu.Lock()
	_, cached := b.panes["w1:p1"]
	b.mu.Unlock()
	if !cached {
		t.Fatal("snapshot did not seed the pane cache")
	}
	statusMu.Lock()
	dials := append([]string(nil), statusDials...)
	statusMu.Unlock()
	if len(dials) != 1 || dials[0] != "w1:p1" {
		t.Fatalf("status subscriptions opened for %v, want [w1:p1]", dials)
	}

	// A status event on the per-pane stream drives the notification path.
	line, _ := json.Marshal(map[string]any{"event": "pane.agent_status_changed", "data": map[string]any{
		"pane_id": "w1:p1", "workspace_id": "w1", "agent_status": "blocked", "agent": "claude", "title": "Fix auth"}})
	statusStream <- line
	deadline := time.After(2 * time.Second)
	for got := false; !got; {
		select {
		case ev := <-events:
			if ev.Type == "notification.created" {
				if n := ev.Data.(notification); n.SurfaceID != "w1:p1" || n.Body != "Needs your input" {
					t.Fatalf("notification = %+v", n)
				}
				got = true
			}
		case <-deadline:
			t.Fatal("no notification from the status stream")
		}
	}

	close(stream)
	select {
	case ev := <-events:
		if ev.Type != "backend.disconnected" {
			t.Fatalf("event after stream end = %v", ev)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("no backend.disconnected")
	}
}

type chanSubscription struct{ lines chan []byte }

func (c *chanSubscription) readLine() ([]byte, error) {
	line, ok := <-c.lines
	if !ok {
		return nil, os.ErrClosed
	}
	return line, nil
}
func (c *chanSubscription) close() {}

func TestParseResponse(t *testing.T) {
	if _, err := parseResponse(`{"id":"x","error":{"code":"invalid_request","message":"bad"}}`); err == nil || !strings.Contains(err.Error(), "invalid_request") {
		t.Fatalf("error response parsed as %v", err)
	}
	raw, err := parseResponse(`{"id":"x","result":{"type":"pong"}}` + "\n")
	if err != nil || !strings.Contains(string(raw), "pong") {
		t.Fatalf("success response: %s %v", raw, err)
	}
}
