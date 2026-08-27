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
	"syscall"
	"time"

	"github.com/itsmaleen/merry/bridge/internal/backend"
	"github.com/itsmaleen/merry/bridge/internal/backend/cmux"
	"github.com/itsmaleen/merry/bridge/internal/backend/herdr"
	"github.com/itsmaleen/merry/bridge/internal/backend/multi"
	"github.com/itsmaleen/merry/bridge/internal/mdns"
	"github.com/itsmaleen/merry/bridge/internal/pair"
	"github.com/itsmaleen/merry/bridge/internal/socket"
	"github.com/itsmaleen/merry/bridge/internal/ws"
	"tailscale.com/tsnet"
)

const (
	defaultPort         = 47821
	defaultPollInterval = 1000
	configDirName       = "merry-bridge"
	// legacyConfigDirName is the pre-rename directory. configDir() keeps using
	// it when the new one doesn't exist yet, so renaming the product doesn't
	// force a re-pair or discard the tailnet node.
	legacyConfigDirName = "cmux-bridge"
	configFileName      = "config.json"
)

type config struct {
	// Backend is "cmux", "herdr", "all", or "auto" (the default). auto fronts
	// every runtime whose socket answers — both at once when both are running,
	// each namespaced (cmux:…, herdr:…) — and falls back to cmux when neither
	// does so the existing error paths explain what is missing. all fronts
	// both regardless, reconnecting to whichever is down.
	Backend           string `json:"backend"`
	SocketPath        string `json:"socket_path"`
	SocketPassword    string `json:"socket_password"`
	HerdrSocketPath   string `json:"herdr_socket_path"`
	HerdrSession      string `json:"herdr_session"`
	BridgePort        int    `json:"bridge_port"`
	PollIntervalMs    int    `json:"poll_interval_ms"`
	Tailscale         bool   `json:"tailscale"`
	TailscaleHostname string `json:"tailscale_hostname"`
}

func defaultConfig() config {
	return config{
		Backend:           "auto",
		SocketPath:        "",
		SocketPassword:    "",
		BridgePort:        defaultPort,
		PollIntervalMs:    defaultPollInterval,
		Tailscale:         false,
		TailscaleHostname: "merry-bridge",
	}
}

// resolveBackendKinds turns cfg.Backend into the concrete runtimes to front,
// in priority order.
func resolveBackendKinds(cfg config) []string {
	switch strings.ToLower(strings.TrimSpace(cfg.Backend)) {
	case "cmux":
		return []string{"cmux"}
	case "herdr":
		return []string{"herdr"}
	case "all", "both", "cmux+herdr":
		return []string{"cmux", "herdr"}
	case "", "auto":
	default:
		// A typo must not silently widen to every runtime on the machine.
		log.Fatalf("config: unknown backend %q (want cmux, herdr, all, or auto)", cfg.Backend)
	}
	var kinds []string
	if _, err := os.Stat(cfg.SocketPath); err == nil {
		if err := cmux.New(cmux.Config{SocketPath: cfg.SocketPath, Password: cfg.SocketPassword}).Ping(); err == nil || cmux.IsAuthRequired(err) {
			kinds = append(kinds, "cmux")
		}
	}
	if err := herdr.New(herdr.Config{SocketPath: cfg.HerdrSocketPath}).Ping(); err == nil {
		kinds = append(kinds, "herdr")
	}
	if len(kinds) == 0 {
		return []string{"cmux"}
	}
	return kinds
}

// openBackend builds the configured backend(s) without connecting them. More
// than one kind yields a composite that namespaces every id by runtime.
func openBackend(kinds []string, cfg config) backend.Backend {
	members := make([]multi.Member, 0, len(kinds))
	for _, kind := range kinds {
		switch kind {
		case "herdr":
			members = append(members, multi.Member{Kind: "herdr", Backend: herdr.New(herdr.Config{
				SocketPath:    cfg.HerdrSocketPath,
				BridgeVersion: ws.BridgeVersion(),
			})})
		default:
			members = append(members, multi.Member{Kind: "cmux", Backend: cmux.New(cmux.Config{
				SocketPath:    cfg.SocketPath,
				Password:      cfg.SocketPassword,
				PollInterval:  time.Duration(cfg.PollIntervalMs) * time.Millisecond,
				BridgeVersion: ws.BridgeVersion(),
			})})
		}
	}
	if len(members) == 1 {
		return members[0].Backend
	}
	return multi.New(members...)
}

func hasKind(kinds []string, kind string) bool {
	for _, k := range kinds {
		if k == kind {
			return true
		}
	}
	return false
}

func configDir() string {
	base := "/tmp"
	if home, err := os.UserHomeDir(); err == nil {
		base = filepath.Join(home, ".config")
	}
	dir := filepath.Join(base, configDirName)
	// Migration: if the new config dir hasn't been created yet but a legacy
	// cmux-bridge one exists, keep using it (its token, config, and tailscale
	// state) so the rename is transparent to an existing install.
	if _, err := os.Stat(dir); os.IsNotExist(err) {
		legacy := filepath.Join(base, legacyConfigDirName)
		if _, err := os.Stat(legacy); err == nil {
			return legacy
		}
	}
	return dir
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
	backendFlag := flag.String("backend", "", "terminal runtime(s) to front: cmux, herdr, all, or auto (overrides config)")
	configDirFlag := flag.String("config-dir", "", "config/token directory (default ~/.config/merry-bridge); lets a second bridge run beside the installed one")
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
	if *configDirFlag != "" {
		dir = *configDirFlag
	}
	// The directory holds the pairing token and the socket/port config; refuse
	// one another user could have pre-populated (see pair.EnsurePrivateDir).
	if err := pair.EnsurePrivateDir(dir); err != nil {
		log.Fatalf("config: %v", err)
	}
	cfg, err := loadConfig(dir)
	if err != nil {
		log.Fatalf("config: %v", err)
	}

	// CLI flag overrides config
	if *tailscaleFlag {
		cfg.Tailscale = true
	}

	if *backendFlag != "" {
		cfg.Backend = *backendFlag
	}

	// Resolve socket paths
	if cfg.SocketPath == "" {
		cfg.SocketPath = socket.DetectSocketPath()
	}
	if cfg.HerdrSocketPath == "" {
		if cfg.HerdrSession != "" {
			cfg.HerdrSocketPath = herdr.SocketPathForSession(cfg.HerdrSession)
		} else {
			cfg.HerdrSocketPath = herdr.DefaultSocketPath()
		}
	}
	kinds := resolveBackendKinds(cfg)

	if *pairMode {
		runPair(dir, cfg, kinds)
		return
	}

	runDaemon(dir, cfg, kinds)
}

// runPair handles --pair: connect to cmux (prompting for password if needed),
// display the QR code, and exit.
func runPair(dir string, cfg config, kinds []string) {
	kind := strings.Join(kinds, "+")
	// Prompt for password if not configured
	if hasKind(kinds, "cmux") && cfg.SocketPassword == "" {
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
	be := openBackend(kinds, cfg)
	if err := be.Ping(); err != nil {
		switch {
		case !hasKind(kinds, "cmux"):
			log.Fatalf("cannot reach herdr at %s: %v\nMake sure herdr is running (run `herdr` in a terminal) or set herdr_socket_path / herdr_session in %s", cfg.HerdrSocketPath, err, filepath.Join(dir, configFileName))
		default:
			log.Fatalf("cannot reach cmux at %s: %v\n"+
				"Make sure cmux is running and the socket path is correct. An \"Access denied\" error means the "+
				"bridge is running as the wrong user (do not run as root — cmux only accepts connections from the "+
				"user running cmux); otherwise the socket password is wrong.", cfg.SocketPath, err)
		}
	}
	fmt.Printf("Connected to %s.\n", kind)

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
				"Authorize it at the login URL printed above, then re-run `merry-bridge --pair --tailscale`.\n" +
				"Refusing to print a LAN-only QR that would silently drop remote access.")
		}
	}

	if err := pair.PrintQR("", cfg.BridgePort, token, tailscaleHost, kind); err != nil {
		log.Fatalf("qr: %v", err)
	}
}

// launchdLabel is the LaunchAgent label installed by scripts/install-bridge.sh.
const launchdLabel = "com.itsmaleen.merry-bridge"

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
func runDaemon(dir string, cfg config, kinds []string) {
	kind := strings.Join(kinds, "+")
	// Only a cmux-only bridge treats an unreachable cmux socket as fatal; under
	// a composite the cmux member simply reconnects when cmux comes back.
	if hasKind(kinds, "cmux") && len(kinds) == 1 && cfg.SocketPassword == "" {
		// Probe the socket; if it responds with auth_required, fail fast
		client := socket.NewClient(cfg.SocketPath, "")
		if err := client.Connect(); err != nil {
			log.Fatalf("cannot connect to cmux socket at %s: %v\nRun with --pair to configure", cfg.SocketPath, err)
		}
		_, probeErr := client.Send("system.ping", nil)
		client.Close()
		if probeErr != nil && cmux.IsAuthRequired(probeErr) {
			log.Fatalf("cmux socket requires a password but none is configured.\nRun with --pair to configure the password.")
		}
	}

	token, err := pair.LoadOrCreateToken(dir)
	if err != nil {
		log.Fatalf("token: %v", err)
	}

	log.Printf("merry-bridge %s starting on port %d (backend: %s)", ws.BridgeVersion(), cfg.BridgePort, kind)
	if hasKind(kinds, "herdr") {
		log.Printf("herdr socket: %s", cfg.HerdrSocketPath)
	}
	if hasKind(kinds, "cmux") {
		log.Printf("cmux socket: %s", cfg.SocketPath)
	}

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	be := openBackend(kinds, cfg)
	go be.Run(ctx)

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
	server := ws.NewServer(token, be)
	if err := server.Serve(ctx, listeners...); err != nil {
		log.Fatalf("ws server: %v", err)
	}
}
