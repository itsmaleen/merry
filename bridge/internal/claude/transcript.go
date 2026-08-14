package claude

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

// sessionIDPattern matches a Claude session UUID. checkpoint_id comes from
// cmux's surface metadata and is interpolated into a filesystem glob, so it is
// validated to this shape first — otherwise `../` or glob metacharacters
// (`*`, `?`, `[`) could escape ~/.claude/projects or match unintended files.
var sessionIDPattern = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

// maxTranscriptFileBytes bounds how much of a transcript file is read into
// memory. Claude session files grow forward, so for a larger file only the
// tail (most recent conversation) is read.
const maxTranscriptFileBytes = 32 * 1024 * 1024

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

// Result is the outcome of resolving and rendering a surface's transcript.
type Result struct {
	// Supported reports whether the binding describes a Claude surface at all.
	Supported bool
	// SessionID is the session the transcript was read from, or — when the
	// bound session's file is gone — the session the surface points at.
	SessionID string
	// Text is the rendered transcript, empty when no file was found.
	Text string
	// SessionMissing reports that the surface names a specific session whose
	// transcript file is not on disk. Distinguishes "this conversation's file
	// is gone" from "this surface hasn't said anything yet", which otherwise
	// look identical (both empty Text) to the client.
	SessionMissing bool
}

// Render returns the rendered transcript for a surface's resume_binding.
func (r *Resolver) Render(resumeBinding map[string]any, maxMessages int) (Result, error) {
	if resumeBinding == nil {
		return Result{}, nil
	}
	kind, _ := resumeBinding["kind"].(string)
	if kind != "claude" {
		return Result{}, nil
	}

	res := Result{Supported: true}

	transcriptPath, boundSession, err := r.resolveTranscriptPath(resumeBinding)
	if err != nil {
		res.SessionID = boundSession
		return res, err
	}
	if transcriptPath == "" {
		// Claude surface, but nothing to read: either the surface has no
		// session yet, or it names one whose file has since disappeared.
		res.SessionID = boundSession
		res.SessionMissing = boundSession != ""
		return res, nil
	}

	res.SessionID = strings.TrimSuffix(filepath.Base(transcriptPath), ".jsonl")

	info, err := os.Stat(transcriptPath)
	if err != nil {
		return res, err
	}

	// Check cache.
	if v, ok := r.cache.Load(transcriptPath); ok {
		entry := v.(*cacheEntry)
		if entry.modTime.Equal(info.ModTime()) && entry.size == info.Size() {
			res.Text = entry.text
			return res, nil
		}
	}

	data, err := readTail(transcriptPath, info.Size(), maxTranscriptFileBytes)
	if err != nil {
		return res, err
	}

	rendered := renderJSONL(data, maxMessages)
	r.cache.Store(transcriptPath, &cacheEntry{
		modTime: info.ModTime(),
		size:    info.Size(),
		text:    rendered,
	})
	res.Text = rendered
	return res, nil
}

// resolveTranscriptPath returns the transcript .jsonl file for the surface's
// resume_binding, or "" if none is found. boundSession is the well-formed
// session id the surface is bound to, whether or not its file exists.
//
// checkpoint_id names the surface's SPECIFIC session and is the authoritative
// mapping — many surfaces share one cwd (e.g. cmux worktrees), so "newest file
// in the project dir" would collapse them all onto the same transcript. cmux's
// agent hook keeps checkpoint_id pointed at each surface's live session, so the
// <checkpoint_id>.jsonl file is used directly. The cwd encoding is only a
// best-effort fallback for a surface that names no session at all.
func (r *Resolver) resolveTranscriptPath(rb map[string]any) (path string, boundSession string, err error) {
	projectsDir := filepath.Join(r.home, ".claude", "projects")

	// Strategy 1: the checkpoint_id names the surface's exact session file.
	if checkpointID, _ := rb["checkpoint_id"].(string); checkpointID != "" {
		// Only accept a well-formed session UUID — it's interpolated into a
		// glob, so `../` or `*?[` in a malformed value must never reach the
		// filesystem.
		if sessionIDPattern.MatchString(checkpointID) {
			boundSession = checkpointID
			pattern := filepath.Join(projectsDir, "*", checkpointID+".jsonl")
			matches, err := filepath.Glob(pattern)
			if err != nil {
				return "", boundSession, err
			}
			// Defense in depth: the match must resolve inside projectsDir.
			if len(matches) > 0 && isWithin(projectsDir, matches[0]) {
				return matches[0], boundSession, nil
			}
		}
		// The surface names a session and that file is not on disk. Stop here
		// rather than falling through to the cwd heuristic below: sessions can
		// outlive their files (cmux keeps a checkpoint_id pointed at a session
		// that was never written, or was since removed), and with many surfaces
		// sharing one cwd the fallback confidently returns a DIFFERENT
		// surface's conversation. An empty history beats someone else's.
		return "", boundSession, nil
	}

	// Strategy 2 (fallback): no checkpoint_id — encode the cwd and take the
	// most-recently-modified session in that project dir.
	if cwd, _ := rb["cwd"].(string); cwd != "" {
		dir := filepath.Join(projectsDir, encodeCWD(cwd))
		if _, err := os.Stat(dir); err == nil {
			path, err := latestJSONL(dir)
			return path, "", err
		}
	}

	return "", "", nil
}

// readTail reads at most maxBytes from the end of the file at path. Claude
// session files grow forward, so the tail is the most recent conversation and
// this bounds memory for very large sessions. A partial first line (from
// cutting mid-line) is harmless — renderJSONL skips unparseable lines.
func readTail(path string, size, maxBytes int64) ([]byte, error) {
	if size <= maxBytes {
		return os.ReadFile(path)
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	buf := make([]byte, maxBytes)
	n, err := f.ReadAt(buf, size-maxBytes)
	if err != nil && n == 0 {
		return nil, err
	}
	return buf[:n], nil
}

// isWithin reports whether path is inside dir (or equal to it).
func isWithin(dir, path string) bool {
	rel, err := filepath.Rel(dir, filepath.Clean(path))
	if err != nil {
		return false
	}
	return rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
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

// maxRenderBytes bounds the rendered transcript so a long session can't produce
// a payload that blows past WebSocket message-size limits or bogs the client's
// text view. The tail (most recent conversation) is kept.
const maxRenderBytes = 128 * 1024

// capTail trims s to at most maxRenderBytes, keeping the end and starting at a
// line boundary so a message isn't cut mid-line.
func capTail(s string) string {
	if len(s) <= maxRenderBytes {
		return s
	}
	s = s[len(s)-maxRenderBytes:]
	if i := strings.IndexByte(s, '\n'); i >= 0 && i+1 < len(s) {
		s = s[i+1:]
	}
	return s
}

// renderJSONL parses raw JSONL data and returns the rendered transcript.
// Only the last maxMessages user/assistant messages are included, and the
// result is byte-capped to the most recent maxRenderBytes.
func renderJSONL(data []byte, maxMessages int) string {
	type msg struct {
		isUser bool
		text   string
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
		// Header comes from the validated line.Type, not message.role, which
		// can be absent/unexpected on some events.
		messages = append(messages, msg{isUser: line.Type == "user", text: text})
	}

	// Keep only the last maxMessages.
	if maxMessages > 0 && len(messages) > maxMessages {
		messages = messages[len(messages)-maxMessages:]
	}

	var sb strings.Builder
	for i, m := range messages {
		header := "⏺ Claude"
		if m.isUser {
			header = "› You"
		}
		if i > 0 {
			sb.WriteByte('\n')
		}
		sb.WriteString(header)
		sb.WriteByte('\n')
		sb.WriteString(m.text)
		sb.WriteByte('\n')
	}
	return capTail(sb.String())
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
