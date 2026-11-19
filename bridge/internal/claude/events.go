package claude

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/itsmaleen/merry/bridge/internal/transcriptrender"
)

// eventLine is one JSONL line, with the fields typed events need.
type eventLine struct {
	Type        string `json:"type"`
	UUID        string `json:"uuid"`
	Timestamp   string `json:"timestamp"`
	IsSidechain bool   `json:"isSidechain"`
	IsMeta      bool   `json:"isMeta"`
	// IsCompactSummary marks the harness-written summary that replaces the
	// earlier conversation after a compaction. It is not something the human said.
	IsCompactSummary bool `json:"isCompactSummary"`
	PromptID    string `json:"promptId"`
	ParentUUID  string `json:"parentUuid"`
	// TurnCompanion is present on the injected skill prompt of a command.
	TurnCompanion json.RawMessage `json:"turnCompanion"`
	// ScheduledTaskID is set on lines the harness fired (e.g. /loop repeats).
	ScheduledTaskID string `json:"scheduledTaskId"`
	// queue-operation lines: enqueue / dequeue / remove / popAll.
	Operation string          `json:"operation"`
	Content   json.RawMessage `json:"content"`
	// Attachment carries a queued_command (a message delivered mid-turn).
	Attachment struct {
		Type   string          `json:"type"`
		Prompt json.RawMessage `json:"prompt"`
	} `json:"attachment"`
	Message struct {
		Content json.RawMessage `json:"content"`
	} `json:"message"`
	// ToolUseResult is the structured twin of a tool_result block. Only
	// AskUserQuestion's answers are read from it.
	ToolUseResult json.RawMessage `json:"toolUseResult"`
}

const askUserQuestionTool = "AskUserQuestion"

var rawCommandRe = regexp.MustCompile(`(?s)^(/[A-Za-z][\w:.-]*)(?:\s+(.*))?$`)

var (
	systemReminderRe = regexp.MustCompile(`(?s)<system-reminder>.*?</system-reminder>`)
	commandNameRe    = regexp.MustCompile(`(?s)<command-name>\s*(.*?)\s*</command-name>`)
	commandArgsRe    = regexp.MustCompile(`(?s)<command-args>\s*(.*?)\s*</command-args>`)
)

var ansiRe = regexp.MustCompile("\x1b\\[[0-9;?]*[ -/]*[@-~]|\x1b\\][^\x07\x1b]*(?:\x07|\x1b\\\\)")

// localCommandOutput reports whether a user text block is a local command's
// printed output and returns it cleaned (ANSI stripped, tail-capped).
func localCommandOutput(text string) (out string, isErr, ok bool) {
	t := strings.TrimSpace(text)
	var tag string
	switch {
	case strings.HasPrefix(t, "<local-command-stdout>"):
		tag = "local-command-stdout"
	case strings.HasPrefix(t, "<local-command-stderr>"):
		tag, isErr = "local-command-stderr", true
	default:
		return "", false, false
	}
	t = strings.TrimPrefix(t, "<"+tag+">")
	t = strings.TrimSuffix(t, "</"+tag+">")
	t = ansiRe.ReplaceAllString(t, "")
	return transcriptrender.OutputTail(t), isErr, true
}

// cleanUserText returns the human-written part of a user text block, or "" when
// the block is harness noise: command output, caveats, background-task
// notifications, system reminders. A slash command becomes "/name args".
func cleanUserText(text string) string {
	trimmed := strings.TrimSpace(text)
	for _, prefix := range []string{"<task-notification", "<local-command-stdout", "<local-command-stderr", "<local-command-caveat"} {
		if strings.HasPrefix(trimmed, prefix) {
			return ""
		}
	}
	if m := commandNameRe.FindStringSubmatch(trimmed); m != nil {
		cmd := m[1]
		if a := commandArgsRe.FindStringSubmatch(trimmed); a != nil && a[1] != "" {
			cmd += " " + a[1]
		}
		return strings.TrimSpace(cmd)
	}
	return strings.TrimSpace(systemReminderRe.ReplaceAllString(text, ""))
}

// splitCommand reports whether a user text block is a slash-command wrapper and
// returns the command name (with its slash) and its args (possibly empty).
func splitCommand(text string) (cmd, args string, ok bool) {
	trimmed := strings.TrimSpace(text)
	for _, prefix := range []string{"<task-notification", "<local-command-stdout", "<local-command-stderr", "<local-command-caveat"} {
		if strings.HasPrefix(trimmed, prefix) {
			return "", "", false
		}
	}
	m := commandNameRe.FindStringSubmatch(trimmed)
	if m == nil || m[1] == "" {
		return "", "", false
	}
	if a := commandArgsRe.FindStringSubmatch(trimmed); a != nil {
		args = a[1]
	}
	return m[1], args, true
}

// toolResultText flattens a tool_result's content (string or text blocks).
func toolResultText(raw any) string {
	switch v := raw.(type) {
	case string:
		return v
	case []any:
		var parts []string
		for _, item := range v {
			if m, _ := item.(map[string]any); m != nil {
				if t, _ := m["text"].(string); t != "" {
					parts = append(parts, t)
				}
			}
		}
		return strings.Join(parts, "\n")
	}
	return ""
}

func unixSeconds(ts string) int64 {
	if ts == "" {
		return 0
	}
	t, err := time.Parse(time.RFC3339Nano, ts)
	if err != nil {
		return 0
	}
	return t.Unix()
}

// parseEvents turns raw JSONL (possibly starting mid-line, as a tail read does)
// into typed events, oldest first. A tool call and its result are one event; a
// result whose call is not in data (cut off by the tail) is dropped.
func parseEvents(data []byte) []transcriptrender.Event {
	var events []transcriptrender.Event
	toolIdx := map[string]int{}              // tool_use id -> index into events
	runs := map[string]int{}                 // scheduledTaskId -> fires seen so far
	cmdIdx, cmdPrompt, cmdUUID := -1, "", "" // last command event, its promptId and line uuid
	var queue []queuedMsg                    // enqueued, not yet dequeued/removed, oldest first

	for n, rawLine := range strings.Split(string(data), "\n") {
		rawLine = strings.TrimSpace(rawLine)
		if rawLine == "" {
			continue
		}
		var line eventLine
		if err := json.Unmarshal([]byte(rawLine), &line); err != nil {
			continue
		}
		if line.Type == "queue-operation" {
			queue = applyQueueOp(queue, line)
			continue
		}
		if line.Type == "attachment" && line.Attachment.Type == "queued_command" && !line.IsSidechain {
			// A message delivered mid-turn: a normal user event here. Its text
			// is the attachment's prompt (a string, or text blocks).
			uuid := line.UUID
			if uuid == "" {
				uuid = fmt.Sprintf("line-%d", n)
			}
			for i, b := range contentBlocks(line.Attachment.Prompt) {
				text, _ := b["text"].(string)
				if ev, ok := userEvent(fmt.Sprintf("%s:%d", uuid, i), unixSeconds(line.Timestamp), text); ok {
					if i == 0 {
						ev.ID = uuid
					}
					events = append(events, ev)
				}
			}
			continue
		}
		if (line.Type != "user" && line.Type != "assistant") || line.IsSidechain {
			continue
		}
		uuid := line.UUID
		if uuid == "" {
			uuid = fmt.Sprintf("line-%d", n)
		}
		ts := unixSeconds(line.Timestamp)

		// The compaction summary: a marker, never the human's message.
		if line.Type == "user" && line.IsCompactSummary {
			events = append(events, transcriptrender.Event{ID: uuid, Kind: transcriptrender.KindUser, TS: ts, Compacted: true})
			cmdIdx = -1
			continue
		}

		// A command's injected skill prompt: the next isMeta companion line
		// sharing the command line's promptId. Its text is never sent.
		if line.Type == "user" && line.IsMeta {
			if cmdIdx >= 0 && line.PromptID != "" && line.PromptID == cmdPrompt && len(line.TurnCompanion) > 0 {
				events[cmdIdx].SkillLoaded = true
			}
			continue
		}
		scheduled, run := false, 0
		if line.Type == "user" && line.ScheduledTaskID != "" {
			scheduled = true
		}
		stamp := func(ev *transcriptrender.Event) {
			if !scheduled {
				return
			}
			if run == 0 {
				runs[line.ScheduledTaskID]++
				run = runs[line.ScheduledTaskID]
			}
			ev.Scheduled, ev.Run = true, run
		}

		blocks := contentBlocks(line.Message.Content)
		textBlocks := 0
		for _, b := range blocks {
			if b["type"] == "text" {
				textBlocks++
			}
		}
		textIdx := 0
		nextTextID := func() string {
			id := uuid
			if textBlocks > 1 {
				id = fmt.Sprintf("%s:%d", uuid, textIdx)
			}
			textIdx++
			return id
		}

		for _, b := range blocks {
			switch b["type"] {
			case "text":
				text, _ := b["text"].(string)
				id := nextTextID()
				if line.Type == "user" {
					if out, isErr, ok := localCommandOutput(text); ok {
						// Belongs to the last command event when it shares the
						// promptId, is a child of the command line, or (with
						// neither id present) directly follows it.
						if cmdIdx >= 0 && out != "" && events[cmdIdx].CommandOutput == "" &&
							((line.PromptID != "" && line.PromptID == cmdPrompt) ||
								(line.ParentUUID != "" && line.ParentUUID == cmdUUID) ||
								(line.PromptID == "" && line.ParentUUID == "" && cmdIdx == len(events)-1)) {
							events[cmdIdx].CommandOutput, events[cmdIdx].CommandError = out, isErr
						}
						continue
					}
					if cmd, args, ok := splitCommand(text); ok {
						ev := transcriptrender.Event{ID: id, Kind: transcriptrender.KindUser, TS: ts, Command: cmd, Text: strings.TrimSpace(args)}
						stamp(&ev)
						cmdIdx, cmdPrompt, cmdUUID = len(events), line.PromptID, line.UUID
						events = append(events, ev)
						continue
					}
					text = cleanUserText(text)
					if text == "" {
						continue
					}
					ev := transcriptrender.Event{ID: id, Kind: transcriptrender.KindUser, TS: ts, Text: text}
					stamp(&ev)
					events = append(events, ev)
					continue
				}
				if strings.TrimSpace(text) == "" {
					continue
				}
				events = append(events, transcriptrender.Event{ID: id, Kind: transcriptrender.KindText, TS: ts, Text: text})

			case "tool_use":
				if line.Type != "assistant" {
					continue
				}
				id, _ := b["id"].(string)
				name, _ := b["name"].(string)
				if id == "" || name == "" {
					continue
				}
				input, _ := b["input"].(map[string]any)
				ev := transcriptrender.Event{ID: id, TS: ts}
				if name == askUserQuestionTool {
					unanswered := false
					ev.Kind = transcriptrender.KindQuestion
					ev.Questions = transcriptrender.ParseQuestions(input)
					ev.Answered = &unanswered
				} else {
					ev.Kind = transcriptrender.KindTool
					ev.Tool = name
					ev.Arg = transcriptrender.ToolArg(input, transcriptrender.MaxEventArgRunes)
					ev.Status = transcriptrender.StatusRunning
					ev.Added, ev.Removed = transcriptrender.DiffCounts(name, input)
				}
				toolIdx[id] = len(events)
				events = append(events, ev)

			case "tool_result":
				if line.Type != "user" {
					continue
				}
				id, _ := b["tool_use_id"].(string)
				i, ok := toolIdx[id]
				if !ok {
					continue // call fell outside the tail window
				}
				isErr, _ := b["is_error"].(bool)
				content := toolResultText(b["content"])
				ev := &events[i]
				if ev.Kind == transcriptrender.KindQuestion {
					answered := true
					ev.Answered = &answered
					ev.Answer = questionAnswer(ev.Questions, line.ToolUseResult, content, isErr)
					continue
				}
				if isErr {
					ev.Status = transcriptrender.StatusError
					ev.Output = transcriptrender.OutputTail(content)
				} else {
					ev.Status = transcriptrender.StatusOK
				}
			}
		}
	}
	// Still-queued messages trail everything, in enqueue order.
	for _, q := range queue {
		if ev, ok := userEvent("q:"+q.rawTS, q.ts, q.text); ok {
			ev.Queued = true
			events = append(events, ev)
		}
	}
	return events
}

// queuedMsg is one enqueued message not yet delivered.
type queuedMsg struct {
	rawTS string
	ts    int64
	text  string
}

// applyQueueOp applies one queue-operation line to the pending queue.
// Observed in real transcripts: enqueue pushes {content}; dequeue and remove
// without content pop the oldest (FIFO); remove with content (reason
// "absorbed_mid_turn") drops that message; popAll (the human pulled the queue
// back into the input box) clears everything. Delivery itself shows up as a
// user line (after dequeue) or a queued_command attachment (after remove).
func applyQueueOp(queue []queuedMsg, line eventLine) []queuedMsg {
	var content string
	_ = json.Unmarshal(line.Content, &content)
	switch line.Operation {
	case "enqueue":
		return append(queue, queuedMsg{rawTS: line.Timestamp, ts: unixSeconds(line.Timestamp), text: content})
	case "popAll":
		return nil
	case "dequeue", "remove":
		if len(queue) == 0 {
			return queue // its enqueue fell outside the tail window
		}
		if content != "" {
			for i := range queue {
				if queue[i].text == content {
					return append(queue[:i:i], queue[i+1:]...)
				}
			}
			return queue
		}
		return queue[1:]
	}
	return queue
}

// userEvent builds a user event from raw human text, applying the same noise
// filter and slash-command handling as user lines. ok is false for noise.
func userEvent(id string, ts int64, text string) (transcriptrender.Event, bool) {
	if cmd, args, ok := splitCommand(text); ok {
		return transcriptrender.Event{ID: id, Kind: transcriptrender.KindUser, TS: ts, Command: cmd, Text: strings.TrimSpace(args)}, true
	}
	text = cleanUserText(text)
	if text == "" {
		return transcriptrender.Event{}, false
	}
	// A message typed as "/cmd args" (queued text is raw, not command-tagged).
	if m := rawCommandRe.FindStringSubmatch(text); m != nil {
		return transcriptrender.Event{ID: id, Kind: transcriptrender.KindUser, TS: ts, Command: m[1], Text: strings.TrimSpace(m[2])}, true
	}
	return transcriptrender.Event{ID: id, Kind: transcriptrender.KindUser, TS: ts, Text: text}, true
}

// contentBlocks normalizes message.content (a plain string or a block array)
// into blocks.
func contentBlocks(raw json.RawMessage) []map[string]any {
	if len(raw) == 0 {
		return nil
	}
	var s string
	if err := json.Unmarshal(raw, &s); err == nil {
		return []map[string]any{{"type": "text", "text": s}}
	}
	var blocks []map[string]any
	if err := json.Unmarshal(raw, &blocks); err != nil {
		return nil
	}
	return blocks
}

// questionAnswer extracts what the human chose. Claude Code records it in the
// line's toolUseResult.answers ({question text: answer}); failing that the
// tool_result text is used. A tool error (the human dismissed the dialog)
// reads "(declined)".
func questionAnswer(questions []transcriptrender.Question, toolUseResult json.RawMessage, content string, isErr bool) string {
	var structured struct {
		Answers map[string]string `json:"answers"`
	}
	if len(toolUseResult) > 0 {
		_ = json.Unmarshal(toolUseResult, &structured)
	}
	if len(structured.Answers) > 0 {
		var parts []string
		for _, q := range questions {
			a, ok := structured.Answers[q.Question]
			if !ok {
				continue
			}
			if len(questions) > 1 {
				label := q.Header
				if label == "" {
					label = q.Question
				}
				a = label + ": " + a
			}
			parts = append(parts, a)
		}
		if len(parts) > 0 {
			return strings.Join(parts, "\n")
		}
	}
	if isErr {
		return "(declined)"
	}
	return strings.TrimSpace(content)
}

// renderEvents is the events-format counterpart of renderJSONL.
// before pages: see transcriptrender.PageEvents. Numbering and tool/result
// joining happen in parseEvents, over everything read, before any cut.
func renderEvents(data []byte, maxMessages int, before string) ([]transcriptrender.Event, bool) {
	events := parseEvents(data)
	if before != "" {
		// Queued messages belong to the tail reply only.
		for len(events) > 0 && events[len(events)-1].Queued {
			events = events[:len(events)-1]
		}
	}
	return transcriptrender.PageEvents(events, before, maxMessages)
}
