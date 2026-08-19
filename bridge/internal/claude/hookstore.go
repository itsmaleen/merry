package claude

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// hookStoreFileName is the per-session record cmux's `cmux hooks claude <event>`
// CLI maintains under ~/.cmuxterm/.
const hookStoreFileName = "claude-hook-sessions.json"

// maxHookStoreBytes bounds how much of the store is parsed. It holds one small
// record per session; anything this large is corrupt, not a real store.
const maxHookStoreBytes = 8 * 1024 * 1024

// hookSessionRecord is the subset of a store record this bridge needs.
//
// transcriptPath is the authoritative field: Claude Code hands every hook its
// own `transcript_path`, and cmux writes it through verbatim. Deriving the path
// instead (encode the cwd, glob for <session>.jsonl) guesses at a layout that
// does not always hold — a session under a non-default CLAUDE_CONFIG_DIR, or a
// workflow session whose file sits in a nested directory, is simply not where
// the glob looks.
type hookSessionRecord struct {
	SessionID      string  `json:"sessionId"`
	SurfaceID      string  `json:"surfaceId"`
	CWD            string  `json:"cwd"`
	TranscriptPath string  `json:"transcriptPath"`
	PID            int     `json:"pid"`
	UpdatedAt      float64 `json:"updatedAt"`
}

type hookActiveSession struct {
	SessionID string `json:"sessionId"`
}

type hookStoreFile struct {
	// The session each surface is CURRENTLY running, maintained by the hook
	// lifecycle. This is the freshest surface → session binding available.
	ActiveSessionsBySurface map[string]hookActiveSession `json:"activeSessionsBySurface"`
	// Every remembered session, keyed by session id.
	Sessions map[string]hookSessionRecord `json:"sessions"`
}

// hookStore reads the cmux hook session store, caching the parsed file until it
// changes on disk. The store is rewritten on every hook event (many per second
// during a tool storm), so re-parsing it per request would be wasteful; a
// stat-guarded cache keeps a poll cheap.
type hookStore struct {
	path string

	mu      sync.Mutex
	modTime time.Time
	size    int64
	parsed  *hookStoreFile
}

func newHookStore(home string) *hookStore {
	return &hookStore{path: filepath.Join(home, ".cmuxterm", hookStoreFileName)}
}

// load returns the parsed store, or nil when it is absent or unreadable. A
// missing store is normal (cmux not installed, or no agent has run yet) and is
// never an error here — the caller falls back to path derivation.
func (s *hookStore) load() *hookStoreFile {
	info, err := os.Stat(s.path)
	if err != nil || !info.Mode().IsRegular() || info.Size() > maxHookStoreBytes {
		return nil
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	if s.parsed != nil && s.modTime.Equal(info.ModTime()) && s.size == info.Size() {
		return s.parsed
	}

	data, err := os.ReadFile(s.path)
	if err != nil {
		return nil
	}
	var file hookStoreFile
	if err := json.Unmarshal(data, &file); err != nil {
		// A torn read (the CLI rewrites this file under a lock we don't hold)
		// parses as garbage. Keep serving the last good parse rather than
		// dropping to the glob for one poll.
		return s.parsed
	}
	s.parsed = &file
	s.modTime = info.ModTime()
	s.size = info.Size()
	return s.parsed
}

// bySurface returns the record for the session a cmux surface is running.
// Prefers the store's own active-session pointer; falls back to the most
// recently updated record naming that surface, which covers a session whose
// pointer was cleared (e.g. after a SessionEnd) but whose transcript is still
// the last thing that surface showed.
func (s *hookStore) bySurface(surfaceID string) (hookSessionRecord, bool) {
	if surfaceID == "" {
		return hookSessionRecord{}, false
	}
	file := s.load()
	if file == nil {
		return hookSessionRecord{}, false
	}

	for key, active := range file.ActiveSessionsBySurface {
		if !strings.EqualFold(key, surfaceID) {
			continue
		}
		if rec, ok := lookupSession(file, active.SessionID); ok {
			return rec, true
		}
	}

	var best hookSessionRecord
	found := false
	for _, rec := range file.Sessions {
		if !strings.EqualFold(rec.SurfaceID, surfaceID) {
			continue
		}
		if !found || rec.UpdatedAt > best.UpdatedAt {
			best = rec
			found = true
		}
	}
	return best, found
}

// bySession returns the record for one session id.
func (s *hookStore) bySession(sessionID string) (hookSessionRecord, bool) {
	if sessionID == "" {
		return hookSessionRecord{}, false
	}
	file := s.load()
	if file == nil {
		return hookSessionRecord{}, false
	}
	return lookupSession(file, sessionID)
}

// lookupSession finds a session record by id. Session ids are UUIDs whose case
// the writers do not agree on (the store normalizes to lower case, cmux's
// resume binding does not), so the match is case-insensitive.
func lookupSession(file *hookStoreFile, sessionID string) (hookSessionRecord, bool) {
	if sessionID == "" || file == nil {
		return hookSessionRecord{}, false
	}
	if rec, ok := file.Sessions[sessionID]; ok {
		return rec, true
	}
	if rec, ok := file.Sessions[strings.ToLower(sessionID)]; ok {
		return rec, true
	}
	for key, rec := range file.Sessions {
		if strings.EqualFold(key, sessionID) {
			return rec, true
		}
	}
	return hookSessionRecord{}, false
}

// readableTranscript reports whether a store-supplied path names a transcript
// file that can be read now.
//
// The store is a 0600 file the CLI writes for this user, and the path in it
// came from Claude Code itself, so this is a sanity check rather than a trust
// boundary: it must be an absolute, unwalked path to an existing regular
// .jsonl file. Notably it is NOT confined to ~/.claude/projects — relocating
// that tree with CLAUDE_CONFIG_DIR is exactly the case the store exists to
// handle.
func readableTranscript(path string) bool {
	if path == "" || !filepath.IsAbs(path) {
		return false
	}
	if filepath.Clean(path) != path || !strings.HasSuffix(path, ".jsonl") {
		return false
	}
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular()
}
