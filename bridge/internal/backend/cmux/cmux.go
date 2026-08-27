// Package cmux is the cmux backend: the phone vocabulary is cmux's own socket
// API, so commands are proxied verbatim, notifications come from polling
// cmux's notification.list, and Claude transcripts are bound through cmux's
// hook session store.
package cmux

import (
	"context"
	"encoding/json"
	"log"
	"strings"
	"sync/atomic"
	"time"

	"github.com/itsmaleen/merry/bridge/internal/backend"
	"github.com/itsmaleen/merry/bridge/internal/claude"
	"github.com/itsmaleen/merry/bridge/internal/poller"
	"github.com/itsmaleen/merry/bridge/internal/socket"
)

// Config selects the cmux socket.
type Config struct {
	SocketPath   string
	Password     string
	PollInterval time.Duration
	// BridgeVersion is reported in the backend.connected event.
	BridgeVersion string
}

// Backend implements backend.Backend over cmux's Unix socket.
type Backend struct {
	cfg       Config
	client    *socket.Client
	hub       *backend.Hub
	poll      *poller.Poller
	resolver  *claude.Resolver
	connected atomic.Bool
}

// New builds a cmux backend. It does not connect; Run does.
func New(cfg Config) *Backend {
	if cfg.PollInterval <= 0 {
		cfg.PollInterval = time.Second
	}
	hub := backend.NewHub()
	client := socket.NewClient(cfg.SocketPath, cfg.Password)
	return &Backend{
		cfg:      cfg,
		client:   client,
		hub:      hub,
		poll:     poller.New(client, cfg.PollInterval, hub),
		resolver: claude.NewResolver(),
	}
}

func (b *Backend) Info() backend.Info {
	return backend.Info{
		Kind: "cmux",
		Capabilities: backend.Capabilities{
			Browser:       true,
			AgentStatus:   false,
			Notifications: "polled",
		},
	}
}

func (b *Backend) Hub() *backend.Hub { return b.hub }

func (b *Backend) Connected() bool { return b.connected.Load() }

// Ping opens a one-off connection and round-trips system.ping, so a socket
// that accepts connections but rejects every RPC (wrong uid, wrong password)
// is caught here rather than left flapping in the daemon.
func (b *Backend) Ping() error {
	client := socket.NewClient(b.cfg.SocketPath, b.cfg.Password)
	if err := client.Connect(); err != nil {
		return err
	}
	defer client.Close()
	_, err := client.Send("system.ping", nil)
	return err
}

// IsAuthRequired reports whether err is cmux saying the socket needs a
// password.
func IsAuthRequired(err error) bool {
	if err == nil {
		return false
	}
	s := err.Error()
	return strings.Contains(s, "auth_required") || strings.Contains(s, "Authentication required")
}

// Run keeps the socket connected with exponential backoff and a 5s ping,
// publishing backend.connected / backend.disconnected on transitions. It also
// drives the notification poller.
func (b *Backend) Run(ctx context.Context) {
	stopPoller := make(chan struct{})
	go func() {
		<-ctx.Done()
		close(stopPoller)
	}()
	go b.poll.Run(stopPoller)

	backoff := time.Second
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		if err := b.client.Connect(); err != nil {
			log.Printf("cmux: connect error: %v (retry in %s)", err, backoff)
			b.setConnected(false, "socket_unavailable")
			select {
			case <-ctx.Done():
				return
			case <-time.After(backoff):
			}
			if backoff < 30*time.Second {
				backoff *= 2
			}
			continue
		}

		log.Printf("cmux: connected")
		backoff = time.Second
		b.setConnected(true, "")

	pingLoop:
		for {
			select {
			case <-ctx.Done():
				return
			case <-time.After(5 * time.Second):
				if _, err := b.client.Send("system.ping", nil); err != nil {
					log.Printf("cmux: connection lost: %v", err)
					b.setConnected(false, "socket_unavailable")
					break pingLoop
				}
			}
		}
	}
}

func (b *Backend) setConnected(up bool, reason string) {
	if b.connected.Swap(up) == up {
		return
	}
	if up {
		b.hub.Broadcast(backend.Event{
			Type: "backend.connected",
			Data: map[string]any{"backend": "cmux", "bridge_version": b.cfg.BridgeVersion},
		})
	} else {
		b.hub.Broadcast(backend.Event{
			Type: "backend.disconnected",
			Data: map[string]any{"backend": "cmux", "reason": reason},
		})
	}
}

// Handle proxies every command to cmux except the bridge-local transcript
// read, and resets the poller's seen set after a successful notification.clear
// so re-appearing notifications get pushed again.
func (b *Backend) Handle(method string, params map[string]any) (json.RawMessage, error) {
	switch method {
	case "claude.transcript", "agent.transcript":
		return b.transcript(params)
	}

	result, err := b.client.Send(method, params)
	if err != nil {
		return nil, backend.Errorf("proxy_error", err.Error())
	}
	if method == "notification.clear" {
		b.poll.ResetSeenIDs()
	}
	return result, nil
}

func (b *Backend) transcript(params map[string]any) (json.RawMessage, error) {
	surfaceID, _ := params["surface_id"].(string)

	// Build surface.list params, forwarding workspace_id if provided.
	listParams := map[string]any{}
	if wsID, ok := params["workspace_id"]; ok {
		listParams["workspace_id"] = wsID
	}

	listResult, err := b.client.Send("surface.list", listParams)
	if err != nil {
		return nil, backend.Errorf("transcript_error", err.Error())
	}

	var listPayload struct {
		Surfaces []map[string]any `json:"surfaces"`
	}
	if err := json.Unmarshal(listResult, &listPayload); err != nil {
		return nil, backend.Errorf("transcript_error", "parse surface.list: "+err.Error())
	}

	var resumeBinding map[string]any
	for _, s := range listPayload.Surfaces {
		if id, _ := s["id"].(string); id == surfaceID {
			resumeBinding, _ = s["resume_binding"].(map[string]any)
			break
		}
	}

	res, err := b.resolver.Render(claude.Request{
		SurfaceID:        surfaceID,
		ResumeBinding:    resumeBinding,
		MaxMessages:      MaxMessages(params),
		KnownFingerprint: KnownFingerprint(params),
	})
	if err != nil {
		return nil, backend.Errorf("transcript_error", err.Error())
	}
	return TranscriptResult(res), nil
}

// MaxMessages reads and bounds the client-supplied message limit.
func MaxMessages(params map[string]any) int {
	maxMessages := 200
	if v, ok := params["max_messages"].(float64); ok && v > 0 {
		maxMessages = int(v)
		if maxMessages > 2000 {
			maxMessages = 2000 // bound client-supplied work
		}
	}
	return maxMessages
}

// KnownFingerprint reads the fingerprint the client already holds.
func KnownFingerprint(params map[string]any) string {
	s, _ := params["known_fingerprint"].(string)
	return s
}

// TranscriptResult encodes a resolver result in the wire shape shared by every
// backend's transcript command.
func TranscriptResult(res claude.Result) json.RawMessage {
	result, _ := json.Marshal(map[string]any{
		"supported":       res.Supported,
		"text":            res.Text,
		"session_id":      res.SessionID,
		"session_missing": res.SessionMissing,
		// Hand back on the next poll as known_fingerprint: an unchanged
		// transcript then answers without re-reading or re-sending it.
		"fingerprint": res.Fingerprint,
		"unchanged":   res.Unchanged,
		"source":      res.Source,
	})
	return result
}
