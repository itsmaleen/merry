package imagepaste

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// pngBytes is a minimal valid PNG (2x2, red).
var pngBytes = []byte{
	0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a,
	0x00, 0x00, 0x00, 0x0d, 'I', 'H', 'D', 'R',
	0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x08, 0x02, 0x00, 0x00, 0x00,
	0x7a, 0x7a, 0xd4, 0x76,
}

func jpegBytes() []byte {
	return append([]byte{0xff, 0xd8, 0xff, 0xe0}, bytes.Repeat([]byte{0}, 32)...)
}
func gifBytes() []byte { return append([]byte("GIF89a"), bytes.Repeat([]byte{0}, 32)...) }
func webpBytes() []byte {
	b := []byte("RIFF____WEBPVP8 ")
	return append(b, bytes.Repeat([]byte{0}, 32)...)
}
func heicBytes() []byte {
	b := []byte{0, 0, 0, 0x18}
	b = append(b, "ftypheic"...)
	return append(b, bytes.Repeat([]byte{0}, 32)...)
}

func newTestStore(t *testing.T) *Store {
	t.Helper()
	return &Store{dir: filepath.Join(t.TempDir(), dirName)}
}

// The extension comes from the bytes, not from anything the client says — a
// payload must never be able to acquire a misleading name.
func TestSaveDetectsFormatFromContent(t *testing.T) {
	cases := map[string][]byte{
		"png":  pngBytes,
		"jpg":  jpegBytes(),
		"gif":  gifBytes(),
		"webp": webpBytes(),
		"heic": heicBytes(), // what an iPhone camera produces by default
	}
	for want, data := range cases {
		store := newTestStore(t)
		res, err := store.Save(data)
		if err != nil {
			t.Fatalf("%s: unexpected error: %v", want, err)
		}
		if res.Format != want {
			t.Fatalf("want format %q, got %q", want, res.Format)
		}
		if filepath.Ext(res.Path) != "."+want {
			t.Fatalf("want extension .%s, got %q", want, res.Path)
		}
		if got, err := os.ReadFile(res.Path); err != nil || !bytes.Equal(got, data) {
			t.Fatalf("%s: file does not contain the original bytes (err=%v)", want, err)
		}
	}
}

func TestSaveRejectsNonImages(t *testing.T) {
	store := newTestStore(t)
	for name, data := range map[string][]byte{
		"empty":      {},
		"plain text": []byte("#!/bin/sh\nrm -rf /\n"),
		"pdf":        []byte("%PDF-1.7\n..............."),
		"elf":        {0x7f, 'E', 'L', 'F', 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0},
	} {
		if _, err := store.Save(data); err == nil {
			t.Fatalf("%s was accepted as an image", name)
		}
	}
}

func TestSaveRejectsOversizedImage(t *testing.T) {
	store := newTestStore(t)
	huge := append(append([]byte{}, pngBytes...), bytes.Repeat([]byte{0}, MaxImageBytes)...)
	if _, err := store.Save(huge); err == nil {
		t.Fatal("an image past the limit was accepted")
	}
}

// Two pastes of identical bytes must not collide: the second would otherwise
// overwrite an image the agent may not have read yet.
func TestSaveGeneratesDistinctPaths(t *testing.T) {
	store := newTestStore(t)
	first, err := store.Save(pngBytes)
	if err != nil {
		t.Fatal(err)
	}
	second, err := store.Save(pngBytes)
	if err != nil {
		t.Fatal(err)
	}
	if first.Path == second.Path {
		t.Fatalf("both pastes wrote to %q", first.Path)
	}
}

// Pasted images are as private as the conversation they belong to.
func TestSaveUsesPrivatePermissions(t *testing.T) {
	store := newTestStore(t)
	res, err := store.Save(pngBytes)
	if err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(res.Path)
	if err != nil {
		t.Fatal(err)
	}
	if perm := info.Mode().Perm(); perm != 0o600 {
		t.Fatalf("image mode is %o, want 600", perm)
	}
	dirInfo, err := os.Stat(filepath.Dir(res.Path))
	if err != nil {
		t.Fatal(err)
	}
	if perm := dirInfo.Mode().Perm(); perm != 0o700 {
		t.Fatalf("directory mode is %o, want 700", perm)
	}
}

// The typed text is what the agent sees; it must be a complete, quoted token.
func TestSaveTextIsQuotedPathWithTrailingSpace(t *testing.T) {
	store := newTestStore(t)
	res, err := store.Save(pngBytes)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(res.Text, " ") {
		t.Fatalf("want a trailing space so the path is a complete token, got %q", res.Text)
	}
	if res.Text != ShellQuote(res.Path)+" " {
		t.Fatalf("text is not the quoted path: %q", res.Text)
	}
	if strings.ContainsAny(res.Text, "\n\r") {
		t.Fatalf("text contains a newline, which would submit the prompt: %q", res.Text)
	}
}

func TestShellQuote(t *testing.T) {
	cases := map[string]string{
		"/tmp/a.png":            "'/tmp/a.png'",
		"/tmp/with space.png":   "'/tmp/with space.png'",
		"/tmp/it's here.png":    `'/tmp/it'\''s here.png'`,
		"/tmp/$(whoami).png":    "'/tmp/$(whoami).png'",
		"/tmp/`id`.png":         "'/tmp/`id`.png'",
		"/tmp/a;rm -rf ~/b.png": "'/tmp/a;rm -rf ~/b.png'",
	}
	for input, want := range cases {
		if got := ShellQuote(input); got != want {
			t.Fatalf("ShellQuote(%q) = %q, want %q", input, got, want)
		}
	}
}

// Images outlive one paste but not the machine: nothing else ever deletes them.
func TestPruneRemovesExpiredImagesOnly(t *testing.T) {
	store := newTestStore(t)
	fresh, err := store.Save(pngBytes)
	if err != nil {
		t.Fatal(err)
	}
	old := filepath.Join(store.dir, "pasted-19700101-000000-deadbeef.png")
	if err := os.WriteFile(old, pngBytes, 0o600); err != nil {
		t.Fatal(err)
	}
	stale := time.Now().Add(-retention - time.Hour)
	if err := os.Chtimes(old, stale, stale); err != nil {
		t.Fatal(err)
	}
	// An unrelated file the store did not write must be left alone.
	foreign := filepath.Join(store.dir, "notes.txt")
	if err := os.WriteFile(foreign, []byte("keep me"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(foreign, stale, stale); err != nil {
		t.Fatal(err)
	}

	if _, err := store.Save(pngBytes); err != nil { // pruning runs on save
		t.Fatal(err)
	}

	if _, err := os.Stat(old); !os.IsNotExist(err) {
		t.Fatal("an expired image survived the prune")
	}
	if _, err := os.Stat(fresh.Path); err != nil {
		t.Fatalf("a fresh image was pruned: %v", err)
	}
	if _, err := os.Stat(foreign); err != nil {
		t.Fatal("prune deleted a file it did not write")
	}
}
