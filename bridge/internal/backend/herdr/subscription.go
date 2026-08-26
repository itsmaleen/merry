package herdr

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"strings"
	"time"
)

// subscription is one open `events.subscribe` stream.
type subscription interface {
	readLine() ([]byte, error)
	close()
}

type socketSubscription struct {
	conn   net.Conn
	reader *bufio.Reader
}

func (s *socketSubscription) readLine() ([]byte, error) {
	line, err := s.reader.ReadBytes('\n')
	if err != nil {
		return nil, err
	}
	return line, nil
}

func (s *socketSubscription) close() { _ = s.conn.Close() }

// subscribedEvents is exactly what the pane cache consumes (see applyEvent).
// Agent status is NOT here: herdr emits it as `pane.agent_status_changed`,
// which must be subscribed per pane_id — see dialStatusSubscription.
var subscribedEvents = []string{
	"pane.created", "pane.updated", "pane.closed", "pane.moved",
}

// dialSubscription opens the lifecycle event stream and waits for herdr's
// subscription_started acknowledgement.
func (b *Backend) dialSubscription(ctx context.Context) (subscription, error) {
	subs := make([]map[string]any, 0, len(subscribedEvents))
	for _, t := range subscribedEvents {
		subs = append(subs, map[string]any{"type": t})
	}
	return b.dialSubscriptions(ctx, subs)
}

// dialStatusSubscription opens the agent-status stream for one pane. herdr
// scopes `pane.agent_status_changed` to a single pane_id per subscription
// (it probes the pane when the subscription starts), so the backend holds one
// of these per known pane.
func (b *Backend) dialStatusSubscription(ctx context.Context, paneID string) (subscription, error) {
	return b.dialSubscriptions(ctx, []map[string]any{
		{"type": "pane.agent_status_changed", "pane_id": paneID},
	})
}

func (b *Backend) dialSubscriptions(ctx context.Context, subs []map[string]any) (subscription, error) {
	req := map[string]any{
		"id":     "bridge:events",
		"method": "events.subscribe",
		"params": map[string]any{"subscriptions": subs},
	}
	payload, err := json.Marshal(req)
	if err != nil {
		return nil, err
	}

	var d net.Dialer
	conn, err := d.DialContext(ctx, "unix", b.cfg.SocketPath)
	if err != nil {
		return nil, fmt.Errorf("connect %s: %w", b.cfg.SocketPath, err)
	}
	_ = conn.SetDeadline(time.Now().Add(10 * time.Second))
	if _, err := fmt.Fprintf(conn, "%s\n", payload); err != nil {
		conn.Close()
		return nil, fmt.Errorf("write subscribe: %w", err)
	}
	reader := bufio.NewReaderSize(conn, 1<<20)
	line, err := reader.ReadString('\n')
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("read subscribe ack: %w", err)
	}
	var ack struct {
		Result struct {
			Type string `json:"type"`
		} `json:"result"`
		Error *rpcError `json:"error"`
	}
	if err := json.Unmarshal([]byte(strings.TrimSpace(line)), &ack); err != nil {
		conn.Close()
		return nil, fmt.Errorf("parse subscribe ack: %w (raw: %q)", err, snippet(line))
	}
	if ack.Error != nil {
		conn.Close()
		return nil, fmt.Errorf("subscribe: %w", ack.Error)
	}
	if ack.Result.Type != "subscription_started" {
		conn.Close()
		return nil, fmt.Errorf("subscribe: unexpected ack %q", snippet(line))
	}
	// The stream is open-ended from here on.
	_ = conn.SetDeadline(time.Time{})
	return &socketSubscription{conn: conn, reader: reader}, nil
}
