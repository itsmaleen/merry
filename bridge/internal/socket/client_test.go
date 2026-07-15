package socket

import (
	"bufio"
	"encoding/json"
	"net"
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
