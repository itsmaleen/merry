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
	if res.Source != "hook_store_surface" {
		t.Fatalf("want source hook_store_surface, got %q", res.Source)
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

// The store must not become a way to read arbitrary files: a path that is not
// an absolute, unwalked .jsonl is ignored.
func TestReadableTranscriptRejectsOddPaths(t *testing.T) {
	home := t.TempDir()
	secret := filepath.Join(home, "secret.txt")
	if err := os.WriteFile(secret, []byte("SECRET"), 0o600); err != nil {
		t.Fatal(err)
	}
	real := filepath.Join(home, "ok.jsonl")
	if err := os.WriteFile(real, []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}

	for _, bad := range []string{
		"",
		"relative.jsonl",
		secret,
		home + "/sub/../ok.jsonl", // unclean, so never dereferenced
		home,                      // a directory
	} {
		if readableTranscript(bad) {
			t.Fatalf("accepted %q", bad)
		}
	}
	if !readableTranscript(real) {
		t.Fatalf("rejected a real transcript %q", real)
	}
}

// A tool call shows what it did, not just which tool ran, and consecutive
// messages from one side share a single header.
func TestRenderToolSummariesAndTurnHeaders(t *testing.T) {
	lines := []string{
		`{"type":"user","message":{"role":"user","content":"run the tests"}}`,
		`{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"On it."}]}}`,
		`{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"go   test\n./...","description":"run tests"}}]}}`,
		`{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{"file_path":"/tmp/x.go"}}]}}`,
	}
	got := renderJSONL([]byte(strings.Join(lines, "\n")+"\n"), 200)

	if !strings.Contains(got, "⚙ Bash: go test ./...") {
		t.Errorf("want the command summarized on one line, got:\n%s", got)
	}
	if !strings.Contains(got, "⚙ Read: /tmp/x.go") {
		t.Errorf("want the file path summarized, got:\n%s", got)
	}
	if n := strings.Count(got, "⏺ Claude"); n != 1 {
		t.Errorf("want one header for the assistant turn, got %d:\n%s", n, got)
	}
	if n := strings.Count(got, "› You"); n != 1 {
		t.Errorf("want one user header, got %d:\n%s", n, got)
	}

	// A tool with no interesting input still renders its name.
	bare := renderJSONL([]byte(`{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":[]}}]}}`+"\n"), 200)
	if !strings.Contains(bare, "⚙ TodoWrite") || strings.Contains(bare, "⚙ TodoWrite:") {
		t.Errorf("want a bare tool name, got %q", bare)
	}
}
