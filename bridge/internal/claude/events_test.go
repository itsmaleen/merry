package claude

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/itsmaleen/merry/bridge/internal/transcriptrender"
)

// jl joins JSONL lines.
func jl(lines ...string) []byte { return []byte(strings.Join(lines, "\n") + "\n") }

func asst(uuid, ts, blocks string) string {
	return `{"type":"assistant","uuid":"` + uuid + `","timestamp":"` + ts + `","isSidechain":false,"message":{"role":"assistant","content":[` + blocks + `]}}`
}

func usr(uuid, content string, extra string) string {
	return `{"type":"user","uuid":"` + uuid + `","timestamp":"2026-11-01T10:00:00.000Z","isSidechain":false` + extra + `,"message":{"role":"user","content":` + content + `}}`
}

func toolUse(id, name, input string) string {
	return `{"type":"tool_use","id":"` + id + `","name":"` + name + `","input":` + input + `}`
}

func toolResult(id, content string, isErr bool) string {
	e := ""
	if isErr {
		e = `,"is_error":true`
	}
	return `{"type":"tool_result","tool_use_id":"` + id + `","content":` + content + e + `}`
}

func TestParseEventsTools(t *testing.T) {
	const ts = "2026-11-01T10:00:05.000Z"
	data := jl(
		usr("u1", `"fix the test"`, ""),
		asst("a1", ts, `{"type":"thinking","thinking":"hmm"},{"type":"text","text":"Looking."}`),
		asst("a2", ts, toolUse("toolu_1", "Read", `{"file_path":"/a/b.go"}`)),
		usr("u2", `[`+toolResult("toolu_1", `"package b"`, false)+`]`, ""),
		asst("a3", ts, toolUse("toolu_2", "Bash", `{"command":"go test ./..."}`)),
		usr("u3", `[`+toolResult("toolu_2", `[{"type":"text","text":"l1\nl2\nl3\nl4\nl5\nl6\nl7\nFAIL"}]`, true)+`]`, ""),
		asst("a4", ts, toolUse("toolu_3", "Edit", `{"file_path":"/a/b.go","old_string":"x\ny\n","new_string":"x\ny\nz\n"}`)),
		usr("u4", `[`+toolResult("toolu_3", `"ok"`, false)+`]`, ""),
		asst("a5", ts, toolUse("toolu_4", "Bash", `{"command":"sleep 100"}`)),
	)
	evs := parseEvents(data)
	if len(evs) != 6 {
		b, _ := json.MarshalIndent(evs, "", " ")
		t.Fatalf("got %d events: %s", len(evs), b)
	}
	want := []struct{ id, kind, status string }{
		{"u1", "user", ""}, {"a1", "text", ""}, {"toolu_1", "tool", "ok"},
		{"toolu_2", "tool", "error"}, {"toolu_3", "tool", "ok"}, {"toolu_4", "tool", "running"},
	}
	for i, w := range want {
		if evs[i].ID != w.id || evs[i].Kind != w.kind || evs[i].Status != w.status {
			t.Errorf("event %d = %+v, want %+v", i, evs[i], w)
		}
	}
	if evs[1].TS != 1793527205 && evs[1].TS == 0 {
		t.Errorf("ts not parsed: %d", evs[1].TS)
	}
	if evs[2].Arg != "/a/b.go" || evs[2].Output != "" {
		t.Errorf("ok tool: %+v", evs[2])
	}
	if got := evs[3].Output; got != "l3\nl4\nl5\nl6\nl7\nFAIL" {
		t.Errorf("error output tail = %q", got)
	}
	if evs[4].Added == nil || *evs[4].Added != 3 || *evs[4].Removed != 2 {
		t.Errorf("edit counts = %v/%v", evs[4].Added, evs[4].Removed)
	}
	if evs[5].Output != "" {
		t.Errorf("running tool must have no output")
	}
}

func TestParseEventsQuestion(t *testing.T) {
	q := `{"questions":[{"question":"Which?","header":"Pick","multiSelect":true,"options":[{"label":"A","description":"a"},{"label":"B","description":"b"}]}]}`
	ts := "2026-11-01T10:00:05.000Z"
	unanswered := jl(asst("a1", ts, toolUse("toolu_q", "AskUserQuestion", q)))
	evs := parseEvents(unanswered)
	if len(evs) != 1 || evs[0].Kind != "question" || evs[0].Answered == nil || *evs[0].Answered {
		t.Fatalf("unanswered: %+v", evs)
	}
	if qs := evs[0].Questions; len(qs) != 1 || !qs[0].Multi || qs[0].Header != "Pick" || len(qs[0].Options) != 2 || qs[0].Options[1].Label != "B" {
		t.Fatalf("questions: %+v", qs)
	}

	resLine := `{"type":"user","uuid":"u2","timestamp":"` + ts + `","message":{"role":"user","content":[` +
		toolResult("toolu_q", `"Your questions have been answered: \"Which?\"=\"B\". You can now continue."`, false) +
		`]},"toolUseResult":{"questions":[],"answers":{"Which?":"B"}}}`
	evs = parseEvents(jl(asst("a1", ts, toolUse("toolu_q", "AskUserQuestion", q)), resLine))
	if len(evs) != 1 || !*evs[0].Answered || evs[0].Answer != "B" {
		t.Fatalf("answered: %+v", evs)
	}

	declined := `{"type":"user","uuid":"u2","message":{"role":"user","content":[` + toolResult("toolu_q", `"The user doesn't want to proceed"`, true) + `]}}`
	evs = parseEvents(jl(asst("a1", ts, toolUse("toolu_q", "AskUserQuestion", q)), declined))
	if !*evs[0].Answered || evs[0].Answer != "(declined)" {
		t.Fatalf("declined: %+v", evs[0])
	}
}

func TestParseEventsUserNoise(t *testing.T) {
	data := jl(
		usr("u1", `"<system-reminder>\nstuff\n</system-reminder>"`, ""),
		usr("u2", `[{"type":"text","text":"<local-command-stdout>Set model</local-command-stdout>"}]`, ""),
		usr("u3", `"<local-command-caveat>The command below</local-command-caveat>"`, `,"isMeta":true`),
		usr("u4", `"<task-notification>\n<task-id>x</task-id></task-notification>"`, ""),
		usr("u5", `"<command-message>model</command-message>\n<command-name>/model</command-name>\n<command-args>opus</command-args>"`, ""),
		usr("u6", `[{"type":"text","text":"real ask <system-reminder>x</system-reminder>"},{"type":"text","text":"second"}]`, ""),
		usr("u7", `"meta body"`, `,"isMeta":true`),
		usr("u8", `[{"type":"tool_result","tool_use_id":"gone","content":"orphan"}]`, ""),
	)
	evs := parseEvents(data)
	var got []string
	for _, e := range evs {
		got = append(got, e.ID+"="+e.Command+"|"+e.Text)
	}
	want := "u5=/model|opus|u6:0=|real ask|u6:1=|second"
	if strings.Join(got, "|") != want {
		t.Fatalf("got %q want %q", strings.Join(got, "|"), want)
	}
}

func TestParseEventsSidechainDropped(t *testing.T) {
	sc := `{"type":"assistant","uuid":"s1","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"subagent"}]}}`
	scUser := `{"type":"user","uuid":"s2","isSidechain":true,"message":{"role":"user","content":"sub prompt"}}`
	evs := parseEvents(jl(sc, scUser, asst("a1", "2026-11-01T10:00:00Z", toolUse("toolu_a", "Task", `{"description":"explore","subagent_type":"Explore"}`))))
	if len(evs) != 1 || evs[0].Tool != "Task" || evs[0].Arg != "Explore" {
		t.Fatalf("%+v", evs)
	}
}

func TestParseEventsTailCutOff(t *testing.T) {
	// A tail read starts mid-line and a result's call may be before the window.
	data := []byte(`ial":"x"}}` + "\n" + usr("u1", `[`+toolResult("toolu_gone", `"x"`, true)+`]`, "") + "\n" +
		asst("a1", "2026-11-01T10:00:00Z", `{"type":"text","text":"hi"}`) + "\n")
	evs := parseEvents(data)
	if len(evs) != 1 || evs[0].Text != "hi" {
		t.Fatalf("%+v", evs)
	}
}

func TestRenderEventsCaps(t *testing.T) {
	var lines []string
	for i := 0; i < 10; i++ {
		lines = append(lines, asst("a"+string(rune('a'+i)), "2026-11-01T10:00:00Z", `{"type":"text","text":"m`+string(rune('a'+i))+`"}`))
	}
	evs, _ := renderEvents(jl(lines...), 3, "")
	if len(evs) != 3 || evs[2].Text != "mj" || evs[0].Text != "mh" {
		t.Fatalf("max events: %+v", evs)
	}
	big := strings.Repeat("x", 40*1024)
	lines = nil
	for i := 0; i < 10; i++ {
		lines = append(lines, asst("b"+string(rune('a'+i)), "2026-11-01T10:00:00Z", `{"type":"text","text":"`+big+string(rune('a'+i))+`"}`))
	}
	evs, _ = renderEvents(jl(lines...), 100, "")
	b, _ := json.Marshal(evs)
	if len(b) > transcriptrender.MaxRenderBytes+len(evs) || len(evs) == 0 || len(evs) >= 10 {
		t.Fatalf("byte cap: %d events, %d bytes", len(evs), len(b))
	}
	if !strings.HasSuffix(evs[len(evs)-1].Text, "j") {
		t.Fatalf("cap must keep the tail")
	}
	if got, _ := renderEvents(nil, 10, ""); got == nil || len(got) != 0 {
		t.Fatalf("empty must be non-nil empty slice")
	}
}

// TestResolverEventsFingerprint covers the format-specific fingerprint, the
// status salt and the unchanged short-circuit.
func TestResolverEventsFingerprint(t *testing.T) {
	home := t.TempDir()
	dir := filepath.Join(home, ".claude", "projects", "-work")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	sid := "11111111-2222-3333-4444-555555555555"
	body := jl(usr("u1", `"hello"`, ""), asst("a1", "2026-11-01T10:00:00Z", toolUse("toolu_1", "Bash", `{"command":"ls"}`)))
	if err := os.WriteFile(filepath.Join(dir, sid+".jsonl"), body, 0o644); err != nil {
		t.Fatal(err)
	}
	r := newResolver(home)
	base := Request{SurfaceID: "s", ResumeBinding: map[string]any{"kind": "claude", "checkpoint_id": sid}, MaxMessages: 50}

	text, err := r.Render(base)
	if err != nil || !strings.Contains(text.Text, "hello") || text.Events != nil {
		t.Fatalf("text: %+v %v", text, err)
	}
	ev := base
	ev.Events = true
	working, err := r.Render(ev)
	if err != nil || working.Text != "" || len(working.Events) != 2 {
		t.Fatalf("events: %+v %v", working, err)
	}
	blocked := ev
	blocked.AgentStatus = "blocked"
	b, _ := r.Render(blocked)
	if text.Fingerprint == working.Fingerprint || working.Fingerprint == b.Fingerprint {
		t.Fatalf("fingerprints must differ by format and status: %s %s %s", text.Fingerprint, working.Fingerprint, b.Fingerprint)
	}
	// Same format + status: unchanged.
	again := ev
	again.KnownFingerprint = working.Fingerprint
	if res, _ := r.Render(again); !res.Unchanged || len(res.Events) != 0 {
		t.Fatalf("want unchanged: %+v", res)
	}
	// A status flip is not unchanged.
	flip := blocked
	flip.KnownFingerprint = working.Fingerprint
	if res, _ := r.Render(flip); res.Unchanged {
		t.Fatalf("status flip answered unchanged")
	}
	// A text fingerprint is not honoured by an events request.
	cross := ev
	cross.KnownFingerprint = text.Fingerprint
	if res, _ := r.Render(cross); res.Unchanged {
		t.Fatalf("text fingerprint must not match events request")
	}
}

func cmdLine(name, args string) string {
	c := `"<command-message>x</command-message>\n<command-name>` + name + `</command-name>`
	if args != "" {
		c += `\n<command-args>` + args + `</command-args>`
	}
	return c + `"`
}

const companionText = `[{"type":"text","text":"# injected skill prompt"}]`

func TestParseEventsCommands(t *testing.T) {
	data := jl(
		usr("c1", cmdLine("/loop", "5m check the deploy"), `,"promptId":"p1"`),
		usr("m1", companionText, `,"isMeta":true,"turnCompanion":true,"promptId":"p1"`),
		usr("c2", cmdLine("/status", ""), `,"promptId":"p2"`),
		usr("m2", companionText, `,"isMeta":true,"promptId":"p2"`), // no turnCompanion
		usr("c3", cmdLine("/model", "opus"), `,"promptId":"p3"`),
		usr("m3", companionText, `,"isMeta":true,"turnCompanion":true,"promptId":"other"`),
		usr("c4", cmdLine("/clear", ""), ""),
	)
	evs := parseEvents(data)
	type row struct {
		id, cmd, text string
		skill         bool
	}
	var got []row
	for _, e := range evs {
		got = append(got, row{e.ID, e.Command, e.Text, e.SkillLoaded})
	}
	want := []row{
		{"c1", "/loop", "5m check the deploy", true},
		{"c2", "/status", "", false},
		{"c3", "/model", "opus", false},
		{"c4", "/clear", "", false},
	}
	if len(got) != len(want) {
		t.Fatalf("got %+v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("event %d = %+v, want %+v", i, got[i], want[i])
		}
	}
	b, _ := json.Marshal(evs[0])
	if want := `{"id":"c1","kind":"user","ts":1793527200,"text":"5m check the deploy","command":"/loop","skill_loaded":true}`; string(b) != want {
		t.Errorf("json = %s", b)
	}
}

func TestParseEventsScheduledRuns(t *testing.T) {
	sched := func(task string) string { return `,"scheduledTaskId":"` + task + `","scheduledFireId":"f"` }
	data := jl(
		usr("h", cmdLine("/loop", "5m go"), `,"promptId":"p0"`),
		usr("m0", companionText, `,"isMeta":true,"turnCompanion":true,"promptId":"p0"`),
		usr("r1", cmdLine("/loop", "5m go"), `,"promptId":"p1"`+sched("t1")),
		usr("m1", companionText, `,"isMeta":true,"turnCompanion":true,"promptId":"p1"`+sched("t1")),
		usr("o1", `"other task fire"`, sched("t2")),
		usr("r2", cmdLine("/loop", "5m go"), `,"promptId":"p2"`+sched("t1")),
		usr("m2", companionText, `,"isMeta":true,"turnCompanion":true,"promptId":"p2"`+sched("t1")),
		usr("o2", `"other task fire"`, sched("t2")),
		usr("hu", `"plain human"`, ""),
	)
	evs := parseEvents(data)
	type row struct {
		id    string
		sched bool
		run   int
		skill bool
	}
	var got []row
	for _, e := range evs {
		got = append(got, row{e.ID, e.Scheduled, e.Run, e.SkillLoaded})
	}
	want := []row{
		{"h", false, 0, true}, {"r1", true, 1, true}, {"o1", true, 1, false},
		{"r2", true, 2, true}, {"o2", true, 2, false}, {"hu", false, 0, false},
	}
	if len(got) != len(want) {
		t.Fatalf("got %+v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("event %d = %+v, want %+v", i, got[i], want[i])
		}
	}
	b, _ := json.Marshal(evs[3])
	if want := `"command":"/loop","skill_loaded":true,"scheduled":true,"run":2}`; !strings.HasSuffix(string(b), want) {
		t.Errorf("json = %s", b)
	}

	// Capping to the last 2 events keeps the run numbers computed before it.
	capped, _ := renderEvents(data, 2, "")
	if len(capped) != 2 || capped[0].ID != "o2" || capped[0].Run != 2 {
		t.Errorf("capped = %+v", capped)
	}
}

func qop(op, ts, content, extra string) string {
	s := `{"type":"queue-operation","operation":"` + op + `","timestamp":"` + ts + `"`
	if content != "" {
		s += `,"content":` + strconv.Quote(content)
	}
	return s + extra + `}`
}

func qatt(uuid, ts, prompt string) string {
	return `{"type":"attachment","uuid":"` + uuid + `","timestamp":"` + ts + `","attachment":{"type":"queued_command","prompt":` + prompt + `}}`
}

func TestQueuedEnqueueOnly(t *testing.T) {
	evs := parseEvents(jl(
		usr("u1", `"go"`, ""),
		asst("a1", "2026-11-01T10:00:00Z", toolUse("toolu_1", "Bash", `{"command":"ls"}`)),
		qop("enqueue", "2026-11-01T10:00:05.123Z", "also fix the tests", ""),
		qop("enqueue", "2026-11-01T10:00:06.000Z", "/loop 5m check", ""),
	))
	if len(evs) != 4 {
		t.Fatalf("%+v", evs)
	}
	q := evs[2]
	if !q.Queued || q.Kind != "user" || q.Text != "also fix the tests" || q.ID != "q:2026-11-01T10:00:05.123Z" || q.TS == 0 {
		t.Fatalf("%+v", q)
	}
	b, _ := json.Marshal(q)
	t.Log(string(b))
	if !evs[3].Queued || evs[3].Command != "/loop" || evs[3].Text != "5m check" {
		t.Fatalf("%+v", evs[3])
	}
	if evs[0].Queued || evs[1].Queued {
		t.Fatalf("only the enqueued are queued")
	}
	// A queued event never counts toward pending: the running tool is still last.
	p := transcriptrender.DerivePending(evs, "blocked")
	if p == nil || p.Kind != "approval" || p.EventID != "toolu_1" {
		t.Fatalf("pending: %+v", p)
	}
}

func TestQueuedDequeueThenUserLine(t *testing.T) {
	evs := parseEvents(jl(
		qop("enqueue", "2026-11-01T10:00:05Z", "next thing", ""),
		qop("dequeue", "2026-11-01T10:00:09Z", "", ""),
		usr("u2", `"next thing"`, ""),
	))
	if len(evs) != 1 || evs[0].Queued || evs[0].ID != "u2" {
		t.Fatalf("%+v", evs)
	}
}

func TestQueuedAbsorbedMidTurnAttachment(t *testing.T) {
	evs := parseEvents(jl(
		asst("a1", "2026-11-01T10:00:00Z", toolUse("toolu_1", "Bash", `{"command":"ls"}`)),
		qop("enqueue", "2026-11-01T10:00:05Z", "also why", ""),
		usr("u9", `[`+toolResult("toolu_1", `"ok"`, false)+`]`, ""),
		qop("remove", "2026-11-01T10:00:06Z", "also why", `,"reason":"absorbed_mid_turn"`),
		qatt("att1", "2026-11-01T10:00:05Z", `"also why"`),
		asst("a2", "2026-11-01T10:00:07Z", `{"type":"text","text":"ok"}`),
	))
	if len(evs) != 3 || evs[1].ID != "att1" || evs[1].Kind != "user" || evs[1].Text != "also why" || evs[1].Queued {
		t.Fatalf("%+v", evs)
	}
	// Remove without content (FIFO) also clears it; attachment prompt as blocks.
	evs = parseEvents(jl(
		qop("enqueue", "2026-11-01T10:00:05Z", "x1", ""),
		qop("remove", "2026-11-01T10:00:06Z", "", ""),
		qatt("att2", "2026-11-01T10:00:05Z", `[{"type":"text","text":"x1"}]`),
	))
	if len(evs) != 1 || evs[0].ID != "att2" || evs[0].Text != "x1" {
		t.Fatalf("%+v", evs)
	}
}

func TestQueuedNoiseAndPopAll(t *testing.T) {
	evs := parseEvents(jl(
		qop("enqueue", "2026-11-01T10:00:05Z", "<task-notification>\n<task-id>b</task-id></task-notification>", ""),
		qatt("att3", "2026-11-01T10:00:05Z", `"<task-notification>x</task-notification>"`),
		qop("enqueue", "2026-11-01T10:00:06Z", "one", ""),
		qop("enqueue", "2026-11-01T10:00:07Z", "two", ""),
	))
	if len(evs) != 2 || evs[0].Text != "one" || evs[1].Text != "two" || !evs[0].Queued {
		t.Fatalf("noise: %+v", evs)
	}
	evs = parseEvents(jl(
		qop("enqueue", "2026-11-01T10:00:06Z", "one", ""),
		qop("enqueue", "2026-11-01T10:00:07Z", "two", ""),
		qop("popAll", "2026-11-01T10:00:08Z", "one\ntwo", ""),
	))
	if len(evs) != 0 {
		t.Fatalf("popAll must clear the queue: %+v", evs)
	}
	// A dequeue whose enqueue fell outside the tail window is a no-op.
	if evs = parseEvents(jl(qop("dequeue", "2026-11-01T10:00:08Z", "", ""))); len(evs) != 0 {
		t.Fatalf("%+v", evs)
	}
}

func TestQueuedNeverInPage(t *testing.T) {
	data := jl(
		asst("a1", "2026-11-01T10:00:00Z", `{"type":"text","text":"1"}`),
		asst("a2", "2026-11-01T10:00:01Z", `{"type":"text","text":"2"}`),
		asst("a3", "2026-11-01T10:00:02Z", `{"type":"text","text":"3"}`),
		qop("enqueue", "2026-11-01T10:00:05Z", "queued one", ""),
	)
	tail, more := renderEvents(data, 3, "")
	if len(tail) != 3 || !tail[2].Queued || tail[0].ID != "a2" || !more {
		t.Fatalf("tail: %+v %v", tail, more)
	}
	page, more := renderEvents(data, 5, "a3")
	if len(page) != 2 || page[1].ID != "a2" || more {
		t.Fatalf("page: %+v %v", page, more)
	}
	if got, _ := renderEvents(data, 5, "q:2026-11-01T10:00:05Z"); len(got) != 0 {
		t.Fatalf("queued id as before: %+v", got)
	}
}

func TestParseEventsCommandOutput(t *testing.T) {
	out := func(uuid, tag, body, extra string) string {
		return usr(uuid, `"<local-command-`+tag+`>`+body+`</local-command-`+tag+`>"`, extra)
	}
	data := jl(
		usr("c1", cmdLine("/model", ""), `,"promptId":"p1"`),
		out("o1", "stdout", `Set model to \u001b[1mOpus 5\u001b[22m and saved\n`, `,"promptId":"p1","parentUuid":"c1"`),
		usr("c2", cmdLine("/foo", ""), `,"promptId":"p2"`),
		out("o2", "stderr", `bad thing`, `,"promptId":"p2","parentUuid":"c2"`),
		usr("c3", cmdLine("/clear", ""), `,"promptId":"p3"`),
		out("o3", "stdout", ``, `,"promptId":"p3","parentUuid":"c3"`),
		usr("c4", cmdLine("/loop", "5m go"), `,"promptId":"p4"`),
		usr("m4", companionText, `,"isMeta":true,"turnCompanion":true,"promptId":"p4"`),
		out("o5", "stdout", `orphan`, `,"promptId":"zzz","parentUuid":"nope"`),
		usr("c6", cmdLine("/context", ""), `,"promptId":"p6"`),
		out("o6", "stdout", `1\n2\n3\n4\n5\n6\n7\n8`, `,"parentUuid":"c6"`),
		usr("c7", cmdLine("/big", ""), `,"promptId":"p7"`),
		out("o7", "stdout", strings.Repeat("x", 2000), `,"promptId":"p7"`),
	)
	evs := parseEvents(data)
	if len(evs) != 6 {
		t.Fatalf("want 6 command events and no output events, got %d: %+v", len(evs), evs)
	}
	if evs[0].CommandOutput != "Set model to Opus 5 and saved" || evs[0].CommandError {
		t.Fatalf("stdout/ansi: %+v", evs[0])
	}
	if evs[1].CommandOutput != "bad thing" || !evs[1].CommandError {
		t.Fatalf("stderr: %+v", evs[1])
	}
	if evs[2].CommandOutput != "" || evs[2].CommandError {
		t.Fatalf("empty: %+v", evs[2])
	}
	if !evs[3].SkillLoaded || evs[3].CommandOutput != "" {
		t.Fatalf("skill_loaded unaffected: %+v", evs[3])
	}
	if evs[4].CommandOutput != "3\n4\n5\n6\n7\n8" {
		t.Fatalf("parentUuid match and 6-line cap: %q", evs[4].CommandOutput)
	}
	if len(evs[5].CommandOutput) > 600 || evs[5].CommandOutput == "" {
		t.Fatalf("byte cap: %d", len(evs[5].CommandOutput))
	}
	b, _ := json.Marshal(evs[1])
	if !strings.Contains(string(b), `"command_error":true`) {
		t.Fatalf("json: %s", b)
	}
	if strings.Contains(string(mustJSON(evs[2])), "command_output") {
		t.Fatal("empty output must be absent")
	}
}

func mustJSON(v any) []byte { b, _ := json.Marshal(v); return b }

func TestParseEventsCompactSummary(t *testing.T) {
	data := jl(
		usr("u1", `"before"`, ""),
		usr("c1", `"This session is being continued from a previous conversation. Summary: lots of text"`, `,"isCompactSummary":true,"isVisibleInTranscriptOnly":true`),
		usr("u2", `"after"`, ""),
	)
	evs := parseEvents(data)
	if len(evs) != 3 {
		t.Fatalf("events: %+v", evs)
	}
	if !evs[1].Compacted || evs[1].Text != "" || evs[1].ID != "c1" {
		t.Fatalf("summary should be an empty compacted marker: %+v", evs[1])
	}
	if evs[0].Compacted || evs[2].Compacted || evs[2].Text != "after" {
		t.Fatalf("neighbours changed: %+v", evs)
	}
}
