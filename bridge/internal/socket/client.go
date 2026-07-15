package socket

import (
	"bufio"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Client is a persistent connection to the cmux Unix socket.
// It serialises all sends with a mutex so callers can share one instance.
type Client struct {
	socketPath string
	password   string

	mu     sync.Mutex
	conn   net.Conn
	reader *bufio.Reader
}

func NewClient(socketPath, password string) *Client {
	return &Client{socketPath: socketPath, password: password}
}

// Connect establishes (or re-establishes) the connection and authenticates.
func (c *Client) Connect() error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.conn != nil {
		c.conn.Close()
		c.conn = nil
		c.reader = nil
	}

	conn, err := net.Dial("unix", c.socketPath)
	if err != nil {
		return fmt.Errorf("connect %s: %w", c.socketPath, err)
	}

	if c.password != "" {
		if err := authenticate(conn, c.password); err != nil {
			conn.Close()
			return fmt.Errorf("auth: %w", err)
		}
	}

	c.conn = conn
	c.reader = bufio.NewReaderSize(conn, 1<<20)
	return nil
}

// Close shuts down the underlying connection.
func (c *Client) Close() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.conn != nil {
		c.conn.Close()
		c.conn = nil
	}
}

// Send sends a v2 JSON-RPC request and returns the parsed result object.
// If the connection is closed it returns an error; the caller is responsible
// for reconnecting.
func (c *Client) Send(method string, params map[string]any) (json.RawMessage, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.conn == nil {
		return nil, fmt.Errorf("not connected")
	}

	id := randomHex(8)
	req := map[string]any{
		"id":     id,
		"method": method,
		"params": params,
	}
	if params == nil {
		req["params"] = map[string]any{}
	}

	payload, err := json.Marshal(req)
	if err != nil {
		return nil, fmt.Errorf("marshal: %w", err)
	}

	_ = c.conn.SetDeadline(time.Now().Add(10 * time.Second))
	if _, err := fmt.Fprintf(c.conn, "%s\n", payload); err != nil {
		c.conn = nil
		c.reader = nil
		return nil, fmt.Errorf("write: %w", err)
	}

	line, err := c.reader.ReadString('\n')
	if err != nil {
		c.conn = nil
		c.reader = nil
		return nil, fmt.Errorf("read: %w", err)
	}
	if len(line) > 8<<20 {
		c.conn = nil
		c.reader = nil
		return nil, fmt.Errorf("response line too large: %d bytes", len(line))
	}
	_ = c.conn.SetDeadline(time.Time{})

	var resp struct {
		OK     bool            `json:"ok"`
		Result json.RawMessage `json:"result"`
		Error  *struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal([]byte(strings.TrimSpace(line)), &resp); err != nil {
		return nil, fmt.Errorf("parse response: %w", err)
	}
	if !resp.OK {
		if resp.Error != nil {
			return nil, fmt.Errorf("[%s] %s", resp.Error.Code, resp.Error.Message)
		}
		return nil, fmt.Errorf("server returned error")
	}
	return resp.Result, nil
}

// DetectSocketPath returns the best available cmux socket path by reading
// the last-socket-path file written by the cmux Mac app, with fallbacks.
func DetectSocketPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return "/tmp/cmux.sock"
	}

	appSupport := filepath.Join(home, "Library", "Application Support", "cmux")

	// Primary: last-socket-path written by cmux on each launch
	if data, err := os.ReadFile(filepath.Join(appSupport, "last-socket-path")); err == nil {
		if p := strings.TrimSpace(string(data)); p != "" {
			return p
		}
	}

	// XDG state directory (cmux v2+)
	xdgState := filepath.Join(home, ".local", "state", "cmux",
		fmt.Sprintf("cmux-%d.sock", os.Getuid()))
	if _, err := os.Stat(xdgState); err == nil {
		return xdgState
	}

	// Stable default (legacy Application Support)
	stable := filepath.Join(appSupport, "cmux.sock")
	if _, err := os.Stat(stable); err == nil {
		return stable
	}

	// Legacy fallback
	return "/tmp/cmux.sock"
}

func authenticate(conn net.Conn, password string) error {
	_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
	defer func() { _ = conn.SetDeadline(time.Time{}) }()

	id := randomHex(8)
	req := map[string]any{
		"id":     id,
		"method": "auth.login",
		"params": map[string]any{"password": password},
	}
	payload, _ := json.Marshal(req)
	if _, err := fmt.Fprintf(conn, "%s\n", payload); err != nil {
		return fmt.Errorf("send auth.login: %w", err)
	}

	reader := bufio.NewReader(conn)
	line, err := reader.ReadString('\n')
	if err != nil {
		return fmt.Errorf("read auth response: %w", err)
	}

	var resp struct {
		OK    bool `json:"ok"`
		Error *struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal([]byte(strings.TrimSpace(line)), &resp); err != nil {
		return fmt.Errorf("parse auth response: %w", err)
	}
	if !resp.OK {
		if resp.Error != nil {
			return fmt.Errorf("[%s] %s", resp.Error.Code, resp.Error.Message)
		}
		return fmt.Errorf("authentication failed")
	}
	return nil
}

func randomHex(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}
