package multi

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/itsmaleen/cmux-companion/bridge/internal/backend"
)

// fake is an in-memory backend recording calls and answering from a table.
type fake struct {
	kind      string
	hub       *backend.Hub
	connected bool
	mu        sync.Mutex
	calls     []call
	results   map[string]any
}

type call struct {
	method string
	params map[string]any
}

func newFake(kind string) *fake {
	return &fake{kind: kind, hub: backend.NewHub(), connected: true, results: map[string]any{}}
}

func (f *fake) Info() backend.Info {
	caps := backend.Capabilities{Browser: f.kind == "cmux", AgentStatus: f.kind == "herdr", Notifications: "polled"}
	return backend.Info{Kind: f.kind, Capabilities: caps}
}
func (f *fake) Run(ctx context.Context) { <-ctx.Done() }
func (f *fake) Connected() bool      { return f.connected }
func (f *fake) Ping() error          { return nil }
func (f *fake) Hub() *backend.Hub    { return f.hub }
func (f *fake) Handle(method string, params map[string]any) (json.RawMessage, error) {
	f.mu.Lock()
	f.calls = append(f.calls, call{method, params})
	res, ok := f.results[method]
	f.mu.Unlock()
	if !ok {
		return nil, backend.Errorf("unsupported_method", method)
	}
	return json.Marshal(res)
}
func (f *fake) last() call {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.calls[len(f.calls)-1]
}

func decode(t *testing.T, raw json.RawMessage) map[string]any {
	t.Helper()
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatal(err)
	}
	return out
}

func setup() (*Backend, *fake, *fake) {
	c, h := newFake("cmux"), newFake("herdr")
	c.results["workspace.list"] = map[string]any{"workspaces": []any{map[string]any{"id": "ws-uuid", "title": "repo"}}}
	h.results["workspace.list"] = map[string]any{"workspaces": []any{map[string]any{"id": "w1", "title": "repo"}}}
	// cmux's real shape: no top-level id, the record nested under `workspace`.
	c.results["workspace.current"] = map[string]any{"workspace_id": "ws-uuid", "workspace": map[string]any{"id": "ws-uuid", "title": "repo"}}
	h.results["workspace.current"] = map[string]any{"id": "w1"}
	c.results["surface.list"] = map[string]any{"surfaces": []any{map[string]any{"id": "s1", "workspace_id": "ws-uuid", "title": "zsh"}}}
	h.results["surface.list"] = map[string]any{"surfaces": []any{map[string]any{"id": "w1:p1", "workspace_id": "w1", "title": "claude"}}}
	h.results["pane.list"] = map[string]any{"panes": []any{map[string]any{"id": "w1:p1", "surface_ids": []any{"w1:p1"}, "focused_surface_id": "w1:p1"}}}
	c.results["workspace.select"] = map[string]any{"ok": true}
	h.results["workspace.select"] = map[string]any{"ok": true}
	h.results["surface.read_text"] = map[string]any{"text": "hi", "surface_id": "w1:p1"}
	c.results["notification.list"] = map[string]any{"notifications": []any{map[string]any{"id": "n1", "surface_id": "s1", "workspace_id": "ws-uuid", "title": "cmux says"}}}
	h.results["notification.list"] = map[string]any{"notifications": []any{}}
	c.results["notification.clear"] = map[string]any{"ok": true}
	h.results["notification.clear"] = map[string]any{"ok": true}
	c.results["system.ping"] = map[string]any{"pong": true}
	h.results["system.ping"] = map[string]any{"pong": true}
	return New(Member{"cmux", c}, Member{"herdr", h}), c, h
}

func TestWorkspaceListMergesAndNamespaces(t *testing.T) {
	b, _, _ := setup()
	raw, err := b.Handle("workspace.list", nil)
	if err != nil {
		t.Fatal(err)
	}
	list := decode(t, raw)["workspaces"].([]any)
	if len(list) != 2 {
		t.Fatalf("got %v", list)
	}
	first, second := list[0].(map[string]any), list[1].(map[string]any)
	if first["id"] != "cmux:ws-uuid" || first["title"] != "repo" || first["backend"] != "cmux" {
		t.Fatalf("cmux workspace = %v", first)
	}
	if second["id"] != "herdr:w1" || second["title"] != "repo" || second["backend"] != "herdr" {
		t.Fatalf("herdr workspace = %v", second)
	}
}

func TestRoutesByPrefixAndStrips(t *testing.T) {
	b, c, h := setup()
	raw, err := b.Handle("surface.list", map[string]any{"workspace_id": "herdr:w1"})
	if err != nil {
		t.Fatal(err)
	}
	if got := h.last().params["workspace_id"]; got != "w1" {
		t.Fatalf("herdr received workspace_id %v", got)
	}
	surfaces := decode(t, raw)["surfaces"].([]any)
	s := surfaces[0].(map[string]any)
	if s["id"] != "herdr:w1:p1" || s["workspace_id"] != "herdr:w1" {
		t.Fatalf("surface = %v", s)
	}

	// herdr ids contain colons: only the first segment is the namespace.
	raw, err = b.Handle("surface.read_text", map[string]any{"surface_id": "herdr:w1:p1", "lines": float64(50)})
	if err != nil {
		t.Fatal(err)
	}
	if got := h.last().params["surface_id"]; got != "w1:p1" {
		t.Fatalf("herdr received surface_id %v", got)
	}
	if decode(t, raw)["surface_id"] != "herdr:w1:p1" {
		t.Fatalf("read_text result = %s", raw)
	}

	if _, err := b.Handle("surface.list", map[string]any{"workspace_id": "cmux:ws-uuid"}); err != nil {
		t.Fatal(err)
	}
	if got := c.last().params["workspace_id"]; got != "ws-uuid" {
		t.Fatalf("cmux received workspace_id %v", got)
	}

	if _, err := b.Handle("surface.focus", map[string]any{"surface_id": "s1"}); err == nil {
		t.Fatal("un-namespaced id must be rejected")
	}
	if _, err := b.Handle("surface.focus", map[string]any{"surface_id": "cmux:s1", "workspace_id": "herdr:w1"}); err == nil {
		t.Fatal("mixed namespaces must be rejected")
	}
}

func TestPaneListRewritesSurfaceIDs(t *testing.T) {
	b, _, _ := setup()
	raw, err := b.Handle("pane.list", map[string]any{"workspace_id": "herdr:w1"})
	if err != nil {
		t.Fatal(err)
	}
	p := decode(t, raw)["panes"].([]any)[0].(map[string]any)
	if p["id"] != "herdr:w1:p1" || p["focused_surface_id"] != "herdr:w1:p1" {
		t.Fatalf("pane = %v", p)
	}
	if ids := p["surface_ids"].([]any); ids[0] != "herdr:w1:p1" {
		t.Fatalf("surface_ids = %v", ids)
	}
}

func TestCurrentFollowsWorkspaceSelect(t *testing.T) {
	b, c, h := setup()
	// No selection yet: the first connected member (cmux) answers.
	raw, _ := b.Handle("workspace.current", nil)
	cur := decode(t, raw)
	if cur["workspace_id"] != "cmux:ws-uuid" || cur["workspace"].(map[string]any)["id"] != "cmux:ws-uuid" {
		t.Fatalf("current = %s", raw)
	}
	if _, err := b.Handle("workspace.select", map[string]any{"workspace_id": "herdr:w1"}); err != nil {
		t.Fatal(err)
	}
	raw, _ = b.Handle("workspace.current", nil)
	if decode(t, raw)["id"] != "herdr:w1" {
		t.Fatalf("current after select = %s", raw)
	}
	// Un-scoped list calls follow the current member too.
	b.Handle("surface.list", nil)
	if h.last().method != "surface.list" {
		t.Fatalf("surface.list went to %v / %v", c.last(), h.last())
	}
	// And fall back when the current member drops.
	h.connected = false
	raw, _ = b.Handle("workspace.current", nil)
	if decode(t, raw)["workspace_id"] != "cmux:ws-uuid" {
		t.Fatalf("current with herdr down = %s", raw)
	}
}

func TestSelectFailureLeavesCurrentAlone(t *testing.T) {
	b, _, h := setup()
	delete(h.results, "workspace.select")
	if _, err := b.Handle("workspace.select", map[string]any{"workspace_id": "herdr:w1"}); err == nil {
		t.Fatal("expected the select to fail")
	}
	raw, _ := b.Handle("workspace.current", nil)
	if decode(t, raw)["workspace_id"] != "cmux:ws-uuid" {
		t.Fatalf("current moved despite failed select: %s", raw)
	}
}

func TestNotificationClearIsStrict(t *testing.T) {
	b, _, h := setup()
	delete(h.results, "notification.clear")
	if _, err := b.Handle("notification.clear", nil); err == nil {
		t.Fatal("clear that failed on one runtime must not report success")
	}
}

func TestNotificationsMergeAndClearFanOut(t *testing.T) {
	b, c, h := setup()
	raw, err := b.Handle("notification.list", nil)
	if err != nil {
		t.Fatal(err)
	}
	n := decode(t, raw)["notifications"].([]any)[0].(map[string]any)
	if n["id"] != "cmux:n1" || n["surface_id"] != "cmux:s1" || n["workspace_id"] != "cmux:ws-uuid" {
		t.Fatalf("notification = %v", n)
	}
	if _, err := b.Handle("notification.clear", nil); err != nil {
		t.Fatal(err)
	}
	if c.last().method != "notification.clear" || h.last().method != "notification.clear" {
		t.Fatal("clear must reach every member")
	}
}

func TestEventsAreNamespacedAndDisconnectGated(t *testing.T) {
	b, c, h := setup()
	events := b.Hub().Subscribe()
	defer b.Hub().Unsubscribe(events)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go b.Run(ctx)
	time.Sleep(20 * time.Millisecond) // let the forwarders subscribe

	next := func() backend.Event {
		select {
		case ev := <-events:
			return ev
		case <-time.After(time.Second):
			t.Fatal("no event")
			return backend.Event{}
		}
	}
	none := func() {
		select {
		case ev := <-events:
			t.Fatalf("unexpected event %v", ev)
		case <-time.After(50 * time.Millisecond):
		}
	}

	h.hub.Broadcast(backend.Event{Type: "notification.created", Data: map[string]any{"id": "x", "surface_id": "w1:p1", "workspace_id": "w1", "title": "t"}})
	ev := next()
	d := ev.Data.(map[string]any)
	if ev.Type != "notification.created" || d["surface_id"] != "herdr:w1:p1" || d["workspace_id"] != "herdr:w1" || d["id"] != "herdr:x" {
		t.Fatalf("event = %v", ev)
	}

	h.hub.Broadcast(backend.Event{Type: "surface.updated", Data: map[string]any{"surface_id": "w1:p1", "workspace_id": "w1", "agent_status": "blocked"}})
	if d := next().Data.(map[string]any); d["surface_id"] != "herdr:w1:p1" {
		t.Fatalf("surface.updated = %v", d)
	}

	// One member dropping while the other is up is not a bridge-wide outage,
	// but the phone is told which member changed so it can refresh.
	h.connected = false
	h.hub.Broadcast(backend.Event{Type: "backend.disconnected", Data: map[string]any{"backend": "herdr"}})
	if ev := next(); ev.Type != "backend.changed" || ev.Data.(map[string]any)["backend"] != "herdr" {
		t.Fatalf("expected backend.changed for herdr, got %v", ev)
	}
	none()
	c.connected = false
	c.hub.Broadcast(backend.Event{Type: "backend.disconnected", Data: map[string]any{"backend": "cmux"}})
	if ev := next(); ev.Type != "backend.disconnected" {
		t.Fatalf("expected disconnected, got %v", ev)
	}
	c.connected = true
	c.hub.Broadcast(backend.Event{Type: "backend.connected", Data: map[string]any{"backend": "cmux"}})
	if ev := next(); ev.Type != "backend.connected" {
		t.Fatalf("expected connected, got %v", ev)
	}
}

func TestInfoUnionsCapabilities(t *testing.T) {
	b, _, _ := setup()
	info := b.Info()
	if info.Kind != "cmux+herdr" || !info.Capabilities.Browser || !info.Capabilities.AgentStatus {
		t.Fatalf("info = %+v", info)
	}
	if !strings.Contains(info.Kind, "herdr") {
		t.Fatal()
	}
}
