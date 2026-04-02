package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/manaflow-ai/cmux-companion/bridge/internal/mdns"
	"github.com/manaflow-ai/cmux-companion/bridge/internal/pair"
	"github.com/manaflow-ai/cmux-companion/bridge/internal/poller"
	"github.com/manaflow-ai/cmux-companion/bridge/internal/socket"
	"github.com/manaflow-ai/cmux-companion/bridge/internal/ws"
)

const (
	defaultPort         = 47821
	defaultPollInterval = 1000
	configDirName       = "cmux-bridge"
	configFileName      = "config.json"
)

type config struct {
	SocketPath     string `json:"socket_path"`
	SocketPassword string `json:"socket_password"`
	BridgePort     int    `json:"bridge_port"`
	PollIntervalMs int    `json:"poll_interval_ms"`
}

func defaultConfig() config {
	return config{
		SocketPath:     "",
		SocketPassword: "",
		BridgePort:     defaultPort,
		PollIntervalMs: defaultPollInterval,
	}
}

func configDir() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return filepath.Join("/tmp", configDirName)
	}
	return filepath.Join(home, ".config", configDirName)
}

func loadConfig(dir string) (config, error) {
	cfg := defaultConfig()
	path := filepath.Join(dir, configFileName)
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return cfg, nil
	}
	if err != nil {
		return cfg, fmt.Errorf("read config: %w", err)
	}
	if err := json.Unmarshal(data, &cfg); err != nil {
		return cfg, fmt.Errorf("parse config: %w", err)
	}
	return cfg, nil
}

func saveConfig(dir string, cfg config) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(dir, configFileName), append(data, '\n'), 0o600)
}

func main() {
	pairMode := flag.Bool("pair", false, "generate QR code for iOS pairing and exit")
	flag.Parse()

	dir := configDir()
	cfg, err := loadConfig(dir)
	if err != nil {
		log.Fatalf("config: %v", err)
	}

	// Resolve socket path
	if cfg.SocketPath == "" {
		cfg.SocketPath = socket.DetectSocketPath()
	}

	if *pairMode {
		runPair(dir, cfg)
		return
	}

	runDaemon(dir, cfg)
}

// runPair handles --pair: connect to cmux (prompting for password if needed),
// display the QR code, and exit.
func runPair(dir string, cfg config) {
	// Prompt for password if not configured
	if cfg.SocketPassword == "" {
		fmt.Print("cmux socket password (leave empty if not using password mode): ")
		var pw string
		_, _ = fmt.Scanln(&pw)
		if pw != "" {
			cfg.SocketPassword = pw
			if err := saveConfig(dir, cfg); err != nil {
				log.Printf("warning: could not save config: %v", err)
			} else {
				fmt.Println("Password saved to config.")
			}
		}
	}

	// Verify connectivity
	client := socket.NewClient(cfg.SocketPath, cfg.SocketPassword)
	if err := client.Connect(); err != nil {
		log.Fatalf("cannot connect to cmux socket: %v\nMake sure cmux is running and the socket path is correct (%s)", err, cfg.SocketPath)
	}
	client.Close()
	fmt.Println("Connected to cmux.")

	token, err := pair.LoadOrCreateToken(dir)
	if err != nil {
		log.Fatalf("token: %v", err)
	}

	if err := pair.PrintQR("", cfg.BridgePort, token); err != nil {
		log.Fatalf("qr: %v", err)
	}
}

// runDaemon starts the bridge in daemon mode with reconnect loop.
func runDaemon(dir string, cfg config) {
	if cfg.SocketPassword == "" {
		// Probe the socket; if it responds with auth_required, fail fast
		client := socket.NewClient(cfg.SocketPath, "")
		if err := client.Connect(); err != nil {
			// Connection error — could be socket not running, fail with helpful message
			log.Fatalf("cannot connect to cmux socket at %s: %v\nRun with --pair to configure", cfg.SocketPath, err)
		}
		_, probeErr := client.Send("system.ping", nil)
		client.Close()
		if probeErr != nil && isAuthRequired(probeErr) {
			log.Fatalf("cmux socket requires a password but none is configured.\nRun with --pair to configure the password.")
		}
	}

	token, err := pair.LoadOrCreateToken(dir)
	if err != nil {
		log.Fatalf("token: %v", err)
	}

	log.Printf("cmux-bridge %s starting on port %d", ws.BridgeVersion(), cfg.BridgePort)
	log.Printf("socket: %s", cfg.SocketPath)

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	cmuxClient := socket.NewClient(cfg.SocketPath, cfg.SocketPassword)
	cmuxConnectedFlag := false

	poll := poller.New(cmuxClient, time.Duration(cfg.PollIntervalMs)*time.Millisecond)

	stopPoller := make(chan struct{})
	go func() {
		<-ctx.Done()
		close(stopPoller)
	}()
	go poll.Run(stopPoller)

	// Reconnect loop — also broadcasts cmux.connected / cmux.disconnected to WS clients.
	go func() {
		backoff := time.Second
		for {
			select {
			case <-ctx.Done():
				return
			default:
			}

			err := cmuxClient.Connect()
			if err != nil {
				log.Printf("cmux: connect error: %v (retry in %s)", err, backoff)
				if cmuxConnectedFlag {
					cmuxConnectedFlag = false
					poll.Broadcast(poller.Event{
						Type: "cmux.disconnected",
						Data: map[string]any{"reason": "socket_unavailable"},
					})
				}
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
			cmuxConnectedFlag = true
			poll.Broadcast(poller.Event{
				Type: "cmux.connected",
				Data: map[string]any{"bridge_version": ws.BridgeVersion()},
			})

			// Wait until connection drops (Send will return error)
		pingLoop:
			for {
				select {
				case <-ctx.Done():
					return
				case <-time.After(5 * time.Second):
					if _, err := cmuxClient.Send("system.ping", nil); err != nil {
						log.Printf("cmux: connection lost: %v", err)
						cmuxConnectedFlag = false
						poll.Broadcast(poller.Event{
							Type: "cmux.disconnected",
							Data: map[string]any{"reason": "socket_unavailable"},
						})
						break pingLoop
					}
				}
			}
		}
	}()

	// Start mDNS advertisement
	stopMDNS, err := mdns.Advertise(cfg.BridgePort)
	if err != nil {
		log.Printf("mdns: %v (continuing without mDNS)", err)
	} else {
		defer stopMDNS()
	}

	// Start WebSocket server
	server := ws.NewServer(token, poll, cmuxClient, func() bool { return cmuxConnectedFlag })
	addr := fmt.Sprintf(":%d", cfg.BridgePort)
	log.Printf("ws: listening on %s", addr)
	if err := server.ListenAndServe(ctx, addr); err != nil {
		log.Fatalf("ws server: %v", err)
	}
}

func isAuthRequired(err error) bool {
	if err == nil {
		return false
	}
	s := err.Error()
	return strings.Contains(s, "auth_required") || strings.Contains(s, "Authentication required")
}
