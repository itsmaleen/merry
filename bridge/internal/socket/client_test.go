package socket

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// fakeCmux is a minimal Unix-socket server that speaks one request/response
// per connection line, letting the test drive Client.Send end to end.
type fakeCmux struct {
	t        *testing.T
	ln       net.Listener
	mu       sync.Mutex
	requests []map[string]any // every request line the server parsed
	respond  func(req map[string]any) string
}

func startFakeCmux(t *testing.T, respond func(map[string]any) string) *fakeCmux {
	t.Helper()
	path := filepath.Join(t.TempDir(), "cmux.sock")
	ln, err := net.Listen("unix", path)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	f := &fakeCmux{t: t, ln: ln, respond: respond}
	go f.serve()
	return f
}

func (f *fakeCmux) path() string { return f.ln.Addr().String() }

func (f *fakeCmux) serve() {
	for {
		conn, err := f.ln.Accept()
		if err != nil {
			return
		}
		go func(c net.Conn) {
			defer c.Close()
			r := bufio.NewReader(c)
			for {
				// One ReadString per request. If the client ever let an
				// unescaped newline into the payload, this would split a single
				// request across two iterations and the second parse would fail.
				line, err := r.ReadString('\n')
				if err != nil {
					return
				}
				var req map[string]any
				if err := json.Unmarshal([]byte(strings.TrimSpace(line)), &req); err != nil {
					return
				}
				f.mu.Lock()
				f.requests = append(f.requests, req)
				f.mu.Unlock()
				if _, err := c.Write([]byte(f.respond(req) + "\n")); err != nil {
					return
				}
			}
		}(conn)
	}
}

func (f *fakeCmux) requestCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.requests)
}

func TestSendHappyPath(t *testing.T) {
	f := startFakeCmux(t, func(req map[string]any) string {
		return `{"id":"` + req["id"].(string) + `","ok":true,"result":{"text":"hello"}}`
	})
	defer f.ln.Close()

	c := NewClient(f.path(), "")
	if err := c.Connect(); err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer c.Close()

	res, err := c.Send("surface.read_text", map[string]any{"surface_id": "s1"})
	if err != nil {
		t.Fatalf("send: %v", err)
	}
	var parsed struct {
		Text string `json:"text"`
	}
	if err := json.Unmarshal(res, &parsed); err != nil {
		t.Fatalf("unmarshal result: %v", err)
	}
	if parsed.Text != "hello" {
		t.Fatalf("got %q, want hello", parsed.Text)
	}
}

func TestSendServerError(t *testing.T) {
	f := startFakeCmux(t, func(req map[string]any) string {
		return `{"id":"` + req["id"].(string) + `","ok":false,"error":{"code":"E_NO","message":"nope"}}`
	})
	defer f.ln.Close()

	c := NewClient(f.path(), "")
	if err := c.Connect(); err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer c.Close()

	if _, err := c.Send("whatever", nil); err == nil {
		t.Fatal("expected error from ok:false response")
	} else if !strings.Contains(err.Error(), "nope") {
		t.Fatalf("error %q missing server message", err)
	}
}

// A parameter value containing a newline must not let a client inject a second
// JSON-RPC line into the socket stream — json.Marshal has to escape it. The
// server asserts it saw exactly one request line and that the newline survived
// intact inside the value.
func TestSendNewlineParamIsEscaped(t *testing.T) {
	f := startFakeCmux(t, func(req map[string]any) string {
		params, _ := req["params"].(map[string]any)
		if got, _ := params["text"].(string); got != "line1\nline2" {
			t.Errorf("param text = %q, want the two-line value intact", got)
		}
		return `{"id":"` + req["id"].(string) + `","ok":true,"result":{}}`
	})
	defer f.ln.Close()

	c := NewClient(f.path(), "")
	if err := c.Connect(); err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer c.Close()

	if _, err := c.Send("surface.send_text", map[string]any{"text": "line1\nline2"}); err != nil {
		t.Fatalf("send: %v", err)
	}
	if n := f.requestCount(); n != 1 {
		t.Fatalf("server saw %d request lines, want 1 (newline leaked a second line)", n)
	}
}

func TestSendNotConnected(t *testing.T) {
	c := NewClient("/nonexistent/path.sock", "")
	if _, err := c.Send("x", nil); err == nil {
		t.Fatal("expected 'not connected' error before Connect")
	}
}

func TestDetectSocketPath(t *testing.T) {
	const uid = 501

	// mkSocket creates a stand-in for a live socket. detectSocketPath only
	// os.Stat's the path, so a regular file is indistinguishable from a real
	// unix socket here — and it avoids the ~104-char sun_path limit that a real
	// socket under t.TempDir() could blow.
	mkSocket := func(t *testing.T, path string) {
		t.Helper()
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, nil, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	writePointer := func(t *testing.T, path, target string) {
		t.Helper()
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(target+"\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	xdgDir := func(home string) string { return filepath.Join(home, ".local", "state", "cmux") }
	appDir := func(home string) string { return filepath.Join(home, "Library", "Application Support", "cmux") }

	tests := []struct {
		name string
		// setup populates the fake home tree and returns the path we expect
		// detectSocketPath to resolve to.
		setup func(t *testing.T, home string) string
	}{
		{
			name: "xdg pointer to live socket (the Mac mini case)",
			setup: func(t *testing.T, home string) string {
				sock := filepath.Join(xdgDir(home), "cmux.sock")
				mkSocket(t, sock)
				writePointer(t, filepath.Join(xdgDir(home), "last-socket-path"), sock)
				return sock
			},
		},
		{
			name: "app support pointer to live uid-suffixed socket",
			setup: func(t *testing.T, home string) string {
				sock := filepath.Join(xdgDir(home), fmt.Sprintf("cmux-%d.sock", uid))
				mkSocket(t, sock)
				writePointer(t, filepath.Join(appDir(home), "last-socket-path"), sock)
				return sock
			},
		},
		{
			name: "live socket beats a stale pointer",
			setup: func(t *testing.T, home string) string {
				// XDG pointer names a socket that doesn't exist...
				writePointer(t, filepath.Join(xdgDir(home), "last-socket-path"), filepath.Join(xdgDir(home), "gone.sock"))
				// ...while the App Support pointer names a live one.
				sock := filepath.Join(appDir(home), "cmux.sock")
				mkSocket(t, sock)
				writePointer(t, filepath.Join(appDir(home), "last-socket-path"), sock)
				return sock
			},
		},
		{
			name: "no pointer, plain cmux.sock in xdg",
			setup: func(t *testing.T, home string) string {
				sock := filepath.Join(xdgDir(home), "cmux.sock")
				mkSocket(t, sock)
				return sock
			},
		},
		{
			name: "no pointer, uid-suffixed preferred over plain",
			setup: func(t *testing.T, home string) string {
				suffixed := filepath.Join(xdgDir(home), fmt.Sprintf("cmux-%d.sock", uid))
				mkSocket(t, suffixed)
				mkSocket(t, filepath.Join(xdgDir(home), "cmux.sock"))
				return suffixed
			},
		},
		{
			name: "stale pointer, no live socket, returns pointer not /tmp",
			setup: func(t *testing.T, home string) string {
				target := filepath.Join(xdgDir(home), "cmux.sock") // referenced but never created
				writePointer(t, filepath.Join(xdgDir(home), "last-socket-path"), target)
				return target
			},
		},
		{
			name: "nothing present falls back to /tmp",
			setup: func(t *testing.T, home string) string {
				return "/tmp/cmux.sock"
			},
		},
		{
			name: "xdg pointer preferred over app support pointer",
			setup: func(t *testing.T, home string) string {
				xdgSock := filepath.Join(xdgDir(home), "cmux.sock")
				appSock := filepath.Join(appDir(home), "cmux.sock")
				mkSocket(t, xdgSock)
				mkSocket(t, appSock)
				writePointer(t, filepath.Join(xdgDir(home), "last-socket-path"), xdgSock)
				writePointer(t, filepath.Join(appDir(home), "last-socket-path"), appSock)
				return xdgSock
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			home := t.TempDir()
			want := tt.setup(t, home)
			if got := detectSocketPath(home, uid); got != want {
				t.Fatalf("detectSocketPath = %q, want %q", got, want)
			}
		})
	}
}
