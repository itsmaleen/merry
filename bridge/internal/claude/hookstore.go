package claude

import (
	"encoding/json"
	"io"
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

	// LimitReader, not ReadFile: the CLI rewrites this file on every hook event,
	// so the size the guard above checked can be stale by the time it is opened.
	f, err := os.Open(s.path)
	if err != nil {
		return nil
	}
	data, err := io.ReadAll(io.LimitReader(f, maxHookStoreBytes))
	f.Close()
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

// activeBySurface returns the session the store says a surface is running right
// now. This is the store's own authoritative pointer, so it is the only
// surface-keyed lookup allowed to override a resolution the surface's
// checkpoint could not satisfy.
func (s *hookStore) activeBySurface(surfaceID string) (hookSessionRecord, bool) {
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
		rec, ok := lookupSession(file, active.SessionID)
		if !ok {
			return hookSessionRecord{}, false
		}
		// The pointer and the record must agree about which surface this is.
		// They are written by the same hooks, so a disagreement means the store
		// is stale or inconsistent — and following it hands this surface's
		// client another surface's conversation.
		if rec.SurfaceID != "" && !strings.EqualFold(rec.SurfaceID, surfaceID) {
			return hookSessionRecord{}, false
		}
		return rec, true
	}
	return hookSessionRecord{}, false
}

// recentBySurface returns the most recently updated record naming a surface.
//
// Unlike activeBySurface this is a HISTORICAL guess: a session whose pointer
// was cleared (SessionEnd) still matches here, so it must never outrank a
// session the surface's resume_binding actually names — it is only for a
// surface that names none at all.
func (s *hookStore) recentBySurface(surfaceID string) (hookSessionRecord, bool) {
	if surfaceID == "" {
		return hookSessionRecord{}, false
	}
	file := s.load()
	if file == nil {
		return hookSessionRecord{}, false
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

// storedTranscript resolves a store-supplied path for one session, returning
// the path to actually read.
//
// The path must be absolute and unwalked, and — after symlinks are resolved —
// must still be a regular file named `<sessionID>.jsonl`. Tying the file name
// to the session the record claims is what keeps a stale, inconsistent, or
// tampered store from turning this into "read whichever JSONL the store names":
// without it a record for session A can serve session B's conversation, or a
// symlink can redirect the read to an unrelated file entirely.
//
// Only the file NAME is constrained, never the directory, because relocating
// the transcript tree with CLAUDE_CONFIG_DIR is exactly the case the store
// exists to handle. A record that fails this check is not fatal: the caller
// falls through to deriving the path under ~/.claude/projects.
func storedTranscript(path, sessionID string) (string, bool) {
	if path == "" || sessionID == "" || !filepath.IsAbs(path) {
		return "", false
	}
	if filepath.Clean(path) != path || !strings.HasSuffix(path, ".jsonl") {
		return "", false
	}
	// Resolve once and read the resolved path, so the name that was checked is
	// the file that gets opened.
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		return "", false
	}
	if !strings.EqualFold(filepath.Base(resolved), sessionID+".jsonl") {
		return "", false
	}
	info, err := os.Stat(resolved)
	if err != nil || !info.Mode().IsRegular() {
		return "", false
	}
	return resolved, true
}
