// Package imagepaste materializes an image the phone pasted into a file on the
// Mac, so its path can be typed into a terminal surface.
//
// This is how a terminal receives an image at all: a TUI reads bytes from a pty,
// so there is no way to hand it a picture directly. What a local clipboard-image
// paste does — in Ghostty, and in cmux's own `terminal.paste_image` — is write
// the image to a file and insert its path as ordinary input. Claude Code then
// attaches the image from that path. Doing the same here keeps the bridge
// working against cmux builds that predate that RPC.
package imagepaste

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// MaxImageBytes bounds a decoded image. Phone photos run 2–5 MB; this leaves
// room for a screenshot of a large display while keeping one paste from
// monopolising the WebSocket or the disk.
const MaxImageBytes = 12 * 1024 * 1024

// retention is how long a pasted image stays on disk. It only has to outlive the
// agent's read of it, but a user re-referencing "that screenshot from earlier"
// in the same session is normal, so keep them for the working day.
const retention = 12 * time.Hour

// dirName is created under the user's cache dir with 0700: pasted images are as
// private as the conversation they belong to.
const dirName = "cmux-companion-images"

// Result describes one materialized image.
type Result struct {
	// Path is the file on disk.
	Path string
	// Text is what to type into the surface: the shell-escaped path plus a
	// trailing space, so the agent sees a complete token and the user can keep
	// typing after it.
	Text string
	// Bytes is the decoded image size.
	Bytes int
	// Format is the detected image format, which may differ from what the
	// client claimed.
	Format string
}

// Store writes pasted images into a directory it owns.
type Store struct {
	dir string
}

// NewStore creates a store under the user's cache directory. It prunes expired
// files immediately — covering anything a previous process left behind past the
// retention window — and then keeps pruning on a timer, so a sensitive file is
// deleted after `retention` even if no further attachment is ever saved.
func NewStore() *Store {
	base, err := os.UserCacheDir()
	if err != nil {
		base = os.TempDir()
	}
	s := &Store{dir: filepath.Join(base, dirName)}
	s.prune()
	go s.pruneLoop()
	return s
}

// pruneLoop deletes expired files on a timer for the life of the process, so
// retention doesn't depend on a future upload happening.
func (s *Store) pruneLoop() {
	ticker := time.NewTicker(time.Hour)
	defer ticker.Stop()
	for range ticker.C {
		s.prune()
	}
}

// Remove deletes one stored file, used to clean up an upload whose dispatch to
// the surface failed so a rejected paste doesn't linger for the full retention.
func (s *Store) Remove(path string) {
	// Only touch files inside the store dir, never a caller-influenced path.
	if filepath.Dir(path) != s.dir {
		return
	}
	_ = os.Remove(path)
}

// Save writes image bytes to a new file and returns what to type into a surface.
//
// The file name is generated here and never taken from the client: the client
// supplies bytes, nothing that reaches the filesystem. The extension comes from
// sniffing the content rather than from the client's claim, so a payload can't
// be given a misleading name.
func (s *Store) Save(data []byte) (Result, error) {
	if len(data) == 0 {
		return Result{}, errors.New("empty image")
	}
	if len(data) > MaxImageBytes {
		return Result{}, fmt.Errorf("image is %d bytes, limit is %d", len(data), MaxImageBytes)
	}
	format, ok := detectFormat(data)
	if !ok {
		return Result{}, errors.New("payload is not a supported image (png, jpeg, gif, webp, heic)")
	}

	if err := os.MkdirAll(s.dir, 0o700); err != nil {
		return Result{}, err
	}
	s.prune()

	var nonce [8]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return Result{}, err
	}
	name := fmt.Sprintf("pasted-%s-%s.%s",
		time.Now().Format("20060102-150405"), hex.EncodeToString(nonce[:]), format)
	path := filepath.Join(s.dir, name)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return Result{}, err
	}

	return Result{
		Path:   path,
		Text:   ShellQuote(path) + " ",
		Bytes:  len(data),
		Format: format,
	}, nil
}

// MaxFileBytes bounds a non-image attachment. Kept equal to MaxImageBytes so a
// file plus its base64 still fits the WebSocket read limit the ws handler sets.
const MaxFileBytes = MaxImageBytes

// SaveFile writes an arbitrary uploaded file (a PDF, a log, a zip — whatever the
// phone picked) under the store dir and returns its path, so the path can be
// typed into a surface exactly like a pasted image.
//
// Unlike Save it does not sniff or transform the content — a file is stored
// byte-for-byte — but the on-disk NAME is always generated, never the client's.
// The supplied filename contributes only a sanitized extension, so a hostile
// name can neither escape the directory nor choose where the bytes land.
func (s *Store) SaveFile(data []byte, filename string) (Result, error) {
	if len(data) == 0 {
		return Result{}, errors.New("empty file")
	}
	if len(data) > MaxFileBytes {
		return Result{}, fmt.Errorf("file is %d bytes, limit is %d", len(data), MaxFileBytes)
	}
	if err := os.MkdirAll(s.dir, 0o700); err != nil {
		return Result{}, err
	}
	s.prune()

	ext := safeExt(filename)
	var nonce [8]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return Result{}, err
	}
	name := fmt.Sprintf("pasted-%s-%s%s",
		time.Now().Format("20060102-150405"), hex.EncodeToString(nonce[:]), ext)
	path := filepath.Join(s.dir, name)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return Result{}, err
	}
	return Result{
		Path:   path,
		Text:   ShellQuote(path) + " ",
		Bytes:  len(data),
		Format: strings.TrimPrefix(ext, "."),
	}, nil
}

// safeExt returns a lowercase, dot-prefixed extension derived from filename, or
// "" when there isn't a safe one. The generated name uses it verbatim, so it is
// restricted to short runs of ASCII letters and digits — no dots, slashes, or
// anything that could reshape the path.
func safeExt(filename string) string {
	ext := strings.ToLower(filepath.Ext(filepath.Base(filename)))
	if len(ext) < 2 || len(ext) > 16 {
		return ""
	}
	for _, r := range ext[1:] {
		if !((r >= 'a' && r <= 'z') || (r >= '0' && r <= '9')) {
			return ""
		}
	}
	return ext
}

// prune deletes images past their retention. Best-effort and bounded: a paste
// should never fail because cleanup did.
func (s *Store) prune() {
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		return
	}
	cutoff := time.Now().Add(-retention)
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasPrefix(entry.Name(), "pasted-") {
			continue
		}
		info, err := entry.Info()
		if err != nil || info.ModTime().After(cutoff) {
			continue
		}
		_ = os.Remove(filepath.Join(s.dir, entry.Name()))
	}
}

// detectFormat identifies the image format from its content.
//
// http.DetectContentType covers png/jpeg/gif/webp; HEIC (what an iPhone camera
// produces by default) is not in its table, so it is sniffed from the ISO-BMFF
// brand directly.
func detectFormat(data []byte) (string, bool) {
	switch http.DetectContentType(data) {
	case "image/png":
		return "png", true
	case "image/jpeg":
		return "jpg", true
	case "image/gif":
		return "gif", true
	case "image/webp":
		return "webp", true
	}
	if isHEIC(data) {
		return "heic", true
	}
	return "", false
}

// isHEIC reports whether data is an ISO base media file with a HEIF/HEIC brand.
// Layout: [4-byte box size]["ftyp"][4-byte major brand].
func isHEIC(data []byte) bool {
	if len(data) < 12 || string(data[4:8]) != "ftyp" {
		return false
	}
	switch string(data[8:12]) {
	case "heic", "heix", "hevc", "hevx", "heim", "heis", "hevm", "hevs", "mif1", "msf1":
		return true
	}
	return false
}

// ShellQuote wraps a path in single quotes so it survives a shell prompt and an
// agent's own tokenizer intact.
//
// Paths generated here never contain anything that needs escaping, but the
// quoting is not conditional on that: it is what a local clipboard-image paste
// inserts, so keeping it identical means an agent that handles one handles the
// other.
func ShellQuote(path string) string {
	return "'" + strings.ReplaceAll(path, "'", `'\''`) + "'"
}
