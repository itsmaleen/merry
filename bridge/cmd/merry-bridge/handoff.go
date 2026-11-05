package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"time"

	"github.com/itsmaleen/merry/bridge/internal/handoff"
	"github.com/itsmaleen/merry/bridge/internal/ws"
)

// handoffConfig is the "handoff" block of config.json.
type handoffConfig struct {
	// Machine is the herdr machine label sessions move to by default.
	Machine string `json:"machine,omitempty"`
	// Synced are directories kept in sync by other means (caravan), so their
	// working tree is not copied, only checked.
	Synced []string `json:"synced,omitempty"`
	// Bridge is the tailnet name of the Merry bridge on Machine, so the phone
	// can follow the sessions there.
	Bridge string `json:"bridge,omitempty"`
}

func (c handoffConfig) withDefaults() handoffConfig {
	if c.Machine == "" {
		c.Machine = "desktop"
	}
	if c.Bridge == "" && c.Machine == "desktop" {
		c.Bridge = "desktop-bridge"
	}
	if c.Synced == nil {
		c.Synced = []string{"~/wrinkles", "~/agent-config"}
	}
	return c
}

// enableHandoff offers session.handoff to phones when herdr here knows the
// handoff machine.
func enableHandoff(c handoffConfig) {
	c = c.withDefaults()
	widenPath()
	out, err := exec.Command("herdr", "machine", "list").Output()
	if err != nil {
		log.Printf("handoff: off (herdr machine list: %v)", err)
		return
	}
	for _, line := range strings.Split(string(out), "\n") {
		if f := strings.Split(line, "\t"); len(f) >= 2 && f[1] == c.Machine {
			ws.SetHandoff(ws.HandoffConfig{Machine: c.Machine, Bridge: c.Bridge, Synced: c.Synced})
			log.Printf("handoff: on, to herdr machine %q (bridge %q)", c.Machine, c.Bridge)
			return
		}
	}
	log.Printf("handoff: off (no herdr machine %q)", c.Machine)
}

// widenPath adds the usual user tool directories to PATH. launchd and
// systemd start the bridge with a bare PATH, where herdr (Homebrew,
// ~/.local/bin) is missing, and the handoff shells out to herdr, git and ssh.
func widenPath() {
	home, _ := os.UserHomeDir()
	have := map[string]bool{}
	parts := filepath.SplitList(os.Getenv("PATH"))
	for _, p := range parts {
		have[p] = true
	}
	for _, d := range []string{"/opt/homebrew/bin", "/usr/local/bin", filepath.Join(home, ".local/bin"), filepath.Join(home, ".cargo/bin"), filepath.Join(home, "go/bin")} {
		if !have[d] {
			if fi, err := os.Stat(d); err == nil && fi.IsDir() {
				parts = append(parts, d)
			}
		}
	}
	os.Setenv("PATH", strings.Join(parts, string(filepath.ListSeparator)))
}

type multiFlag []string

func (m *multiFlag) String() string     { return strings.Join(*m, ",") }
func (m *multiFlag) Set(v string) error { *m = append(*m, v); return nil }

// runHandoff implements `merry-bridge handoff`.
func runHandoff(args []string) int {
	fs := flag.NewFlagSet("handoff", flag.ExitOnError)
	fs.Usage = func() {
		fmt.Fprint(os.Stderr, `Usage: merry-bridge handoff [options]

Move agent sessions (claude, codex, opencode) between this machine and another
herdr machine, resuming each where it left off.

  merry-bridge handoff                      every agent here -> desktop
  merry-bridge handoff --workspace wrinkles one workspace
  merry-bridge handoff --pane wS:p2Q        one pane
  merry-bridge handoff --back               every agent on desktop -> here
  merry-bridge handoff --dry-run            show the plan only

Options:
`)
		fs.PrintDefaults()
	}
	var panes multiFlag
	cfgDir := fs.String("config-dir", "", "bridge config directory (default ~/.config/merry-bridge)")
	to := fs.String("to", "", "target herdr machine label (default: config handoff.machine, else desktop)")
	from := fs.String("from", "local", "source: local or a herdr machine label")
	back := fs.Bool("back", false, "pull sessions from the handoff machine to this one (--from <machine> --to local)")
	fs.Var(&panes, "pane", "herdr pane id to move (repeatable; default every agent pane)")
	ws := fs.String("workspace", "", "only move agents in this workspace (label or id)")
	wait := fs.Duration("wait", 2*time.Minute, "how long to wait for a working agent to settle")
	force := fs.Bool("force", false, "move agents even mid-turn (the turn is lost)")
	dry := fs.Bool("dry-run", false, "print what would move and stop")
	closeSrc := fs.Bool("close", false, "close the source panes after moving (default: rename them)")
	asJSON := fs.Bool("json", false, "print results as JSON")
	_ = fs.Parse(args)

	dir := configDir()
	if *cfgDir != "" {
		dir = *cfgDir
	}
	cfg, err := loadConfig(dir)
	if err != nil {
		fmt.Fprintln(os.Stderr, "config:", err)
		return 1
	}
	hc := cfg.Handoff.withDefaults()
	target := *to
	if target == "" {
		target = hc.Machine
	}
	source := *from
	if *back {
		source, target = target, "local"
		if *to != "" {
			source = *to
		}
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	opts := handoff.Options{
		From: source, To: target, Panes: panes, Workspace: *ws,
		Wait: *wait, Force: *force, DryRun: *dry, CloseSource: *closeSrc,
		Synced: hc.Synced,
	}
	if !*asJSON {
		opts.Log = func(f string, a ...any) { fmt.Fprintf(os.Stderr, "  "+f+"\n", a...) }
	}
	res, err := handoff.Run(ctx, opts)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	if *asJSON {
		_ = json.NewEncoder(os.Stdout).Encode(res)
	} else {
		fmt.Printf("\n%s -> %s\n", source, target)
		for _, r := range res {
			line := fmt.Sprintf("%-8s %-8s %-20s %s", r.Status, r.Agent, trunc(r.Workspace, 20), r.FromCwd)
			if r.ToPane != "" {
				line += "  -> " + r.ToPane
			}
			if r.Repo != "" {
				line += "  [" + r.Repo + "]"
			}
			if r.Reason != "" {
				line += "  " + r.Reason
			}
			if r.RolledBack {
				line += " (restarted where it was)"
			}
			fmt.Println(line)
		}
	}
	for _, r := range res {
		if r.Status == "failed" {
			return 2
		}
	}
	return 0
}

func trunc(s string, n int) string {
	if len([]rune(s)) <= n {
		return s
	}
	return string([]rune(s)[:n-1]) + "…"
}
