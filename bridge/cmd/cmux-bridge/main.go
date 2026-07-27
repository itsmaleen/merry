package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/itsmaleen/cmux-companion/bridge/internal/mdns"
	"github.com/itsmaleen/cmux-companion/bridge/internal/pair"
	"github.com/itsmaleen/cmux-companion/bridge/internal/poller"
	"github.com/itsmaleen/cmux-companion/bridge/internal/socket"
	"github.com/itsmaleen/cmux-companion/bridge/internal/ws"
	"tailscale.com/tsnet"
)

const (
	defaultPort         = 47821
	defaultPollInterval = 1000
	configDirName       = "cmux-bridge"
	configFileName      = "config.json"
)

type config struct {
	SocketPath        string `json:"socket_path"`
	SocketPassword    string `json:"socket_password"`
	BridgePort        int    `json:"bridge_port"`
	PollIntervalMs    int    `json:"poll_interval_ms"`
	Tailscale         bool   `json:"tailscale"`
	TailscaleHostname string `json:"tailscale_hostname"`
}

func defaultConfig() config {
	return config{
		SocketPath:        "",
		SocketPassword:    "",
		BridgePort:        defaultPort,
		PollIntervalMs:    defaultPollInterval,
		Tailscale:         false,
		TailscaleHostname: "cmux-bridge",
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
	tailscaleFlag := flag.Bool("tailscale", false, "enable Tailscale tailnet listener")
	flag.Parse()

	// cmux only accepts control-socket connections from the user that runs cmux;
	// a root peer is denied with "ERROR: Access denied - only processes started
	// inside cmux can connect". The bridge then connects but has every RPC
	// rejected — surfacing as cryptic 'E' parse errors and endless reconnect
	// flapping. This most often happens when a historical `sudo ./install-bridge.sh`
	// left a root-domain launchd job behind. Warn early so the log names the cause.
	if os.Geteuid() == 0 {
		log.Printf("WARNING: running as root (uid 0). cmux denies control-socket access to " +
			"root (\"Access denied - only processes started inside cmux can connect\"), so " +
			"every RPC will fail. Run the bridge as your normal user (see scripts/install-bridge.sh).")
	}

	dir := configDir()
	cfg, err := loadConfig(dir)
	if err != nil {
		log.Fatalf("config: %v", err)
	}

	// CLI flag overrides config
	if *tailscaleFlag {
		cfg.Tailscale = true
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

	// Verify connectivity with a real RPC round-trip. Connect() only opens the
	// socket; it does not prove cmux will answer requests. cmux can accept the
	// connection and then reject every RPC — e.g. when the bridge runs as the
	// wrong uid or the socket password is wrong. Pinging here surfaces that at
	// pairing time instead of leaving a daemon that silently flaps afterward.
	client := socket.NewClient(cfg.SocketPath, cfg.SocketPassword)
	if err := client.Connect(); err != nil {
		log.Fatalf("cannot connect to cmux socket: %v\nMake sure cmux is running and the socket path is correct (%s)", err, cfg.SocketPath)
	}
	if _, err := client.Send("system.ping", nil); err != nil {
		client.Close()
		log.Fatalf("connected to the cmux socket but it rejected a test request: %v\n"+
			"An \"Access denied\" error means the bridge is running as the wrong user (do not run "+
			"as root — cmux only accepts connections from the user running cmux); otherwise the "+
			"socket password is wrong.", err)
	}
	client.Close()
	fmt.Println("Connected to cmux.")

	token, err := pair.LoadOrCreateToken(dir)
	if err != nil {
		log.Fatalf("token: %v", err)
	}

	// If Tailscale is enabled, bring up tsnet to discover the tailnet hostname.
	// The user explicitly asked for remote access, so refuse to fall back to a
	// LAN-only QR — that silent degradation is exactly what makes a phone pair
	// "successfully" and then sit on "reconnecting" off Wi-Fi.
	var tailscaleHost string
	if cfg.Tailscale {
		// The background daemon holds the tsnet state directory open, which would
		// block our pairing tsnet. Pause it for the duration and bring it back as
		// soon as we've read the hostname (tsnet state is released by then), so a
		// failure here can't leave the daemon down and the phone reconnecting.
		restore := pauseDaemonForPairing()
		tailscaleHost = startTailscaleForPairing(dir, cfg)
		restore()
		if tailscaleHost == "" {
			log.Fatalf("--tailscale was requested but the bridge's Tailscale node did not come up.\n" +
				"Authorize it at the login URL printed above, then re-run `cmux-bridge --pair --tailscale`.\n" +
				"Refusing to print a LAN-only QR that would silently drop remote access.")
		}
	}

	if err := pair.PrintQR("", cfg.BridgePort, token, tailscaleHost); err != nil {
		log.Fatalf("qr: %v", err)
	}
}

// launchdLabel is the LaunchAgent label installed by scripts/install-bridge.sh.
const launchdLabel = "com.itsmaleen.cmux-bridge"

// pauseDaemonForPairing stops the launchd-managed bridge daemon so it releases
// the tsnet state directory during --tailscale pairing, returning a function
// that restarts it. It is a no-op on non-macOS or when the daemon isn't managed
// by launchd (e.g. run by hand), and the returned restore is safe to call once.
func pauseDaemonForPairing() (restore func()) {
	noop := func() {}
	if runtime.GOOS != "darwin" {
		return noop
	}
	uid := os.Getuid()
	target := fmt.Sprintf("gui/%d/%s", uid, launchdLabel)

	// Only touch the daemon if launchd currently knows about it.
	if err := exec.Command("launchctl", "print", target).Run(); err != nil {
		return noop
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return noop
	}
	plist := filepath.Join(home, "Library", "LaunchAgents", launchdLabel+".plist")

	if err := exec.Command("launchctl", "bootout", target).Run(); err != nil {
		log.Printf("warning: could not pause the bridge daemon for pairing: %v", err)
		return noop
	}
	fmt.Println("Paused the background bridge daemon for pairing.")
	// Give launchd a moment to tear the process down and free the tsnet lock.
	time.Sleep(500 * time.Millisecond)

	var once sync.Once
	return func() {
		once.Do(func() {
			domain := fmt.Sprintf("gui/%d", uid)
			if err := exec.Command("launchctl", "bootstrap", domain, plist).Run(); err != nil {
				log.Printf("warning: could not restart the bridge daemon: %v\n"+
					"restart it manually with: launchctl bootstrap %s %s", err, domain, plist)
				return
			}
			fmt.Println("Restarted the background bridge daemon.")
		})
	}
}

// startTailscaleForPairing starts a tsnet server to discover the tailnet
// hostname. If the node isn't authenticated yet it surfaces the interactive
// login URL clearly (instead of burying it in tsnet's verbose output) and waits
// a few minutes for the user to approve it. Returns "" if the node can't be
// brought up in that window.
func startTailscaleForPairing(dir string, cfg config) string {
	var loginOnce sync.Once
	ts := &tsnet.Server{
		Hostname: cfg.TailscaleHostname,
		Dir:      filepath.Join(dir, "tailscale"),
		Logf: func(format string, args ...any) {
			msg := fmt.Sprintf(format, args...)
			if i := strings.Index(msg, "https://login.tailscale.com/"); i >= 0 {
				url := strings.Fields(msg[i:])[0]
				loginOnce.Do(func() {
					fmt.Println()
					fmt.Println("Tailscale login required to enable remote access.")
					fmt.Printf("Open this URL and approve %q on your tailnet:\n\n  %s\n\n", cfg.TailscaleHostname, url)
					fmt.Println("Waiting for authorization (up to 3 minutes)…")
				})
			}
		},
	}

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()

	status, err := ts.Up(ctx)
	if err != nil {
		log.Printf("tailscale: node did not come up: %v", err)
		ts.Close()
		return ""
	}

	dnsName := strings.TrimSuffix(status.Self.DNSName, ".")
	log.Printf("tailscale: %s", dnsName)
	ts.Close()
	return dnsName
}

// runDaemon starts the bridge in daemon mode with reconnect loop.
func runDaemon(dir string, cfg config) {
	if cfg.SocketPassword == "" {
		// Probe the socket; if it responds with auth_required, fail fast
		client := socket.NewClient(cfg.SocketPath, "")
		if err := client.Connect(); err != nil {
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
	var cmuxConnected atomic.Bool

	poll := poller.New(cmuxClient, time.Duration(cfg.PollIntervalMs)*time.Millisecond)

	stopPoller := make(chan struct{})
	go func() {
		<-ctx.Done()
		close(stopPoller)
	}()
	go poll.Run(stopPoller)

	// Reconnect loop
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
				if cmuxConnected.Load() {
					cmuxConnected.Store(false)
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
			cmuxConnected.Store(true)
			poll.Broadcast(poller.Event{
				Type: "cmux.connected",
				Data: map[string]any{"bridge_version": ws.BridgeVersion()},
			})

		pingLoop:
			for {
				select {
				case <-ctx.Done():
					return
				case <-time.After(5 * time.Second):
					if _, err := cmuxClient.Send("system.ping", nil); err != nil {
						log.Printf("cmux: connection lost: %v", err)
						cmuxConnected.Store(false)
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

	// Start mDNS advertisement (LAN discovery)
	stopMDNS, err := mdns.Advertise(cfg.BridgePort)
	if err != nil {
		log.Printf("mdns: %v (continuing without mDNS)", err)
	} else {
		defer stopMDNS()
	}

	// Build listeners
	addr := fmt.Sprintf(":%d", cfg.BridgePort)
	lanLn, err := net.Listen("tcp", addr)
	if err != nil {
		log.Fatalf("lan listen %s: %v", addr, err)
	}
	log.Printf("ws: listening on %s (LAN)", addr)

	listeners := []net.Listener{lanLn}

	// Tailscale listener
	var tsServer *tsnet.Server
	if cfg.Tailscale {
		tsServer = &tsnet.Server{
			Hostname: cfg.TailscaleHostname,
			Dir:      filepath.Join(dir, "tailscale"),
		}

		log.Printf("tailscale: starting as %s ...", cfg.TailscaleHostname)
		tsLn, err := tsServer.Listen("tcp", addr)
		if err != nil {
			log.Printf("tailscale: listen failed: %v (continuing without tailnet)", err)
		} else {
			status, err := tsServer.Up(ctx)
			if err != nil {
				log.Printf("tailscale: up failed: %v (continuing without tailnet)", err)
			} else {
				dnsName := strings.TrimSuffix(status.Self.DNSName, ".")
				log.Printf("tailscale: listening on %s:%d", dnsName, cfg.BridgePort)
				listeners = append(listeners, tsLn)
			}
		}
		defer tsServer.Close()
	}

	// Start WebSocket server on all listeners
	server := ws.NewServer(token, poll, cmuxClient, func() bool { return cmuxConnected.Load() })
	if err := server.Serve(ctx, listeners...); err != nil {
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
