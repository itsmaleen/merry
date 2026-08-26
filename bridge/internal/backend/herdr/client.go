package herdr

import (
	"bufio"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// maxResponseBytes bounds one response line. A deep pane.read of a busy
// scrollback is a few hundred KiB; anything approaching this is a broken peer.
const maxResponseBytes = 64 << 20

// herdr's socket API is newline-delimited JSON over a Unix socket. The server
// answers one request per connection and closes it (its own CLI dials per
// call), so Client dials per request too; only event subscriptions hold a
// connection open, and those are driven directly by the backend's event loop.
type client struct {
	socketPath string
	timeout    time.Duration
}

// rpcError is herdr's `error` object.
type rpcError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (e *rpcError) Error() string { return "[" + e.Code + "] " + e.Message }

// call sends one request and returns its `result` object.
func (c *client) call(method string, params any) (json.RawMessage, error) {
	if params == nil {
		params = map[string]any{}
	}
	req := map[string]any{"id": "bridge:" + randomHex(6), "method": method, "params": params}
	payload, err := json.Marshal(req)
	if err != nil {
		return nil, fmt.Errorf("marshal: %w", err)
	}

	conn, err := net.DialTimeout("unix", c.socketPath, c.timeout)
	if err != nil {
		return nil, fmt.Errorf("connect %s: %w", c.socketPath, err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(c.timeout))

	if _, err := fmt.Fprintf(conn, "%s\n", payload); err != nil {
		return nil, fmt.Errorf("write: %w", err)
	}
	line, err := bufio.NewReaderSize(io.LimitReader(conn, maxResponseBytes), 1<<20).ReadString('\n')
	if err != nil && line == "" {
		return nil, fmt.Errorf("read: %w", err)
	}
	if err != nil && !strings.HasSuffix(line, "\n") {
		return nil, fmt.Errorf("read: response exceeds %d bytes or was cut short: %w", maxResponseBytes, err)
	}
	return parseResponse(line)
}

func parseResponse(line string) (json.RawMessage, error) {
	var resp struct {
		Result json.RawMessage `json:"result"`
		Error  *rpcError       `json:"error"`
	}
	if err := json.Unmarshal([]byte(strings.TrimSpace(line)), &resp); err != nil {
		return nil, fmt.Errorf("parse response: %w (raw: %q)", err, snippet(line))
	}
	if resp.Error != nil {
		return nil, resp.Error
	}
	if resp.Result == nil {
		return nil, fmt.Errorf("response has neither result nor error (raw: %q)", snippet(line))
	}
	return resp.Result, nil
}

// callInto is call plus decoding of the result into out.
func (c *client) callInto(method string, params any, out any) error {
	raw, err := c.call(method, params)
	if err != nil {
		return err
	}
	if err := json.Unmarshal(raw, out); err != nil {
		return fmt.Errorf("decode %s result: %w", method, err)
	}
	return nil
}

func snippet(line string) string {
	s := strings.TrimSpace(line)
	const max = 160
	if len(s) > max {
		return s[:max] + "…"
	}
	return s
}

func randomHex(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// DefaultSocketPath is where herdr's default session listens, honouring the
// same overrides herdr's own CLI does: HERDR_SOCKET_PATH, then HERDR_SESSION
// (a named session), then ~/.config/herdr/herdr.sock.
func DefaultSocketPath() string {
	if p := os.Getenv("HERDR_SOCKET_PATH"); p != "" {
		return p
	}
	return SocketPathForSession(os.Getenv("HERDR_SESSION"))
}

// SocketPathForSession returns the socket of a named herdr session, or the
// default session's when name is empty or "default" (herdr's reserved name for
// the un-nested default session). The config dir follows herdr's own rule:
// $XDG_CONFIG_HOME/herdr when set, else ~/.config/herdr.
func SocketPathForSession(name string) string {
	base := configDir()
	if name == "" || name == "default" {
		return filepath.Join(base, "herdr.sock")
	}
	return filepath.Join(base, "sessions", name, "herdr.sock")
}

func configDir() string {
	if xdg := os.Getenv("XDG_CONFIG_HOME"); xdg != "" {
		return filepath.Join(xdg, "herdr")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		home = "/tmp"
	}
	return filepath.Join(home, ".config", "herdr")
}
