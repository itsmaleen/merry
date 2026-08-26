package pair

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLoadOrCreateTokenCreatesPrivateFile(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "cfg")
	tok, err := LoadOrCreateToken(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(tok) < 40 {
		t.Fatalf("token too short: %q", tok)
	}
	info, err := os.Stat(filepath.Join(dir, tokenFile))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("token mode = %04o, want 0600", info.Mode().Perm())
	}
	again, err := LoadOrCreateToken(dir)
	if err != nil || again != tok {
		t.Fatalf("second load = %q, %v; want the same token", again, err)
	}
}

// A pre-created, world-accessible directory (the planted-token attack) is
// refused rather than trusted.
func TestLoadOrCreateTokenRefusesSharedDir(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "shared")
	if err := os.MkdirAll(dir, 0o777); err != nil {
		t.Fatal(err)
	}
	_ = os.Chmod(dir, 0o777) // umask may have narrowed it
	if err := os.WriteFile(filepath.Join(dir, tokenFile), []byte("PLANTED\n"), 0o666); err != nil {
		t.Fatal(err)
	}
	_, err := LoadOrCreateToken(dir)
	if err == nil || !strings.Contains(err.Error(), "accessible to other users") {
		t.Fatalf("expected a refusal for a shared dir, got %v", err)
	}
}

func TestLoadOrCreateTokenRefusesReadableToken(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "cfg")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, tokenFile), []byte("PLANTED\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := LoadOrCreateToken(dir)
	if err == nil || !strings.Contains(err.Error(), "readable by other users") {
		t.Fatalf("expected a refusal for a 0644 token, got %v", err)
	}
}

func TestLoadOrCreateTokenRefusesSymlinkedToken(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "cfg")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(t.TempDir(), "elsewhere")
	if err := os.WriteFile(target, []byte("PLANTED\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(dir, tokenFile)); err != nil {
		t.Fatal(err)
	}
	_, err := LoadOrCreateToken(dir)
	if err == nil || !strings.Contains(err.Error(), "symlink") {
		t.Fatalf("expected a refusal for a symlinked token, got %v", err)
	}
}
