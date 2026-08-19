package claude

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// writeHookStore writes a cmux hook session store shaped like the real one.
func writeHookStore(t *testing.T, home string, store map[string]any) {
	t.Helper()
	dir := filepath.Join(home, ".cmuxterm")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	data, err := json.Marshal(store)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, hookStoreFileName), data, 0o600); err != nil {
		t.Fatal(err)
	}
}

func writeTranscript(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	line := `{"type":"user","message":{"role":"user","content":"` + content + `"}}` + "\n"
	if err := os.WriteFile(path, []byte(line), 0o644); err != nil {
		t.Fatal(err)
	}
}

// The hook store records the transcript path Claude Code itself reported, so a
// transcript outside ~/.claude/projects (a relocated CLAUDE_CONFIG_DIR) still
// resolves — the glob strategy cannot see it at all.
func TestResolveUsesHookStorePathOutsideProjects(t *testing.T) {
	home := t.TempDir()
	surfaceID := "80268E71-E614-4020-A413-70B0ED2ED4E3"
	sessionID := "11111111-2222-3333-4444-555555555555"
	transcript := filepath.Join(home, "elsewhere", "projects", "-proj", sessionID+".jsonl")
	writeTranscript(t, transcript, "FROM STORE")

	writeHookStore(t, home, map[string]any{
		"activeSessionsBySurface": map[string]any{
			surfaceID: map[string]any{"sessionId": sessionID},
		},
		"sessions": map[string]any{
			sessionID: map[string]any{
				"sessionId":      sessionID,
				"surfaceId":      surfaceID,
				"transcriptPath": transcript,
				"updatedAt":      1.0,
			},
		},
	})

	r := newResolver(home)
	res, err := r.Render(Request{
		SurfaceID:     surfaceID,
		ResumeBinding: map[string]any{"kind": "claude", "checkpoint_id": sessionID},
		MaxMessages:   100,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(res.Text, "FROM STORE") {
		t.Fatalf("want the recorded transcript, got %q", res.Text)
	}
	if res.Source != "hook_store_session" {
		t.Fatalf("want source hook_store_session, got %q", res.Source)
	}
	if res.SessionID != sessionID {
		t.Fatalf("want session %q, got %q", sessionID, res.SessionID)
	}
}

// Surfaces share a cwd, so the store binding must win over anything derived
// from the directory — a surface must never be shown its neighbour's session.
func TestResolveHookStoreBindsPerSurface(t *testing.T) {
	home := t.TempDir()
	cwd := "/Users/someone/proj"
	projects := filepath.Join(home, ".claude", "projects", encodeCWD(cwd))

	mine := "aaaaaaaa-1111-2222-3333-444444444444"
	theirs := "bbbbbbbb-1111-2222-3333-444444444444"
	writeTranscript(t, filepath.Join(projects, mine+".jsonl"), "MINE")
	// Written second, so a newest-file heuristic would pick it.
	writeTranscript(t, filepath.Join(projects, theirs+".jsonl"), "THEIRS")

	surfaceID := "1C2A2F22-DEF6-4214-A37E-1D6CA026BE1F"
	writeHookStore(t, home, map[string]any{
		"activeSessionsBySurface": map[string]any{
			surfaceID: map[string]any{"sessionId": mine},
		},
		"sessions": map[string]any{
			mine: map[string]any{
				"sessionId":      mine,
				"surfaceId":      surfaceID,
				"cwd":            cwd,
				"transcriptPath": filepath.Join(projects, mine+".jsonl"),
				"updatedAt":      2.0,
			},
			theirs: map[string]any{
				"sessionId":      theirs,
				"surfaceId":      "OTHER-SURFACE",
				"cwd":            cwd,
				"transcriptPath": filepath.Join(projects, theirs+".jsonl"),
				"updatedAt":      3.0,
			},
		},
	})

	r := newResolver(home)
	res, err := r.Render(Request{
		SurfaceID:     surfaceID,
		ResumeBinding: map[string]any{"kind": "claude", "cwd": cwd},
		MaxMessages:   100,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if strings.Contains(res.Text, "THEIRS") {
		t.Fatalf("served another surface's transcript: %q", res.Text)
	}
	if !strings.Contains(res.Text, "MINE") {
		t.Fatalf("want this surface's transcript, got %q", res.Text)
	}
}

// A store entry pointing at a file that no longer exists must fall through to
// the checkpoint_id strategies rather than reporting nothing.
func TestResolveFallsBackWhenStorePathIsStale(t *testing.T) {
	home := t.TempDir()
	surfaceID := "2A47C8D4-4EFF-4F51-8B4F-760758056F09"
	sessionID := "cccccccc-1111-2222-3333-444444444444"
	projects := filepath.Join(home, ".claude", "projects", "-proj")
	writeTranscript(t, filepath.Join(projects, sessionID+".jsonl"), "ON DISK")

	writeHookStore(t, home, map[string]any{
		"activeSessionsBySurface": map[string]any{
			surfaceID: map[string]any{"sessionId": sessionID},
		},
		"sessions": map[string]any{
			sessionID: map[string]any{
				"sessionId":      sessionID,
				"surfaceId":      surfaceID,
				"transcriptPath": filepath.Join(home, "gone", sessionID+".jsonl"),
				"updatedAt":      1.0,
			},
		},
	})

	r := newResolver(home)
	res, err := r.Render(Request{
		SurfaceID:     surfaceID,
		ResumeBinding: map[string]any{"kind": "claude", "checkpoint_id": sessionID},
		MaxMessages:   100,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(res.Text, "ON DISK") {
		t.Fatalf("want the glob fallback to resolve, got %q (source %q)", res.Text, res.Source)
	}
	if res.Source != "projects_glob" {
		t.Fatalf("want source projects_glob, got %q", res.Source)
	}
}

// Claude nests some sessions a level below the encoded-cwd directory, where a
// single-level glob never looked.
func TestResolveFindsNestedTranscript(t *testing.T) {
	home := t.TempDir()
	parent := "dddddddd-1111-2222-3333-444444444444"
	nested := "eeeeeeee-1111-2222-3333-444444444444"
	path := filepath.Join(home, ".claude", "projects", "-proj", parent, nested+".jsonl")
	writeTranscript(t, path, "NESTED")

	r := newResolver(home)
	res, err := r.Render(Request{
		ResumeBinding: map[string]any{"kind": "claude", "checkpoint_id": nested},
		MaxMessages:   100,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(res.Text, "NESTED") {
		t.Fatalf("want the nested transcript, got %q", res.Text)
	}
}

// A store whose entry names a surface but whose file is gone, with no
// checkpoint_id to fall back on, reports the session missing instead of
// guessing the newest session for the cwd.
func TestResolveStoreOnlyMissingFileDoesNotFallBackToCWD(t *testing.T) {
	home := t.TempDir()
	cwd := "/Users/someone/proj"
	projects := filepath.Join(home, ".claude", "projects", encodeCWD(cwd))
	writeTranscript(t, filepath.Join(projects, "ffffffff-1111-2222-3333-444444444444.jsonl"), "OTHER SURFACE")

	surfaceID := "40FF3C91-303F-423F-9827-328F28A310E8"
	goneID := "99999999-1111-2222-3333-444444444444"
	writeHookStore(t, home, map[string]any{
		"activeSessionsBySurface": map[string]any{
			surfaceID: map[string]any{"sessionId": goneID},
		},
		"sessions": map[string]any{
			goneID: map[string]any{
				"sessionId":      goneID,
				"surfaceId":      surfaceID,
				"cwd":            cwd,
				"transcriptPath": filepath.Join(home, "gone.jsonl"),
				"updatedAt":      1.0,
			},
		},
	})

	r := newResolver(home)
	res, err := r.Render(Request{
		SurfaceID:     surfaceID,
		ResumeBinding: map[string]any{"kind": "claude", "cwd": cwd},
		MaxMessages:   100,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.Text != "" {
		t.Fatalf("want empty text, got %q", res.Text)
	}
	if !res.SessionMissing || res.SessionID != goneID {
		t.Fatalf("want the bound session reported missing, got missing=%v id=%q", res.SessionMissing, res.SessionID)
	}
}

// The fingerprint round-trip is what makes polling cheap: hand it back and an
// unchanged transcript answers without text.
func TestRenderUnchangedSkipsText(t *testing.T) {
	home := t.TempDir()
	sessionID := "12121212-1111-2222-3333-444444444444"
	path := filepath.Join(home, ".claude", "projects", "-proj", sessionID+".jsonl")
	writeTranscript(t, path, "HELLO")

	r := newResolver(home)
	req := Request{
		ResumeBinding: map[string]any{"kind": "claude", "checkpoint_id": sessionID},
		MaxMessages:   100,
	}
	first, err := r.Render(req)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if first.Fingerprint == "" || first.Unchanged {
		t.Fatalf("want a fingerprint and Unchanged=false, got %q / %v", first.Fingerprint, first.Unchanged)
	}

	req.KnownFingerprint = first.Fingerprint
	second, err := r.Render(req)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !second.Unchanged || second.Text != "" {
		t.Fatalf("want Unchanged with no text, got unchanged=%v text=%q", second.Unchanged, second.Text)
	}
	if second.Fingerprint != first.Fingerprint {
		t.Fatalf("fingerprint changed without the file changing")
	}

	// A different message bound is a different rendering, so the client's
	// fingerprint must not suppress it.
	req.MaxMessages = 1
	third, err := r.Render(req)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if third.Unchanged {
		t.Fatal("want a fresh render when the message bound changes")
	}
}

// A store that is absent, truncated, or half-written must never break the
// resolver — it silently drops back to path derivation.
func TestHookStoreToleratesGarbage(t *testing.T) {
	home := t.TempDir()
	sessionID := "13131313-1111-2222-3333-444444444444"
	path := filepath.Join(home, ".claude", "projects", "-proj", sessionID+".jsonl")
	writeTranscript(t, path, "HELLO")

	dir := filepath.Join(home, ".cmuxterm")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, hookStoreFileName), []byte(`{"sessions": {"a`), 0o600); err != nil {
		t.Fatal(err)
	}

	r := newResolver(home)
	res, err := r.Render(Request{
		SurfaceID:     "ANY-SURFACE",
		ResumeBinding: map[string]any{"kind": "claude", "checkpoint_id": sessionID},
		MaxMessages:   100,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(res.Text, "HELLO") {
		t.Fatalf("want derivation to still work with a corrupt store, got %q", res.Text)
	}
}

// The store must not become a way to read arbitrary files: a path is accepted
// only when it is absolute, unwalked, and — after symlinks — still named for the
// session that claims it.
func TestStoredTranscriptRejectsOddPaths(t *testing.T) {
	home := t.TempDir()
	sessionID := "14141414-1111-2222-3333-444444444444"
	secret := filepath.Join(home, "secret.txt")
	if err := os.WriteFile(secret, []byte("SECRET"), 0o600); err != nil {
		t.Fatal(err)
	}
	real := filepath.Join(home, sessionID+".jsonl")
	if err := os.WriteFile(real, []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	// A symlink NAMED for the session but pointing at another session's file.
	other := filepath.Join(home, "99999999-1111-2222-3333-444444444444.jsonl")
	if err := os.WriteFile(other, []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	redirect := filepath.Join(home, "redirect", sessionID+".jsonl")
	if err := os.MkdirAll(filepath.Dir(redirect), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(other, redirect); err != nil {
		t.Fatal(err)
	}

	for name, path := range map[string]string{
		"empty":            "",
		"relative":         sessionID + ".jsonl",
		"wrong extension":  secret,
		"unclean":          home + "/sub/../" + sessionID + ".jsonl",
		"directory":        home,
		"other session":    other,
		"symlink redirect": redirect,
	} {
		if resolved, ok := storedTranscript(path, sessionID); ok {
			t.Fatalf("accepted %s: %q -> %q", name, path, resolved)
		}
	}

	// The returned path is the symlink-resolved one (on macOS a TempDir under
	// /var resolves to /private/var), so compare identity, not spelling.
	resolvedReal, ok := storedTranscript(real, sessionID)
	if !ok {
		t.Fatalf("rejected a real transcript %q", real)
	}
	if got, err := os.Stat(resolvedReal); err != nil {
		t.Fatalf("resolved path is not readable: %v", err)
	} else if want, _ := os.Stat(real); !os.SameFile(got, want) {
		t.Fatalf("resolved %q is a different file from %q", resolvedReal, real)
	}

	// A symlinked tree (a relocated ~/.claude) still resolves: only the file
	// NAME is constrained, never the directory.
	linkedDir := filepath.Join(home, "linked")
	if err := os.Symlink(home, linkedDir); err != nil {
		t.Fatal(err)
	}
	if _, ok := storedTranscript(filepath.Join(linkedDir, sessionID+".jsonl"), sessionID); !ok {
		t.Fatal("rejected a transcript reached through a symlinked directory")
	}
}

// A surface's store record outlives the session that wrote it, so a historical
// record must never outrank the session the surface's checkpoint names.
// Reproduced by cross-review before this ordering existed: the bridge served the
// ended session A indefinitely while the surface ran session B.
func TestResolveCurrentCheckpointBeatsHistoricalRecord(t *testing.T) {
	home := t.TempDir()
	surfaceID := "5F0C931D-1111-2222-3333-444444444444"
	sessA := "aaaaaaaa-1111-2222-3333-444444444444" // ended, pointer cleared
	sessB := "bbbbbbbb-5555-6666-7777-888888888888" // what the surface runs now
	projects := filepath.Join(home, ".claude", "projects", "-proj")
	writeTranscript(t, filepath.Join(projects, sessA+".jsonl"), "OLD SESSION A")
	writeTranscript(t, filepath.Join(projects, sessB+".jsonl"), "CURRENT SESSION B")

	writeHookStore(t, home, map[string]any{
		// No active pointer for the surface — SessionEnd cleared it.
		"activeSessionsBySurface": map[string]any{},
		"sessions": map[string]any{
			sessA: map[string]any{
				"sessionId":      sessA,
				"surfaceId":      surfaceID,
				"transcriptPath": filepath.Join(projects, sessA+".jsonl"),
				"updatedAt":      100.0,
			},
		},
	})

	r := newResolver(home)
	res, err := r.Render(Request{
		SurfaceID:     surfaceID,
		ResumeBinding: map[string]any{"kind": "claude", "checkpoint_id": sessB},
		MaxMessages:   100,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if strings.Contains(res.Text, "OLD SESSION A") {
		t.Fatalf("served the ended session instead of the current one: source=%q", res.Source)
	}
	if !strings.Contains(res.Text, "CURRENT SESSION B") {
		t.Fatalf("want session B, got %q (source %q)", res.Text, res.Source)
	}
	if res.SessionID != sessB {
		t.Fatalf("want session %q, got %q", sessB, res.SessionID)
	}
}

// An active pointer that names a session belonging to a DIFFERENT surface is an
// inconsistent store, and following it would hand this client someone else's
// conversation. Reproduced by cross-review.
func TestResolveIgnoresActivePointerForAnotherSurface(t *testing.T) {
	home := t.TempDir()
	mySurface := "AAAAAAAA-1111-1111-1111-AAAAAAAAAAAA"
	theirSurface := "BBBBBBBB-2222-2222-2222-BBBBBBBBBBBB"
	mySession := "11111111-1111-1111-1111-111111111111"
	theirSession := "22222222-2222-2222-2222-222222222222"
	projects := filepath.Join(home, ".claude", "projects", "-proj")
	writeTranscript(t, filepath.Join(projects, theirSession+".jsonl"), "THEIR PRIVATE CONVERSATION")

	writeHookStore(t, home, map[string]any{
		// Inconsistent: my surface points at their session.
		"activeSessionsBySurface": map[string]any{
			mySurface: map[string]any{"sessionId": theirSession},
		},
		"sessions": map[string]any{
			theirSession: map[string]any{
				"sessionId":      theirSession,
				"surfaceId":      theirSurface,
				"transcriptPath": filepath.Join(projects, theirSession+".jsonl"),
				"updatedAt":      100.0,
			},
		},
	})

	r := newResolver(home)
	res, err := r.Render(Request{
		SurfaceID:     mySurface,
		ResumeBinding: map[string]any{"kind": "claude", "checkpoint_id": mySession},
		MaxMessages:   100,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if strings.Contains(res.Text, "THEIR PRIVATE CONVERSATION") {
		t.Fatalf("leaked another surface's transcript (source %q)", res.Source)
	}
	if res.SessionID != mySession || !res.SessionMissing {
		t.Fatalf("want my session reported missing, got id=%q missing=%v", res.SessionID, res.SessionMissing)
	}
}

// max_messages is client-chosen, so an unbounded cache lets one client pin
// arbitrary memory. Reproduced by cross-review at 897 MiB over 2000 values.
func TestRenderCacheIsBounded(t *testing.T) {
	home := t.TempDir()
	sessionID := "15151515-1111-2222-3333-444444444444"
	writeTranscript(t, filepath.Join(home, ".claude", "projects", "-proj", sessionID+".jsonl"), "HELLO")

	r := newResolver(home)
	for i := 1; i <= maxCachedRenderings*8; i++ {
		if _, err := r.Render(Request{
			ResumeBinding: map[string]any{"kind": "claude", "checkpoint_id": sessionID},
			MaxMessages:   i,
		}); err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
	}
	r.cache.mu.Lock()
	entries, order := len(r.cache.entries), len(r.cache.order)
	r.cache.mu.Unlock()
	if entries > maxCachedRenderings || order > maxCachedRenderings {
		t.Fatalf("cache grew past the cap: %d entries, %d ordered", entries, order)
	}
}
