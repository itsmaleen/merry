package transcriptrender

import (
	"strings"
	"testing"
)

func boolp(b bool) *bool { return &b }

func TestDerivePending(t *testing.T) {
	running := Event{ID: "t1", Kind: KindTool, Tool: "Bash", Arg: "rm -rf build", Status: StatusRunning}
	done := Event{ID: "t0", Kind: KindTool, Tool: "Read", Status: StatusOK}
	openQ := Event{ID: "q1", Kind: KindQuestion, Answered: boolp(false)}
	answeredQ := Event{ID: "q0", Kind: KindQuestion, Answered: boolp(true)}
	text := Event{ID: "x", Kind: KindText, Text: "hi"}

	cases := []struct {
		name   string
		events []Event
		status string
		want   *Pending
	}{
		{"question beats status", []Event{done, openQ}, "working", &Pending{Kind: "question", EventID: "q1"}},
		{"question, blocked too", []Event{openQ}, "blocked", &Pending{Kind: "question", EventID: "q1"}},
		{"question without status (cmux)", []Event{openQ}, "", &Pending{Kind: "question", EventID: "q1"}},
		{"approval", []Event{text, running}, "blocked", &Pending{Kind: "approval", EventID: "t1", Tool: "Bash", Arg: "rm -rf build"}},
		{"blocked, last is finished tool", []Event{running, done}, "blocked", &Pending{Kind: "unknown"}},
		{"blocked, answered question", []Event{answeredQ}, "blocked", &Pending{Kind: "unknown"}},
		{"blocked, no events", nil, "blocked", &Pending{Kind: "unknown"}},
		{"running tool, working", []Event{running}, "working", nil},
		{"running tool, cmux", []Event{running}, "", nil},
		{"idle", []Event{text}, "idle", nil},
	}
	for _, c := range cases {
		got := DerivePending(c.events, c.status)
		if (got == nil) != (c.want == nil) || (got != nil && *got != *c.want) {
			t.Errorf("%s: got %+v want %+v", c.name, got, c.want)
		}
	}
}

func TestOutputTail(t *testing.T) {
	if got := OutputTail("a\nb\nc\nd\ne\nf\ng\nh\n"); got != "c\nd\ne\nf\ng\nh" {
		t.Errorf("lines: %q", got)
	}
	long := OutputTail(strings.Repeat("é", 1000))
	if len(long) > MaxOutputBytes || !strings.HasSuffix(long, "é") || strings.ContainsRune(long, '�') {
		t.Errorf("bytes: %d", len(long))
	}
	if OutputTail("  \n") != "" {
		t.Errorf("blank")
	}
}

func TestToolArgPriorityAndLimit(t *testing.T) {
	in := map[string]any{"description": "d", "file_path": "/x", "command": "  go   test\n./... "}
	if got := ToolArg(in, 200); got != "go test ./..." {
		t.Errorf("priority: %q", got)
	}
	long := ToolArg(map[string]any{"command": strings.Repeat("a", 300)}, MaxEventArgRunes)
	if r := []rune(long); len(r) != MaxEventArgRunes+1 || r[len(r)-1] != '…' {
		t.Errorf("limit: %d", len(r))
	}
}

func TestCapEvents(t *testing.T) {
	var evs []Event
	for i := 0; i < 5; i++ {
		evs = append(evs, Event{ID: string(rune('a' + i)), Kind: KindText, Text: "x"})
	}
	if got := CapEvents(evs, 2); len(got) != 2 || got[0].ID != "d" {
		t.Errorf("count cap: %+v", got)
	}
	huge := []Event{{ID: "old", Kind: KindText, Text: strings.Repeat("o", MaxRenderBytes)}, {ID: "new", Kind: KindText, Text: "n"}}
	if got := CapEvents(huge, 10); len(got) != 1 || got[0].ID != "new" {
		t.Errorf("byte cap: %+v", got)
	}
}

func idsOf(evs []Event) string {
	var s []string
	for _, e := range evs {
		s = append(s, e.ID)
	}
	return strings.Join(s, ",")
}

func numbered(n int, text string) []Event {
	evs := make([]Event, n)
	for i := range evs {
		evs[i] = Event{ID: "e" + string(rune('a'+i)), Kind: KindText, Text: text}
	}
	return evs
}

func TestPageEvents(t *testing.T) {
	evs := numbered(10, "x") // ea..ej
	cases := []struct {
		name, before string
		max          int
		ids          string
		more         bool
	}{
		{"tail with more", "", 4, "eg,eh,ei,ej", true},
		{"tail all", "", 10, "ea,eb,ec,ed,ee,ef,eg,eh,ei,ej", false},
		{"tail max larger", "", 50, "ea,eb,ec,ed,ee,ef,eg,eh,ei,ej", false},
		{"page", "eg", 3, "ed,ee,ef", true},
		{"page reaching the start", "ed", 3, "ea,eb,ec", false},
		{"page partial", "ec", 5, "ea,eb", false},
		{"before first", "ea", 5, "", false},
		{"unknown id", "nope", 5, "", false},
	}
	for _, c := range cases {
		got, more := PageEvents(evs, c.before, c.max)
		if got == nil || idsOf(got) != c.ids || more != c.more {
			t.Errorf("%s: got %q more=%v want %q more=%v", c.name, idsOf(got), more, c.ids, c.more)
		}
	}
}

func TestPageEventsWalkBackHasNoGapOrDuplicate(t *testing.T) {
	evs := numbered(23, "x")
	page, more := PageEvents(evs, "", 5)
	got := append([]Event{}, page...)
	for more {
		page, more = PageEvents(evs, got[0].ID, 5)
		got = append(append([]Event{}, page...), got...)
	}
	if idsOf(got) != idsOf(evs) {
		t.Fatalf("walk: %s", idsOf(got))
	}
}

func TestPageEventsByteCapKeepsNearestBefore(t *testing.T) {
	evs := numbered(10, strings.Repeat("y", 40*1024))
	page, more := PageEvents(evs, "ei", 100)
	if len(page) == 0 || len(page) >= 8 || !more {
		t.Fatalf("len=%d more=%v", len(page), more)
	}
	if page[len(page)-1].ID != "eh" {
		t.Fatalf("page must end just before ei: %s", idsOf(page))
	}
}
