package transcriptrender

import (
	"encoding/json"
	"strings"
	"unicode/utf8"
)

// Event kinds and tool statuses on the wire (format "events").
const (
	KindUser     = "user"
	KindText     = "text"
	KindTool     = "tool"
	KindQuestion = "question"

	StatusRunning = "running"
	StatusOK      = "ok"
	StatusError   = "error"

	PendingApproval = "approval"
	PendingQuestion = "question"
	PendingUnknown  = "unknown"
)

// Limits for typed events. MaxRenderBytes (render.go) bounds the whole list.
const (
	MaxEventArgRunes   = 200
	MaxOutputLines     = 6
	MaxOutputBytes     = 600
	AgentStatusBlocked = "blocked"
)

// Event is one typed transcript item. Which fields are set depends on Kind;
// see plans/session-ui.md, "Wire contract".
type Event struct {
	ID   string `json:"id"`
	Kind string `json:"kind"`
	// TS is unix seconds, 0 (omitted) when the source gave no timestamp.
	TS int64 `json:"ts,omitempty"`

	// user, text
	Text string `json:"text,omitempty"`

	// user: slash commands and scheduled runs (plans/session-ui.md).
	// Command is the name with its slash and Text holds only the args.
	// SkillLoaded: the harness injected a prompt for the command. Scheduled:
	// the harness fired the line. Run: 1-based fire count of that scheduled task.
	Command     string `json:"command,omitempty"`
	SkillLoaded bool   `json:"skill_loaded,omitempty"`
	Scheduled   bool   `json:"scheduled,omitempty"`
	Run         int    `json:"run,omitempty"`
	// CommandOutput: what a local command printed (ANSI stripped, last 6
	// lines, at most 600 bytes); CommandError: it came from stderr.
	CommandOutput string `json:"command_output,omitempty"`
	CommandError  bool   `json:"command_error,omitempty"`
	// Queued: the human sent this while the agent was working and the agent has
	// not taken it yet. Queued events trail all others and are never pending.
	Queued bool `json:"queued,omitempty"`
	// Compacted: the harness replaced the earlier conversation with a summary
	// here. Text is empty: the summary itself is never sent.
	Compacted bool `json:"compacted,omitempty"`

	// tool
	Tool    string `json:"tool,omitempty"`
	Arg     string `json:"arg,omitempty"`
	Status  string `json:"status,omitempty"`
	Output  string `json:"output,omitempty"`
	Added   *int   `json:"added,omitempty"`
	Removed *int   `json:"removed,omitempty"`

	// question
	Questions []Question `json:"questions,omitempty"`
	Answered  *bool      `json:"answered,omitempty"`
	Answer    string     `json:"answer,omitempty"`
}

// Question is one entry of an AskUserQuestion call.
type Question struct {
	Question string           `json:"question"`
	Header   string           `json:"header"`
	Multi    bool             `json:"multi"`
	Options  []QuestionOption `json:"options"`
}

// QuestionOption is one choice of a Question.
type QuestionOption struct {
	Label       string `json:"label"`
	Description string `json:"description"`
}

// Pending says what the session is waiting on from the human.
type Pending struct {
	Kind    string `json:"kind"`
	EventID string `json:"event_id,omitempty"`
	Tool    string `json:"tool,omitempty"`
	Arg     string `json:"arg,omitempty"`
}

// ParseQuestions reads AskUserQuestion's `questions` input.
func ParseQuestions(input map[string]any) []Question {
	raw, ok := input["questions"].([]any)
	if !ok {
		return nil
	}
	out := make([]Question, 0, len(raw))
	for _, item := range raw {
		m, _ := item.(map[string]any)
		if m == nil {
			continue
		}
		q := Question{
			Question: stringValue(m["question"]),
			Header:   stringValue(m["header"]),
			Options:  []QuestionOption{},
		}
		q.Multi, _ = m["multiSelect"].(bool)
		if opts, ok := m["options"].([]any); ok {
			for _, o := range opts {
				om, _ := o.(map[string]any)
				if om == nil {
					continue
				}
				q.Options = append(q.Options, QuestionOption{
					Label:       stringValue(om["label"]),
					Description: stringValue(om["description"]),
				})
			}
		}
		out = append(out, q)
	}
	return out
}

// OutputTail keeps the last MaxOutputLines lines of a tool result, at most
// MaxOutputBytes bytes, cutting on a rune boundary.
func OutputTail(s string) string {
	s = strings.TrimRight(s, " \t\r\n")
	if s == "" {
		return ""
	}
	lines := strings.Split(s, "\n")
	if len(lines) > MaxOutputLines {
		lines = lines[len(lines)-MaxOutputLines:]
	}
	s = strings.Join(lines, "\n")
	if len(s) > MaxOutputBytes {
		s = s[len(s)-MaxOutputBytes:]
		for len(s) > 0 && !utf8.RuneStart(s[0]) {
			s = s[1:]
		}
	}
	return s
}

// LineCount counts lines of s; a trailing newline does not add one.
func LineCount(s string) int {
	if s == "" {
		return 0
	}
	n := strings.Count(s, "\n")
	if !strings.HasSuffix(s, "\n") {
		n++
	}
	return n
}

// DiffCounts estimates added/removed line counts for the file-editing tools
// (Claude's Edit/Write/MultiEdit, opencode's edit/write) from the call input.
// Both are nil for any other tool or when the input has no usable fields.
func DiffCounts(tool string, input map[string]any) (added, removed *int) {
	count := func(m map[string]any, keys ...string) (int, bool) {
		for _, k := range keys {
			if v, ok := m[k].(string); ok {
				return LineCount(v), true
			}
		}
		return 0, false
	}
	var a, r int
	var found bool
	switch strings.ToLower(tool) {
	case "edit":
		n, ok1 := count(input, "new_string", "newString")
		o, ok2 := count(input, "old_string", "oldString")
		a, r, found = n, o, ok1 || ok2
	case "write":
		n, ok := count(input, "content")
		a, found = n, ok
	case "multiedit":
		edits, _ := input["edits"].([]any)
		for _, e := range edits {
			em, _ := e.(map[string]any)
			if em == nil {
				continue
			}
			n, ok1 := count(em, "new_string", "newString")
			o, ok2 := count(em, "old_string", "oldString")
			a += n
			r += o
			found = found || ok1 || ok2
		}
	}
	if !found {
		return nil, nil
	}
	return &a, &r
}

// CapEvents keeps the last maxEvents events and then drops from the front until
// their JSON fits MaxRenderBytes.
func CapEvents(events []Event, maxEvents int) []Event {
	if maxEvents > 0 && len(events) > maxEvents {
		events = events[len(events)-maxEvents:]
	}
	total := 0
	keepFrom := len(events)
	for i := len(events) - 1; i >= 0; i-- {
		b, _ := json.Marshal(events[i])
		total += len(b) + 1
		if total > MaxRenderBytes {
			break
		}
		keepFrom = i
	}
	return events[keepFrom:]
}

// PageEvents is the paging window over a fully parsed event list. With before
// == "" it is the tail; otherwise it is the events strictly older than the one
// with that id. Either way the last maxEvents events that fit MaxRenderBytes are
// kept (so a page holds the events nearest to before), and hasMore reports
// whether anything older than the returned slice remains. An unknown before id
// yields an empty page with hasMore false. The result is never nil.
func PageEvents(events []Event, before string, maxEvents int) (page []Event, hasMore bool) {
	if before != "" {
		idx := -1
		for i := range events {
			if events[i].ID == before {
				idx = i
				break
			}
		}
		if idx < 0 {
			return []Event{}, false
		}
		events = events[:idx]
	}
	page = CapEvents(events, maxEvents)
	if page == nil {
		page = []Event{}
	}
	return page, len(page) < len(events)
}

// DerivePending works out what the human is being waited on for. agentStatus is
// the backend's own report ("blocked", "working", ...) or "" when the backend
// has none.
func DerivePending(events []Event, agentStatus string) *Pending {
	var last *Event
	for n := len(events); n > 0; n-- {
		if !events[n-1].Queued {
			last = &events[n-1]
			break
		}
	}
	if last != nil && last.Kind == KindQuestion && (last.Answered == nil || !*last.Answered) {
		return &Pending{Kind: PendingQuestion, EventID: last.ID}
	}
	if agentStatus != AgentStatusBlocked {
		return nil
	}
	if last != nil && last.Kind == KindTool && last.Status == StatusRunning {
		return &Pending{Kind: PendingApproval, EventID: last.ID, Tool: last.Tool, Arg: last.Arg}
	}
	return &Pending{Kind: PendingUnknown}
}
