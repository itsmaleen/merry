package ws

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
	"github.com/itsmaleen/cmux-companion/bridge/internal/backend"
)

const bridgeVersion = "0.2.0"

// protocolVersion 2 adds `backend`, `backend_connected` and `capabilities` to
// the connected payload, renames cmux.connected/disconnected to
// backend.connected/disconnected, and introduces surface.updated.
const protocolVersion = 2

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
// It pushes backend events and dispatches commands to the backend.
func handleClient(w http.ResponseWriter, r *http.Request, token string, be backend.Backend) {
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

	// Subscribe to backend events BEFORE reading the connection snapshot, so a
	// transition between the two can't be missed: the snapshot says "up", the
	// backend drops, and the subscription started too late to hear it. The
	// channel is never closed by Unsubscribe — the handler exits via ctx
	// cancellation or incoming closing.
	hub := be.Hub()
	events := hub.Subscribe()
	defer hub.Unsubscribe(events)

	info := be.Info()
	connected := be.Connected()
	// Send initial connected event. cmux_connected is kept for phones that
	// predate protocol 2.
	_ = wsjson.Write(ctx, conn, pushMessage{
		Type: "connected",
		Data: map[string]any{
			"bridge_version":    bridgeVersion,
			"protocol_version":  protocolVersion,
			"backend":           info.Kind,
			"backend_connected": connected,
			"cmux_connected":    connected,
			"capabilities":      info.Capabilities,
		},
	})

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
			if err := wsjson.Write(ctx, conn, dispatch(cmd, be)); err != nil {
				return
			}
		}
	}
}

// dispatch runs one command against the backend and shapes the response.
func dispatch(cmd commandRequest, be backend.Backend) commandResponse {
	result, err := be.Handle(cmd.Method, cmd.Params)
	if err != nil {
		code := "proxy_error"
		var berr *backend.Error
		if errors.As(err, &berr) {
			code = berr.Code
			return commandResponse{ID: cmd.ID, OK: false, Error: &rpcError{Code: code, Message: berr.Message}}
		}
		return commandResponse{ID: cmd.ID, OK: false, Error: &rpcError{Code: code, Message: err.Error()}}
	}
	return commandResponse{ID: cmd.ID, OK: true, Result: result}
}
