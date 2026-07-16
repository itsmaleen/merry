package claude

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// cacheEntry holds an already-rendered transcript with its file identity.
type cacheEntry struct {
	modTime time.Time
	size    int64
	text    string
}

// Resolver locates and renders Claude session transcripts.
type Resolver struct {
	home  string
	cache sync.Map // keyed by absolute path → *cacheEntry
}

// NewResolver creates a Resolver that resolves $HOME via os.UserHomeDir.
func NewResolver() *Resolver {
	home, _ := os.UserHomeDir()
	return &Resolver{home: home}
}

// Render returns the rendered transcript for a surface's resume_binding.
//
// supported reports whether the binding describes a Claude surface at all.
// If supported is true but text is empty (""), no transcript file was found yet.
// sessionID is the base filename (without .jsonl) of the active transcript.
func (r *Resolver) Render(resumeBinding map[string]any, maxMessages int) (text string, supported bool, sessionID string, err error) {
	if resumeBinding == nil {
		return "", false, "", nil
	}
	kind, _ := resumeBinding["kind"].(string)
	if kind != "claude" {
		return "", false, "", nil
	}

	transcriptPath, err := r.resolveTranscriptPath(resumeBinding)
	if err != nil {
		return "", true, "", err
	}
	if transcriptPath == "" {
		// Claude surface but no transcript file found yet.
		return "", true, "", nil
	}

	sessionID = strings.TrimSuffix(filepath.Base(transcriptPath), ".jsonl")

	info, err := os.Stat(transcriptPath)
	if err != nil {
		return "", true, sessionID, err
	}

	// Check cache.
	if v, ok := r.cache.Load(transcriptPath); ok {
		entry := v.(*cacheEntry)
		if entry.modTime.Equal(info.ModTime()) && entry.size == info.Size() {
			return entry.text, true, sessionID, nil
		}
	}

	data, err := os.ReadFile(transcriptPath)
	if err != nil {
		return "", true, sessionID, err
	}

	rendered := renderJSONL(data, maxMessages)
	r.cache.Store(transcriptPath, &cacheEntry{
		modTime: info.ModTime(),
		size:    info.Size(),
		text:    rendered,
	})
	return rendered, true, sessionID, nil
}

// resolveTranscriptPath returns the transcript .jsonl file for the surface's
// resume_binding, or "" if none is found.
//
// checkpoint_id names the surface's SPECIFIC session and is the authoritative
// mapping — many surfaces share one cwd (e.g. cmux worktrees), so "newest file
// in the project dir" would collapse them all onto the same transcript. cmux's
// agent hook keeps checkpoint_id pointed at each surface's live session, so the
// <checkpoint_id>.jsonl file is used directly. The cwd encoding is only a
// best-effort fallback when no checkpoint_id is present.
func (r *Resolver) resolveTranscriptPath(rb map[string]any) (string, error) {
	projectsDir := filepath.Join(r.home, ".claude", "projects")

	// Strategy 1: the checkpoint_id names the surface's exact session file.
	if checkpointID, _ := rb["checkpoint_id"].(string); checkpointID != "" {
		pattern := filepath.Join(projectsDir, "*", checkpointID+".jsonl")
		matches, err := filepath.Glob(pattern)
		if err != nil {
			return "", err
		}
		if len(matches) > 0 {
			return matches[0], nil
		}
	}

	// Strategy 2 (fallback): no checkpoint_id — encode the cwd and take the
	// most-recently-modified session in that project dir.
	if cwd, _ := rb["cwd"].(string); cwd != "" {
		dir := filepath.Join(projectsDir, encodeCWD(cwd))
		if _, err := os.Stat(dir); err == nil {
			return latestJSONL(dir)
		}
	}

	return "", nil
}

// encodeCWD converts an absolute cwd path to the Claude project directory name.
// e.g. "/Users/marlin/wrinkles" → "-Users-marlin-wrinkles"
func encodeCWD(cwd string) string {
	stripped := strings.TrimPrefix(cwd, "/")
	replacer := strings.NewReplacer("/", "-", ".", "-", "_", "-")
	return "-" + replacer.Replace(stripped)
}

// latestJSONL returns the most-recently-modified *.jsonl file in dir, or "".
func latestJSONL(dir string) (string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return "", err
	}

	var bestPath string
	var bestMod time.Time

	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".jsonl") {
			continue
		}
		full := filepath.Join(dir, e.Name())
		info, err := e.Info()
		if err != nil {
			continue
		}
		if bestPath == "" || info.ModTime().After(bestMod) {
			bestPath = full
			bestMod = info.ModTime()
		}
	}
	return bestPath, nil
}

// ---- Pure rendering helpers (exported for tests) ----------------------------

// jsonlLine is the top-level structure of each JSONL event line.
type jsonlLine struct {
	Type    string `json:"type"`
	Message struct {
		Role    string          `json:"role"`
		Content json.RawMessage `json:"content"`
	} `json:"message"`
}

// renderJSONL parses raw JSONL data and returns the rendered transcript.
// Only the last maxMessages user/assistant messages are included.
func renderJSONL(data []byte, maxMessages int) string {
	type msg struct {
		role string
		text string
	}

	var messages []msg
	for _, rawLine := range strings.Split(string(data), "\n") {
		rawLine = strings.TrimSpace(rawLine)
		if rawLine == "" {
			continue
		}
		var line jsonlLine
		if err := json.Unmarshal([]byte(rawLine), &line); err != nil {
			continue
		}
		if line.Type != "user" && line.Type != "assistant" {
			continue
		}
		text := extractContent(line.Message.Content)
		if strings.TrimSpace(text) == "" {
			continue
		}
		messages = append(messages, msg{role: line.Message.Role, text: text})
	}

	// Keep only the last maxMessages.
	if maxMessages > 0 && len(messages) > maxMessages {
		messages = messages[len(messages)-maxMessages:]
	}

	var sb strings.Builder
	for i, m := range messages {
		var header string
		if m.role == "user" {
			header = "› You"
		} else {
			header = "⏺ Claude"
		}
		if i > 0 {
			sb.WriteByte('\n')
		}
		sb.WriteString(header)
		sb.WriteByte('\n')
		sb.WriteString(m.text)
		sb.WriteByte('\n')
	}
	return sb.String()
}

// extractContent converts a raw JSON content field (string or block array)
// into plain text.
func extractContent(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}

	// Try string first.
	var s string
	if err := json.Unmarshal(raw, &s); err == nil {
		return s
	}

	// Try array of blocks.
	var blocks []map[string]any
	if err := json.Unmarshal(raw, &blocks); err != nil {
		return ""
	}

	var parts []string
	for _, block := range blocks {
		blockType, _ := block["type"].(string)
		switch blockType {
		case "text":
			if t, _ := block["text"].(string); t != "" {
				parts = append(parts, t)
			}
		case "tool_use":
			if name, _ := block["name"].(string); name != "" {
				parts = append(parts, "⚙ "+name)
			}
		// thinking, tool_result, and anything else: skip
		}
	}
	return strings.Join(parts, "\n")
}
