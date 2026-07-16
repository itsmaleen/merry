package claude

import (
	"encoding/json"
	"strings"
	"testing"
)

// ---- extractContent tests ---------------------------------------------------

func TestExtractContentString(t *testing.T) {
	raw := json.RawMessage(`"hello world"`)
	got := extractContent(raw)
	if got != "hello world" {
		t.Fatalf("got %q, want %q", got, "hello world")
	}
}

func TestExtractContentArray(t *testing.T) {
	raw := json.RawMessage(`[
		{"type":"text","text":"Here is the answer"},
		{"type":"tool_use","name":"Bash"},
		{"type":"thinking","thinking":"internal reasoning"},
		{"type":"tool_result","content":"output"}
	]`)
	got := extractContent(raw)
	want := "Here is the answer\n⚙ Bash"
	if got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestExtractContentArrayOnlyThinking(t *testing.T) {
	raw := json.RawMessage(`[{"type":"thinking","thinking":"skip me"}]`)
	got := extractContent(raw)
	if got != "" {
		t.Fatalf("got %q, want empty string", got)
	}
}

func TestExtractContentEmpty(t *testing.T) {
	if got := extractContent(nil); got != "" {
		t.Fatalf("got %q, want empty", got)
	}
	if got := extractContent(json.RawMessage("")); got != "" {
		t.Fatalf("got %q, want empty", got)
	}
}

func TestExtractContentUnknownBlock(t *testing.T) {
	raw := json.RawMessage(`[{"type":"mystery","data":"ignored"}]`)
	got := extractContent(raw)
	if got != "" {
		t.Fatalf("got %q, want empty string for unknown block type", got)
	}
}

// ---- renderJSONL tests ------------------------------------------------------

// buildJSONL creates JSONL bytes from lines for test convenience.
func buildJSONL(lines []string) []byte {
	return []byte(strings.Join(lines, "\n"))
}

// A snapshot of synthetic events representing a short conversation.
var syntheticLines = []string{
	// non-message line: should be skipped
	`{"type":"system","message":{"role":"system","content":"You are helpful."}}`,
	// user message with string content
	`{"type":"user","message":{"role":"user","content":"What is 2+2?"}}`,
	// assistant message with array content (text + tool_use + thinking skipped)
	`{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"let me think"},{"type":"text","text":"The answer is 4."},{"type":"tool_use","name":"Calculator"}]}}`,
	// another user message
	`{"type":"user","message":{"role":"user","content":"Thanks!"}}`,
	// empty line should be skipped silently
	``,
}

func TestRenderJSONLBasic(t *testing.T) {
	data := buildJSONL(syntheticLines)
	got := renderJSONL(data, 200)

	// Should have 3 messages: user, assistant, user
	// Check headers appear in order
	if !strings.Contains(got, "› You") {
		t.Error("missing '› You' header")
	}
	if !strings.Contains(got, "⏺ Claude") {
		t.Error("missing '⏺ Claude' header")
	}

	// Check content
	if !strings.Contains(got, "What is 2+2?") {
		t.Error("missing first user message")
	}
	if !strings.Contains(got, "The answer is 4.") {
		t.Error("missing assistant text block")
	}
	if !strings.Contains(got, "⚙ Calculator") {
		t.Error("missing tool_use rendered as ⚙")
	}
	if !strings.Contains(got, "Thanks!") {
		t.Error("missing second user message")
	}

	// thinking block must be absent
	if strings.Contains(got, "let me think") {
		t.Error("thinking block leaked into output")
	}

	// system line must be absent
	if strings.Contains(got, "You are helpful") {
		t.Error("system line leaked into output")
	}
}

func TestRenderJSONLOrdering(t *testing.T) {
	data := buildJSONL(syntheticLines)
	got := renderJSONL(data, 200)

	userIdx := strings.Index(got, "What is 2+2?")
	assistantIdx := strings.Index(got, "The answer is 4.")
	thanks := strings.Index(got, "Thanks!")

	if userIdx < 0 || assistantIdx < 0 || thanks < 0 {
		t.Fatal("one or more expected messages missing from output")
	}
	if !(userIdx < assistantIdx && assistantIdx < thanks) {
		t.Errorf("messages out of order: user=%d assistant=%d thanks=%d", userIdx, assistantIdx, thanks)
	}
}

func TestRenderJSONLMaxMessages(t *testing.T) {
	// 3 real messages in syntheticLines (user, assistant, user).
	// maxMessages=1 should keep only the last one ("Thanks!").
	data := buildJSONL(syntheticLines)
	got := renderJSONL(data, 1)

	if strings.Contains(got, "What is 2+2?") {
		t.Error("first user message should have been truncated")
	}
	if strings.Contains(got, "The answer is 4.") {
		t.Error("assistant message should have been truncated")
	}
	if !strings.Contains(got, "Thanks!") {
		t.Error("last message should be present")
	}
}

func TestRenderJSONLMaxMessagesTwo(t *testing.T) {
	data := buildJSONL(syntheticLines)
	got := renderJSONL(data, 2)

	// Should keep last 2: assistant + user("Thanks!")
	if strings.Contains(got, "What is 2+2?") {
		t.Error("oldest message should be dropped with maxMessages=2")
	}
	if !strings.Contains(got, "The answer is 4.") {
		t.Error("second-to-last message (assistant) should be present")
	}
	if !strings.Contains(got, "Thanks!") {
		t.Error("last message should be present")
	}
}

func TestRenderJSONLHeaders(t *testing.T) {
	lines := []string{
		`{"type":"user","message":{"role":"user","content":"Hi"}}`,
		`{"type":"assistant","message":{"role":"assistant","content":"Hello"}}`,
	}
	got := renderJSONL(buildJSONL(lines), 200)

	// First header should be › You
	firstHeader := strings.Index(got, "› You")
	claudeHeader := strings.Index(got, "⏺ Claude")
	if firstHeader < 0 {
		t.Fatal("'› You' not found")
	}
	if claudeHeader < 0 {
		t.Fatal("'⏺ Claude' not found")
	}
	if firstHeader > claudeHeader {
		t.Error("user header should come before assistant header")
	}
}

func TestRenderJSONLSkipsEmptyContent(t *testing.T) {
	lines := []string{
		// message with only whitespace text — should be skipped
		`{"type":"user","message":{"role":"user","content":"   "}}`,
		`{"type":"user","message":{"role":"user","content":"Real message"}}`,
	}
	got := renderJSONL(buildJSONL(lines), 200)

	// Only one › You header for the real message
	count := strings.Count(got, "› You")
	if count != 1 {
		t.Errorf("expected 1 user header, got %d", count)
	}
}

func TestRenderJSONLInvalidLinesSkipped(t *testing.T) {
	lines := []string{
		`not valid json {{{`,
		`{"type":"user","message":{"role":"user","content":"Valid"}}`,
	}
	got := renderJSONL(buildJSONL(lines), 200)
	if !strings.Contains(got, "Valid") {
		t.Error("valid line after invalid JSON should still appear")
	}
}

// ---- encodeCWD tests --------------------------------------------------------

func TestEncodeCWD(t *testing.T) {
	cases := []struct {
		cwd  string
		want string
	}{
		{"/Users/marlin/wrinkles", "-Users-marlin-wrinkles"},
		{"/Users/marlin/my.project", "-Users-marlin-my-project"},
		{"/Users/marlin/my_project", "-Users-marlin-my-project"},
	}
	for _, tc := range cases {
		got := encodeCWD(tc.cwd)
		if got != tc.want {
			t.Errorf("encodeCWD(%q) = %q, want %q", tc.cwd, got, tc.want)
		}
	}
}

func TestCapTail(t *testing.T) {
	// Under the cap: unchanged.
	if got := capTail("hello"); got != "hello" {
		t.Fatalf("small input changed: %q", got)
	}
	// Over the cap: trimmed to <= maxRenderBytes, ends preserved, starts at a line boundary.
	var b strings.Builder
	for i := 0; i < 20000; i++ {
		b.WriteString("line ")
		b.WriteString(strings.Repeat("x", 10))
		b.WriteByte('\n')
	}
	big := b.String() + "FINAL-TAIL-LINE\n"
	got := capTail(big)
	if len(got) > maxRenderBytes {
		t.Fatalf("capTail returned %d bytes, want <= %d", len(got), maxRenderBytes)
	}
	if !strings.HasSuffix(got, "FINAL-TAIL-LINE\n") {
		t.Fatal("capTail dropped the most-recent content")
	}
	if strings.HasPrefix(got, "ine ") || got[0] == 'x' {
		t.Fatalf("capTail did not start at a line boundary: %q", got[:20])
	}
}
