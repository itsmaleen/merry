package ws

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"sync"
	"time"

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

	s.httpServer = &http.Server{
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
	}
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
	return s.Serve(ctx, ln)
}

// Serve serves on the given listeners until ctx is cancelled.
// All listeners share the same HTTP handler and auth token.
func (s *Server) Serve(ctx context.Context, listeners ...net.Listener) error {
	var wg sync.WaitGroup
	errCh := make(chan error, len(listeners))

	for _, ln := range listeners {
		wg.Add(1)
		go func(l net.Listener) {
			defer wg.Done()
			if err := s.httpServer.Serve(l); err != http.ErrServerClosed {
				errCh <- err
			}
		}(ln)
	}

	select {
	case <-ctx.Done():
		_ = s.httpServer.Shutdown(context.Background())
		wg.Wait()
		return nil
	case err := <-errCh:
		_ = s.httpServer.Shutdown(context.Background())
		wg.Wait()
		return err
	}
}
