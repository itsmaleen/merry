package opencode

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/itsmaleen/merry/bridge/internal/transcriptrender"
)

// EventsFingerprint is the events-format twin of Fingerprint: the same session
// state, salted so it never equals a text fingerprint, plus the backend's agent
// status so a flip to "blocked" is not answered "unchanged".
func EventsFingerprint(base, agentStatus string) string {
	return base + "-events-" + agentStatus
}

// maxToolOutputChars bounds how much of a tool's output is pulled per part; only
// the tail is ever shown.
const maxToolOutputChars = 2000

// RenderEvents renders a session's conversation as typed events, oldest first.
// Tool parts map straight onto tool events: state.status gives running / ok /
// error and state.output (or state.error) the result tail. opencode's `question`
// tool becomes a question event.
func (s *Store) RenderEvents(sessionID string, maxMessages int) ([]transcriptrender.Event, error) {
	if !sessionIDPattern.MatchString(sessionID) {
		return nil, errors.New("invalid session id")
	}
	if maxMessages <= 0 {
		maxMessages = 200
	}
	// A message holds several events, so the message window is a generous bound
	// and the exact cap is applied to events afterwards.
	msgRows, err := s.query(
		"select id, json_extract(data,'$.role') as role from message" +
			" where session_id = " + textLiteral(sessionID) +
			" order by time_created desc limit " + fmt.Sprint(maxMessages),
	)
	if err != nil {
		return nil, err
	}
	if len(msgRows) == 0 {
		return []transcriptrender.Event{}, nil
	}
	isUser := make(map[string]bool, len(msgRows))
	ids := make([]string, 0, len(msgRows))
	for _, row := range msgRows {
		id := stringField(row, "id")
		if id == "" {
			continue
		}
		isUser[id] = stringField(row, "role") == "user"
		ids = append(ids, textLiteral(id))
	}
	partRows, err := s.query(
		"select p.id as id, p.message_id as message_id, p.time_created as created," +
			" json_extract(p.data,'$.type') as type," +
			" substr(coalesce(json_extract(p.data,'$.text'),''),1," + fmt.Sprint(maxPartTextBytes) + ") as text," +
			" json_extract(p.data,'$.tool') as tool," +
			" json_extract(p.data,'$.callID') as call_id," +
			" json_extract(p.data,'$.state.status') as status," +
			" substr(coalesce(json_extract(p.data,'$.state.input'),''),1," + fmt.Sprint(maxToolInputBytes) + ") as input," +
			" substr(coalesce(json_extract(p.data,'$.state.output'),json_extract(p.data,'$.state.error'),''),-" + fmt.Sprint(maxToolOutputChars) + ") as output," +
			" coalesce(json_extract(p.data,'$.state.metadata'),'') as metadata" +
			" from part p" +
			" where p.message_id in (" + strings.Join(ids, ",") + ")" +
			" and json_extract(p.data,'$.type') in ('text','tool')" +
			" order by p.time_created asc, p.id asc",
	)
	if err != nil {
		return nil, err
	}

	events := make([]transcriptrender.Event, 0, len(partRows))
	for _, row := range partRows {
		ts := intField(row, "created") / 1000
		partID := stringField(row, "id")
		switch stringField(row, "type") {
		case "text":
			text := strings.TrimRight(stringField(row, "text"), "\n")
			if strings.TrimSpace(text) == "" {
				continue
			}
			kind := transcriptrender.KindText
			if isUser[stringField(row, "message_id")] {
				kind = transcriptrender.KindUser
			}
			events = append(events, transcriptrender.Event{ID: partID, Kind: kind, TS: ts, Text: text})
		case "tool":
			if ev, ok := toolEvent(row, partID, ts); ok {
				events = append(events, ev)
			}
		}
	}
	return transcriptrender.CapEvents(events, maxMessages), nil
}

func toolEvent(row map[string]any, partID string, ts int64) (transcriptrender.Event, bool) {
	name := stringField(row, "tool")
	if name == "" {
		return transcriptrender.Event{}, false
	}
	id := stringField(row, "call_id")
	if id == "" {
		id = partID
	}
	var input map[string]any
	if raw := stringField(row, "input"); raw != "" {
		_ = json.Unmarshal([]byte(raw), &input) // truncated JSON: no args, fine
	}
	status := stringField(row, "status")

	if name == "question" {
		answered := status == "completed" || status == "error"
		ev := transcriptrender.Event{
			ID: id, Kind: transcriptrender.KindQuestion, TS: ts,
			Questions: transcriptrender.ParseQuestions(input), Answered: &answered,
		}
		if status == "error" {
			ev.Answer = "(declined)"
		} else if answered {
			ev.Answer = questionAnswer(ev.Questions, stringField(row, "metadata"), stringField(row, "output"))
		}
		return ev, true
	}

	ev := transcriptrender.Event{
		ID: id, Kind: transcriptrender.KindTool, TS: ts, Tool: name,
		Arg: transcriptrender.ToolArg(input, transcriptrender.MaxEventArgRunes),
	}
	ev.Added, ev.Removed = transcriptrender.DiffCounts(name, input)
	switch status {
	case "completed":
		ev.Status = transcriptrender.StatusOK
	case "error":
		ev.Status = transcriptrender.StatusError
		ev.Output = transcriptrender.OutputTail(stringField(row, "output"))
	default: // pending, running, anything new
		ev.Status = transcriptrender.StatusRunning
	}
	return ev, true
}

// questionAnswer reads state.metadata.answers ([[label, ...] per question).
func questionAnswer(questions []transcriptrender.Question, metadata, output string) string {
	var meta struct {
		Answers [][]string `json:"answers"`
	}
	_ = json.Unmarshal([]byte(metadata), &meta)
	var parts []string
	for i, a := range meta.Answers {
		text := strings.Join(a, ", ")
		if len(meta.Answers) > 1 && i < len(questions) {
			label := questions[i].Header
			if label == "" {
				label = questions[i].Question
			}
			text = label + ": " + text
		}
		parts = append(parts, text)
	}
	if len(parts) > 0 {
		return strings.Join(parts, "\n")
	}
	return strings.TrimSpace(output)
}
