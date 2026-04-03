package ws

import (
	"context"
	"fmt"
	"net"
	"net/http"

	"github.com/itsmaleen/cmux-companion/bridge/internal/poller"
	"github.com/itsmaleen/cmux-companion/bridge/internal/socket"
)

// Server is the WebSocket HTTP server.
type Server struct {
	token         string
	poll          *poller.Poller
	cmuxClient    *socket.Client
	cmuxConnected func() bool
	httpServer    *http.Server
}

func NewServer(
	token string,
	poll *poller.Poller,
	cmuxClient *socket.Client,
	cmuxConnected func() bool,
) *Server {
	s := &Server{
		token:         token,
		poll:          poll,
		cmuxClient:    cmuxClient,
		cmuxConnected: cmuxConnected,
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/ws", s.wsHandler)

	s.httpServer = &http.Server{Handler: mux}
	return s
}

func (s *Server) wsHandler(w http.ResponseWriter, r *http.Request) {
	handleClient(w, r, s.token, s.poll, s.cmuxClient, s.cmuxConnected)
}

// ListenAndServe binds to addr (e.g. ":47821") and serves until ctx is cancelled.
func (s *Server) ListenAndServe(ctx context.Context, addr string) error {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return fmt.Errorf("listen %s: %w", addr, err)
	}

	errCh := make(chan error, 1)
	go func() {
		errCh <- s.httpServer.Serve(ln)
	}()

	select {
	case <-ctx.Done():
		_ = s.httpServer.Shutdown(context.Background())
		return nil
	case err := <-errCh:
		return err
	}
}
