package ws

import (
	"encoding/json"
	"log"
	"net/http"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
	"github.com/itsmaleen/cmux-companion/bridge/internal/poller"
	"github.com/itsmaleen/cmux-companion/bridge/internal/socket"
)

const bridgeVersion = "0.1.0"

type pushMessage struct {
	Type string `json:"type"`
	Data any    `json:"data"`
}

type commandRequest struct {
	ID     string         `json:"id"`
	Method string         `json:"method"`
	Params map[string]any `json:"params"`
}

type commandResponse struct {
	ID     string          `json:"id"`
	OK     bool            `json:"ok"`
	Result json.RawMessage `json:"result,omitempty"`
	Error  *rpcError       `json:"error,omitempty"`
}

type rpcError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// handleClient manages a single WebSocket connection for its lifetime.
// It pushes notification events and proxies commands to the cmux socket.
func handleClient(
	w http.ResponseWriter,
	r *http.Request,
	token string,
	poll *poller.Poller,
	cmuxClient *socket.Client,
	cmuxConnected func() bool,
) {
	if !validateBearer(r, token) {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		InsecureSkipVerify: true, // LAN only; origins vary
	})
	if err != nil {
		log.Printf("ws: accept error: %v", err)
		return
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	ctx := r.Context()

	// Send initial connected event
	_ = wsjson.Write(ctx, conn, pushMessage{
		Type: "connected",
		Data: map[string]any{
			"bridge_version":   bridgeVersion,
			"cmux_connected":   cmuxConnected(),
			"protocol_version": 1,
		},
	})

	// Subscribe to poller events. The channel is never closed by Unsubscribe —
	// the handler exits via ctx cancellation or incoming closing.
	events := poll.Subscribe()
	defer poll.Unsubscribe(events)

	// Channel for incoming commands from the client
	incoming := make(chan commandRequest, 8)

	// Read loop: decode incoming commands and forward to incoming channel
	go func() {
		defer close(incoming)
		for {
			var cmd commandRequest
			if err := wsjson.Read(ctx, conn, &cmd); err != nil {
				return
			}
			select {
			case incoming <- cmd:
			case <-ctx.Done():
				return
			}
		}
	}()

	for {
		select {
		case <-ctx.Done():
			return

		case ev := <-events:
			if err := wsjson.Write(ctx, conn, pushMessage{
				Type: ev.Type,
				Data: ev.Data,
			}); err != nil {
				return
			}

		case cmd, ok := <-incoming:
			if !ok {
				return
			}
			resp := proxyCommand(cmd, cmuxClient, poll)
			if err := wsjson.Write(ctx, conn, resp); err != nil {
				return
			}
		}
	}
}

func proxyCommand(cmd commandRequest, client *socket.Client, poll *poller.Poller) commandResponse {
	result, err := client.Send(cmd.Method, cmd.Params)
	if err != nil {
		return commandResponse{
			ID: cmd.ID,
			OK: false,
			Error: &rpcError{
				Code:    "proxy_error",
				Message: err.Error(),
			},
		}
	}

	// After a successful notification.clear, reset the poller's seen-ID set
	// so re-appearing notifications get pushed again.
	if cmd.Method == "notification.clear" {
		poll.ResetSeenIDs()
	}

	return commandResponse{
		ID:     cmd.ID,
		OK:     true,
		Result: result,
	}
}
