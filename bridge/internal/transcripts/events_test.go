package transcripts

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/itsmaleen/merry/bridge/internal/transcriptrender"
)

func decode(t *testing.T, raw json.RawMessage) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatal(err)
	}
	return m
}

func TestWantsEvents(t *testing.T) {
	for _, c := range []struct {
		params map[string]any
		want   bool
	}{
		{map[string]any{}, false}, {map[string]any{"format": "text"}, false},
		{map[string]any{"format": "events"}, true}, {map[string]any{"format": 3.0}, false},
	} {
		if WantsEvents(c.params) != c.want {
			t.Errorf("%v", c.params)
		}
	}
}

// TestEncodeTextUnchanged pins the text reply's keys: no events/pending leak
// into it, so an older app build sees exactly what it saw before.
func TestEncodeTextUnchanged(t *testing.T) {
	m := decode(t, Encode(Result{Supported: true, AgentKind: "claude", Text: "hi", SessionID: "s", Fingerprint: "f"}))
	keys := []string{"supported", "agent_kind", "text", "session_id", "session_title", "session_missing", "fingerprint", "unchanged", "source"}
	if len(m) != len(keys) {
		t.Errorf("keys = %v", m)
	}
	for _, k := range keys {
		if _, ok := m[k]; !ok {
			t.Errorf("missing %s", k)
		}
	}
}

func claudeFixture(t *testing.T, jsonl string) (string, string) {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	dir := filepath.Join(home, ".claude", "projects", "-work")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	sid := "11111111-2222-3333-4444-555555555555"
	if err := os.WriteFile(filepath.Join(dir, sid+".jsonl"), []byte(jsonl), 0o644); err != nil {
		t.Fatal(err)
	}
	return sid, home
}

const runningBash = `{"type":"assistant","uuid":"a1","timestamp":"2026-11-01T10:00:00Z","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"rm -rf build"}}]}}` + "\n"

func TestEventsEncodeAndPending(t *testing.T) {
	sid, _ := claudeFixture(t, runningBash)
	d := New()
	req := Request{SurfaceID: "p", ResumeBinding: map[string]any{"kind": "claude", "checkpoint_id": sid}, MaxMessages: 50, Events: true}

	// Not blocked: no pending.
	req.AgentStatus = "working"
	res, err := d.Render(req)
	if err != nil {
		t.Fatal(err)
	}
	m := decode(t, Encode(res))
	if _, ok := m["text"]; ok {
		t.Errorf("events reply must not carry text")
	}
	if p, present := m["pending"]; !present || p != nil {
		t.Errorf("pending = %v present=%v, want null", p, present)
	}
	evs := m["events"].([]any)
	if len(evs) != 1 || evs[0].(map[string]any)["status"] != "running" {
		t.Errorf("events = %v", evs)
	}

	// Blocked: approval with the tool and arg.
	req.AgentStatus = "blocked"
	res2, _ := d.Render(req)
	p := decode(t, Encode(res2))["pending"].(map[string]any)
	if p["kind"] != "approval" || p["event_id"] != "toolu_1" || p["tool"] != "Bash" || p["arg"] != "rm -rf build" {
		t.Errorf("pending = %v", p)
	}
	if res.Fingerprint == res2.Fingerprint {
		t.Errorf("fingerprint must change when status flips to blocked")
	}

	// Nothing to show: events is [] and pending null, not omitted.
	empty := Result{Supported: true, EventsFormat: true}
	m = decode(t, Encode(empty))
	if e, ok := m["events"].([]any); !ok || len(e) != 0 {
		t.Errorf("empty events = %v", m["events"])
	}
}

func TestEventsOpencode(t *testing.T) {
	newOpencodeDB(t)
	db := filepath.Join(os.Getenv("XDG_DATA_HOME"), "opencode", "opencode.db")
	sql := `
		insert into message (id, session_id, time_created, time_updated, data)
			values ('msg_2', 'ses_disp001', 20, 20, '{"role":"assistant"}');
		insert into part (id, message_id, session_id, time_created, time_updated, data) values
		('p1','msg_2','ses_disp001',21,21,'{"type":"tool","tool":"bash","callID":"call_a","state":{"status":"completed","input":{"command":"ls"},"output":"x"}}'),
		('p2','msg_2','ses_disp001',22,22,'{"type":"tool","tool":"bash","callID":"call_b","state":{"status":"error","input":{"command":"false"},"error":"boom\nexit 1"}}'),
		('p3','msg_2','ses_disp001',23,23,'{"type":"tool","tool":"edit","callID":"call_c","state":{"status":"running","input":{"filePath":"/a.go","oldString":"a\n","newString":"a\nb\n"}}}'),
		('p4','msg_2','ses_disp001',24,24,'{"type":"tool","tool":"question","callID":"call_q","state":{"status":"completed","input":{"questions":[{"question":"Q?","header":"H","options":[{"label":"Y","description":"d"}]}]},"output":"User has answered","metadata":{"answers":[["Y"]]}}}');`
	if out, err := exec.Command("sqlite3", db, sql).CombinedOutput(); err != nil {
		t.Fatalf("%v %s", err, out)
	}
	d := New()
	res, err := d.Render(Request{SurfaceID: "p", ResumeBinding: map[string]any{"kind": "opencode", "checkpoint_id": "ses_disp001"}, MaxMessages: 50, Events: true})
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Events) != 5 {
		t.Fatalf("events: %+v", res.Events)
	}
	e := res.Events
	if e[0].Kind != "user" || e[0].Text != "hello from opencode" {
		t.Errorf("user: %+v", e[0])
	}
	if e[1].ID != "call_a" || e[1].Status != "ok" || e[1].Arg != "ls" || e[1].Output != "" {
		t.Errorf("ok: %+v", e[1])
	}
	if e[2].Status != "error" || e[2].Output != "boom\nexit 1" {
		t.Errorf("error: %+v", e[2])
	}
	if e[3].Status != "running" || e[3].Added == nil || *e[3].Added != 2 || *e[3].Removed != 1 {
		t.Errorf("running edit: %+v", e[3])
	}
	if e[4].Kind != "question" || !*e[4].Answered || e[4].Answer != "Y" {
		t.Errorf("question: %+v", e[4])
	}
	if res.Pending != nil {
		t.Errorf("pending = %+v", res.Pending)
	}
	text, _ := d.Render(Request{SurfaceID: "p", ResumeBinding: map[string]any{"kind": "opencode", "checkpoint_id": "ses_disp001"}, MaxMessages: 50})
	if text.Fingerprint == res.Fingerprint || text.Text == "" {
		t.Errorf("text vs events fingerprint: %q %q", text.Fingerprint, res.Fingerprint)
	}
}

func pagedFixture(t *testing.T, n int) (*Dispatcher, Request) {
	t.Helper()
	var b string
	for i := 0; i < n; i++ {
		b += fmt.Sprintf(`{"type":"assistant","uuid":"a%02d","timestamp":"2026-11-01T10:00:00Z","message":{"content":[{"type":"text","text":"m%02d"}]}}`+"\n", i, i)
	}
	b += runningBash
	sid, _ := claudeFixture(t, b)
	return New(), Request{SurfaceID: "p", ResumeBinding: map[string]any{"kind": "claude", "checkpoint_id": sid}, MaxMessages: 4, Events: true}
}

func TestPagingClaude(t *testing.T) {
	d, req := pagedFixture(t, 9) // a00..a08 + toolu_1 = 10 events
	req.AgentStatus = "blocked"
	tail, err := d.Render(req)
	if err != nil {
		t.Fatal(err)
	}
	tm := decode(t, Encode(tail))
	if tm["has_more"] != true || tm["pending"] == nil || len(tm["events"].([]any)) != 4 {
		t.Fatalf("tail: %v", tm)
	}
	// Tail reply keys, pinned.
	keys := []string{"supported", "agent_kind", "events", "has_more", "pending", "session_id", "session_title", "session_missing", "fingerprint", "unchanged", "source"}
	if len(tm) != len(keys) {
		t.Errorf("tail keys = %v", tm)
	}

	// Walk back: no gap, no duplicate, pending null even though blocked, never
	// unchanged even when the caller hands back the tail's fingerprint.
	got := append([]transcriptrender.Event{}, tail.Events...)
	for more, pages := true, 0; more; pages++ {
		if pages > 10 {
			t.Fatal("did not terminate")
		}
		pr := req
		pr.Before = got[0].ID
		pr.KnownFingerprint = tail.Fingerprint
		page, err := d.Render(pr)
		if err != nil {
			t.Fatal(err)
		}
		pm := decode(t, Encode(page))
		if pm["pending"] != nil || pm["unchanged"] != false || pm["events"] == nil {
			t.Fatalf("page reply: %v", pm)
		}
		got = append(append([]transcriptrender.Event{}, page.Events...), got...)
		more = page.HasMore
		if pm["has_more"] != more {
			t.Fatalf("has_more key: %v", pm)
		}
	}
	if len(got) != 10 || got[0].ID != "a00" || got[9].ID != "toolu_1" {
		t.Fatalf("reconstructed %d: %+v", len(got), got)
	}
	seen := map[string]bool{}
	for _, e := range got {
		if seen[e.ID] {
			t.Fatalf("duplicate %s", e.ID)
		}
		seen[e.ID] = true
	}

	// Page and tail are never served from each other's cache entry.
	again, _ := d.Render(req)
	if len(again.Events) != 4 || again.Events[3].ID != "toolu_1" {
		t.Fatalf("tail after page: %+v", again.Events)
	}

	// Unknown id.
	req.Before = "nope"
	un, _ := d.Render(req)
	um := decode(t, Encode(un))
	if len(um["events"].([]any)) != 0 || um["has_more"] != false || um["pending"] != nil {
		t.Fatalf("unknown id: %v", um)
	}
}

func TestPagingTailHasMoreFalse(t *testing.T) {
	d, req := pagedFixture(t, 2)
	req.MaxMessages = 50
	res, _ := d.Render(req)
	if res.HasMore || len(res.Events) != 3 {
		t.Fatalf("%+v", res)
	}
}

func TestTextFormatIgnoresBefore(t *testing.T) {
	d, req := pagedFixture(t, 3)
	req.Events = false
	req.Before = "a01"
	res, _ := d.Render(req)
	m := decode(t, Encode(res))
	if _, ok := m["has_more"]; ok {
		t.Errorf("text reply must not carry has_more")
	}
	if res.Text == "" {
		t.Errorf("text reply should be the normal tail")
	}
}
