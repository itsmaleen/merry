// Package handoff moves live agent sessions (Claude Code, Codex, opencode)
// between machines that both run herdr, so work started on the MacBook can be
// picked up on the desktop when Marlin heads out, and brought back after.
//
// One move, per agent pane:
//
//  1. Wait for the agent to settle (idle/done), then stop it, so its
//     transcript on disk is final and only one process ever writes it.
//  2. Copy the working tree of its repo (tracked + untracked-not-ignored files,
//     the .git dir, and ignored .env* files) unless the directory is already
//     kept in sync by something else (caravan); then only check the
//     recently-changed files arrived, and copy over the ones that have not.
//  3. Copy the agent's native session files with home paths rewritten.
//  4. Start the same agent with the same flags plus its resume flag in a
//     herdr pane on the target, in a workspace with the same label.
//  5. If 2-4 fail, restart the agent where it was.
//
// Hosts are reached the way herdr already reaches them: the local machine
// directly, a remote one through `herdr --machine <label>` for the herdr API
// and plain ssh to the machine's saved ssh target for files. Either side can
// be the remote one, so the Mac can push to the desktop and pull back.
package handoff

import (
	"archive/tar"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path"
	"strings"
	"time"
)

// Host is one end of a move.
type Host struct {
	// Label is "local" or a herdr machine label.
	Label string
	// SSH is the ssh target for a remote host, "" for local.
	SSH string
	// Home is the user's home directory on that host.
	Home string
}

func (h *Host) Local() bool { return h.SSH == "" }

// Runner executes a command. Swappable for tests.
type Runner func(ctx context.Context, stdin io.Reader, stdout io.Writer, name string, args ...string) error

func execRunner(ctx context.Context, stdin io.Reader, stdout io.Writer, name string, args ...string) error {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Stdin = stdin
	cmd.Stdout = stdout
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(stderr.String())
		if len(msg) > 600 {
			msg = msg[len(msg)-600:]
		}
		if msg != "" {
			return fmt.Errorf("%s: %w: %s", name, err, msg)
		}
		return fmt.Errorf("%s: %w", name, err)
	}
	return nil
}

// Options configure a move.
type Options struct {
	// From and To are "local" or a herdr machine label. Exactly one is usually
	// local; both remote is refused.
	From, To string
	// Panes are herdr pane ids on From. Empty means every agent pane on From,
	// narrowed by Workspace.
	Panes []string
	// Workspace narrows the move to one workspace (label or id) on From.
	Workspace string
	// Wait is how long to wait for a working agent to settle before skipping
	// it. Zero skips working agents immediately.
	Wait time.Duration
	// Force moves an agent that is still working (its current turn is lost).
	Force bool
	// DryRun reports what would move without touching anything.
	DryRun bool
	// Synced are directories (on the local machine, ~ allowed) that something
	// else keeps in sync between the hosts, so the repo copy is skipped.
	Synced []string
	// CloseSource closes the source pane after a successful move instead of
	// leaving it as a labelled shell.
	CloseSource bool
	// MaxRepoBytes caps one repo copy (default 2 GiB).
	MaxRepoBytes int64
	// Log receives progress lines.
	Log func(format string, args ...any)
	// Run overrides the command runner (tests).
	Run Runner
}

// Result is one session's outcome.
type Result struct {
	Pane       string `json:"pane"`
	Agent      string `json:"agent"`
	SessionID  string `json:"session_id"`
	Workspace  string `json:"workspace"`
	FromCwd    string `json:"from_cwd"`
	ToCwd      string `json:"to_cwd"`
	ToPane     string `json:"to_pane,omitempty"`
	Repo       string `json:"repo,omitempty"` // "copied", "synced", "synced+patched N", "skipped"
	Status     string `json:"status"`         // "moved", "skipped", "failed", "planned"
	Reason     string `json:"reason,omitempty"`
	RolledBack bool   `json:"rolled_back,omitempty"`
}

type mover struct {
	o        Options
	run      Runner
	src, dst Host
	log      func(string, ...any)
}

// Run performs the move and returns one Result per agent pane considered.
func Run(ctx context.Context, o Options) ([]Result, error) {
	m := &mover{o: o, run: o.Run, log: o.Log}
	if m.run == nil {
		m.run = execRunner
	}
	if m.log == nil {
		m.log = func(string, ...any) {}
	}
	if m.o.MaxRepoBytes == 0 {
		m.o.MaxRepoBytes = 2 << 30
	}
	if o.From == "" {
		m.o.From = "local"
	}
	if o.To == "" {
		return nil, errors.New("handoff: no target machine")
	}
	if m.o.From == m.o.To {
		return nil, errors.New("handoff: source and target are the same machine")
	}
	if m.o.From != "local" && m.o.To != "local" {
		return nil, errors.New("handoff: one side must be this machine")
	}
	var err error
	if m.src, err = m.resolveHost(ctx, m.o.From); err != nil {
		return nil, err
	}
	if m.dst, err = m.resolveHost(ctx, m.o.To); err != nil {
		return nil, err
	}

	agents, err := m.listAgents(ctx)
	if err != nil {
		return nil, err
	}
	if len(agents) == 0 {
		return nil, errors.New("handoff: no matching agent panes on " + m.src.Label)
	}

	var results []Result
	for _, a := range agents {
		r := m.moveOne(ctx, a)
		m.log("%s %s %s: %s %s", r.Status, r.Agent, short(r.SessionID), r.Workspace, r.Reason)
		results = append(results, r)
	}
	return results, nil
}

// ---------- hosts ----------

func (m *mover) resolveHost(ctx context.Context, label string) (Host, error) {
	if label == "local" {
		home, err := os.UserHomeDir()
		return Host{Label: "local", Home: home}, err
	}
	var out bytes.Buffer
	if err := m.run(ctx, nil, &out, "herdr", "machine", "list"); err != nil {
		return Host{}, err
	}
	target := ""
	for _, line := range strings.Split(out.String(), "\n") {
		f := strings.Split(line, "\t")
		if len(f) >= 3 && (f[1] == label || f[0] == label) {
			target = f[2]
			label = f[1]
			break
		}
	}
	if target == "" {
		return Host{}, fmt.Errorf("handoff: no saved herdr machine %q (herdr machine list)", label)
	}
	h := Host{Label: label, SSH: target}
	home, err := m.shOut(ctx, h, `printf %s "$HOME"`, nil)
	if err != nil {
		return Host{}, fmt.Errorf("handoff: reach %s over ssh: %w", target, err)
	}
	h.Home = strings.TrimSpace(home)
	if h.Home == "" {
		return Host{}, fmt.Errorf("handoff: %s reported no $HOME", target)
	}
	return h, nil
}

// sh runs a bash script on h.
func (m *mover) sh(ctx context.Context, h Host, script string, stdin io.Reader, stdout io.Writer) error {
	if h.Local() {
		return m.run(ctx, stdin, stdout, "bash", "-c", script)
	}
	// Login shell so nvm/~/.local/bin are on PATH on the far side.
	return m.run(ctx, stdin, stdout, "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", h.SSH, "bash -lc "+shq(script))
}

func (m *mover) shOut(ctx context.Context, h Host, script string, stdin io.Reader) (string, error) {
	var out bytes.Buffer
	err := m.sh(ctx, h, script, stdin, &out)
	return out.String(), err
}

// herdr runs one herdr API command on h and returns its `result`.
func (m *mover) herdr(ctx context.Context, h Host, args ...string) (json.RawMessage, error) {
	if !h.Local() {
		args = append([]string{"--machine", h.Label}, args...)
	}
	var out bytes.Buffer
	if err := m.run(ctx, nil, &out, "herdr", args...); err != nil {
		return nil, err
	}
	if len(bytes.TrimSpace(out.Bytes())) == 0 {
		return nil, nil // pane send-keys/run/rename print nothing on success
	}
	var env struct {
		Result json.RawMessage `json:"result"`
		Error  *struct {
			Code, Message string
		} `json:"error"`
	}
	if err := json.Unmarshal(out.Bytes(), &env); err != nil {
		return nil, fmt.Errorf("herdr %s: unreadable reply: %.200s", strings.Join(args, " "), out.String())
	}
	if env.Error != nil {
		return nil, fmt.Errorf("herdr %s: [%s] %s", strings.Join(args, " "), env.Error.Code, env.Error.Message)
	}
	return env.Result, nil
}

// ---------- discovery ----------

type agentPane struct {
	Pane, Agent, Session, Status, Cwd, WorkspaceID, Workspace string
	Argv                                                      []string
}

type snapshot struct {
	Snapshot struct {
		Agents []struct {
			Agent        string `json:"agent"`
			AgentSession *struct {
				Value string `json:"value"`
			} `json:"agent_session"`
			AgentStatus string `json:"agent_status"`
			Cwd         string `json:"cwd"`
			PaneID      string `json:"pane_id"`
			WorkspaceID string `json:"workspace_id"`
		} `json:"agents"`
		Workspaces []struct {
			WorkspaceID string `json:"workspace_id"`
			Label       string `json:"label"`
		} `json:"workspaces"`
		Panes []struct {
			PaneID      string `json:"pane_id"`
			WorkspaceID string `json:"workspace_id"`
			Label       string `json:"label"`
			Agent       string `json:"agent"`
		} `json:"panes"`
	} `json:"snapshot"`
}

func (m *mover) snapshot(ctx context.Context, h Host) (*snapshot, error) {
	raw, err := m.herdr(ctx, h, "api", "snapshot")
	if err != nil {
		return nil, err
	}
	var s snapshot
	if err := json.Unmarshal(raw, &s); err != nil {
		return nil, err
	}
	return &s, nil
}

func (m *mover) listAgents(ctx context.Context) ([]agentPane, error) {
	s, err := m.snapshot(ctx, m.src)
	if err != nil {
		return nil, err
	}
	labels := map[string]string{}
	for _, w := range s.Snapshot.Workspaces {
		labels[w.WorkspaceID] = w.Label
	}
	want := map[string]bool{}
	for _, p := range m.o.Panes {
		want[p] = true
	}
	seen := map[string]bool{}
	var out []agentPane
	for _, a := range s.Snapshot.Agents {
		if seen[a.PaneID] {
			continue // the snapshot can list a pane twice
		}
		seen[a.PaneID] = true
		if len(want) > 0 && !want[a.PaneID] {
			continue
		}
		if m.o.Workspace != "" && a.WorkspaceID != m.o.Workspace && labels[a.WorkspaceID] != m.o.Workspace {
			continue
		}
		ap := agentPane{Pane: a.PaneID, Agent: a.Agent, Status: a.AgentStatus, Cwd: a.Cwd,
			WorkspaceID: a.WorkspaceID, Workspace: labels[a.WorkspaceID]}
		if a.AgentSession != nil {
			ap.Session = a.AgentSession.Value
		}
		out = append(out, ap)
	}
	for p := range want {
		if !seen[p] {
			out = append(out, agentPane{Pane: p, Status: "missing"})
		}
	}
	return out, nil
}

// agentProc is the agent's own process in a pane.
type agentProc struct {
	Argv []string
	Cwd  string
	Pid  int
}

// findAgent finds the agent's process among the pane's foreground processes
// (MCP servers it spawned share the process group). nil when it is gone.
func (m *mover) findAgent(ctx context.Context, h Host, pane, agent string) (*agentProc, error) {
	raw, err := m.herdr(ctx, h, "pane", "process-info", "--pane", pane)
	if err != nil {
		return nil, err
	}
	var pi struct {
		ProcessInfo struct {
			Foreground []struct {
				Argv  []string `json:"argv"`
				Argv0 string   `json:"argv0"`
				Name  string   `json:"name"`
				Pid   int      `json:"pid"`
				Cwd   string   `json:"cwd"`
			} `json:"foreground_processes"`
		} `json:"process_info"`
	}
	if err := json.Unmarshal(raw, &pi); err != nil {
		return nil, err
	}
	for _, p := range pi.ProcessInfo.Foreground {
		switch {
		case len(p.Argv) == 0 && p.Name == agent && p.Pid > 0:
			// herdr on Linux reports only name+pid; read the argv from /proc.
			argv := []string{agent}
			if out, err := m.shOut(ctx, h, fmt.Sprintf("tr '\\0' '\\n' < /proc/%d/cmdline", p.Pid), nil); err == nil {
				if got := strings.Split(strings.TrimRight(out, "\n"), "\n"); len(got) > 0 && got[0] != "" {
					argv = append([]string{agent}, got[1:]...)
				}
			}
			return &agentProc{Argv: argv, Cwd: p.Cwd, Pid: p.Pid}, nil
		case len(p.Argv) > 0 && path.Base(p.Argv[0]) == agent:
			return &agentProc{Argv: p.Argv, Cwd: p.Cwd, Pid: p.Pid}, nil
		case len(p.Argv) > 1 && path.Base(p.Argv[0]) == "node" && path.Base(p.Argv[1]) == agent:
			// node-hosted CLIs: `node /…/bin/codex …`
			return &agentProc{Argv: append([]string{agent}, p.Argv[2:]...), Cwd: p.Cwd, Pid: p.Pid}, nil
		}
	}
	return nil, nil
}

// ---------- one move ----------

func (m *mover) moveOne(ctx context.Context, a agentPane) Result {
	r := Result{Pane: a.Pane, Agent: a.Agent, SessionID: a.Session, Workspace: a.Workspace, FromCwd: a.Cwd}
	skip := func(why string) Result { r.Status, r.Reason = "skipped", why; return r }
	fail := func(err error) Result { r.Status, r.Reason = "failed", err.Error(); return r }

	switch {
	case a.Status == "missing":
		return skip("no agent in that pane")
	case !supported(a.Agent):
		return skip("agent " + a.Agent + " cannot be resumed elsewhere")
	case a.Session == "":
		return skip("herdr has no session id for it (is the herdr integration installed?)")
	}

	proc, err := m.findAgent(ctx, m.src, a.Pane, a.Agent)
	if err != nil {
		return fail(err)
	}
	if proc == nil {
		return skip("the agent is not the pane's foreground process")
	}
	argv := proc.Argv
	if proc.Cwd != "" {
		a.Cwd = proc.Cwd
		r.FromCwd = proc.Cwd
	}
	dstCwd, ok := mapHome(a.Cwd, m.src.Home, m.dst.Home)
	if !ok {
		return skip(a.Cwd + " is outside the home directory, so it has no counterpart on " + m.dst.Label)
	}
	r.ToCwd = dstCwd
	flags := resumeFlags(a.Agent, argv[1:])

	if a.Status == "working" || a.Status == "blocked" {
		if a.Status == "blocked" && !m.o.Force {
			return skip("waiting on a permission prompt; answer it first")
		}
		if !m.o.Force {
			if m.o.Wait <= 0 {
				return skip("still working")
			}
			if m.o.DryRun {
				return skip("still working (would wait)")
			}
			m.log("waiting up to %s for %s to settle", m.o.Wait, a.Pane)
			if _, err := m.herdr(ctx, m.src, "agent", "wait", a.Pane, "--until", "idle", "--until", "done",
				"--timeout", fmt.Sprint(m.o.Wait.Milliseconds())); err != nil {
				return skip("still working after " + m.o.Wait.String())
			}
		}
	}

	repo, synced := m.repoRoot(ctx, a.Cwd)
	if m.o.DryRun {
		r.Status = "planned"
		switch {
		case synced:
			r.Repo = "synced"
		case repo != "":
			r.Repo = "copy " + repo
		default:
			r.Repo = "skipped (not a git repo)"
		}
		return r
	}

	if !synced && repo != "" {
		if err := m.checkDiverged(ctx, repo); err != nil {
			return skip(err.Error())
		}
	}

	// Stop the agent: from here on the source is not running, so any failure
	// must restart it.
	m.log("stopping %s in %s", a.Agent, a.Pane)
	if err := m.stopAgent(ctx, a, proc.Pid); err != nil {
		return fail(err)
	}
	rollback := func(err error) Result {
		r = fail(err)
		cmd := launchCommand(a.Agent, a.Session, flags)
		// Restart even when the move was interrupted (Ctrl+C cancels ctx).
		rctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 20*time.Second)
		defer cancel()
		if _, rerr := m.herdr(rctx, m.src, "pane", "run", a.Pane, cmd); rerr == nil {
			r.RolledBack = true
		} else {
			r.Reason += "; restart where it was also failed: " + rerr.Error() + " (run: " + cmd + ")"
		}
		return r
	}

	switch {
	case synced:
		n, err := m.checkSynced(ctx, repo)
		if err != nil {
			return rollback(err)
		}
		r.Repo = "synced"
		if n > 0 {
			r.Repo = fmt.Sprintf("synced, %d late files copied", n)
		}
	case repo != "":
		if err := m.copyRepo(ctx, repo); err != nil {
			return rollback(err)
		}
		r.Repo = "copied"
	default:
		r.Repo = "skipped (not a git repo)"
	}

	if err := m.copySession(ctx, a, dstCwd); err != nil {
		return rollback(err)
	}

	pane, err := m.startRemote(ctx, a, dstCwd, flags)
	if err != nil {
		return rollback(err)
	}
	r.ToPane = pane
	r.Status = "moved"
	if st := m.paneStatus(ctx, m.dst, pane); st == "blocked" {
		r.Reason = "waiting on a prompt on " + m.dst.Label + ", answer it from the phone"
	}

	if m.o.CloseSource {
		_, _ = m.herdr(ctx, m.src, "pane", "close", a.Pane)
	} else {
		_, _ = m.herdr(ctx, m.src, "pane", "rename", a.Pane, movedLabel(m.dst.Label))
	}
	return r
}

func supported(agent string) bool {
	return agent == "claude" || agent == "codex" || agent == "opencode"
}

// stopAgent ends the agent and waits for its process to leave the pane.
// SIGTERM first: Claude, Codex and opencode all exit cleanly on it whatever
// their UI is showing (a draft, a side panel), whereas Ctrl+C depends on
// focus. Ctrl+C is the fallback when there is no pid.
func (m *mover) stopAgent(ctx context.Context, a agentPane, pid int) error {
	gone := func(d time.Duration) bool {
		deadline := time.Now().Add(d)
		for time.Now().Before(deadline) {
			if p, err := m.findAgent(ctx, m.src, a.Pane, a.Agent); err == nil && p == nil {
				time.Sleep(500 * time.Millisecond) // let the final transcript write land
				return true
			}
			time.Sleep(300 * time.Millisecond)
		}
		return false
	}
	if pid > 0 {
		if _, err := m.shOut(ctx, m.src, fmt.Sprintf("kill -TERM %d", pid), nil); err == nil && gone(8*time.Second) {
			return nil
		}
	}
	for i := 0; i < 3; i++ {
		if _, err := m.herdr(ctx, m.src, "pane", "send-keys", a.Pane, "ctrl+c"); err != nil {
			return err
		}
		time.Sleep(400 * time.Millisecond)
		if i >= 1 && gone(3*time.Second) {
			return nil
		}
	}
	return errors.New("the agent did not exit")
}

// ---------- repo ----------

// repoRoot returns the git root of cwd on the source and whether it sits
// inside a directory that is synced by other means.
func (m *mover) repoRoot(ctx context.Context, cwd string) (string, bool) {
	root := cwd
	if out, err := m.shOut(ctx, m.src, "git -C "+shq(cwd)+" rev-parse --show-toplevel 2>/dev/null", nil); err == nil && strings.TrimSpace(out) != "" {
		root = strings.TrimSpace(out)
	} else {
		root = ""
	}
	local, _ := os.UserHomeDir()
	for _, s := range m.o.Synced {
		s = expandHome(s, local)
		// Synced paths are named on this machine; translate for a remote source.
		if !m.src.Local() {
			s, _ = mapHome(s, local, m.src.Home)
		}
		if within(cwd, s) {
			if root == "" || !within(root, s) {
				root = s
			}
			return root, true
		}
	}
	return root, false
}

// repoList is a bash snippet run in the repo root that prints, NUL-separated,
// every path to carry: tracked and untracked-not-ignored files that exist,
// ignored .env* files outside node_modules, and the whole .git directory.
const repoList = `
emit() { while IFS= read -r -d '' f; do { [ -e "$f" ] || [ -L "$f" ]; } && printf '%s\0' "$f"; done; }
{ git ls-files -co --exclude-standard -z | emit
  git ls-files -oi --exclude-standard -z | while IFS= read -r -d '' f; do
    case "$f" in */node_modules/*|node_modules/*) continue;; esac
    case "${f##*/}" in .env*) printf '%s\0' "$f";; esac
  done
  [ -d .git ] && find .git -print0
}`

// checkDiverged refuses a copy that would orphan commits: a clone on the
// target with branches pointing at commits the source does not have (work
// committed there and never brought back) would lose them when .git is
// overwritten. Runs before the agent is stopped.
func (m *mover) checkDiverged(ctx context.Context, root string) error {
	if wt, _ := m.shOut(ctx, m.src, "[ -f "+shq(root+"/.git")+" ] && echo worktree", nil); strings.TrimSpace(wt) == "worktree" {
		return errors.New(root + " is a git worktree; its .git points at a path that does not exist on " + m.dst.Label)
	}
	dstRoot, ok := mapHome(root, m.src.Home, m.dst.Home)
	if !ok {
		return errors.New(root + " is outside the home directory")
	}
	refs, _ := m.shOut(ctx, m.dst, "cd "+shq(dstRoot)+" 2>/dev/null && [ -d .git ] && git for-each-ref --format='%(objectname) %(refname:short)' refs/heads", nil)
	if strings.TrimSpace(refs) != "" && !m.o.Force {
		var stdin bytes.Buffer
		stdin.WriteString(refs)
		missing, err := m.shOut(ctx, m.src, "cd "+shq(root)+" && while read -r sha ref; do git cat-file -e \"$sha^{commit}\" 2>/dev/null || echo \"$ref\"; done", &stdin)
		if err != nil {
			return fmt.Errorf("compare branches with %s: %w", m.dst.Label, err)
		}
		if b := strings.Fields(missing); len(b) > 0 {
			return fmt.Errorf("%s:%s has commits this side lacks on %s; push or bring them back first (or --force)", m.dst.Label, dstRoot, strings.Join(b, ", "))
		}
	}
	return nil
}

func (m *mover) copyRepo(ctx context.Context, root string) error {
	isFile, _ := m.shOut(ctx, m.src, "[ -f "+shq(root+"/.git")+" ] && echo worktree", nil)
	if strings.TrimSpace(isFile) == "worktree" {
		return errors.New(root + " is a git worktree; its .git points at a path that does not exist on " + m.dst.Label)
	}
	dstRoot, ok := mapHome(root, m.src.Home, m.dst.Home)
	if !ok {
		return errors.New(root + " is outside the home directory")
	}
	// Keep anything uncommitted on the target before it is overwritten.
	backup := `cd ` + shq(dstRoot) + ` 2>/dev/null && [ -d .git ] || exit 0
files=$(git ls-files -mo --exclude-standard | head -c 1)
[ -n "$files" ] || exit 0
d="$HOME/.cache/merry-handoff/backups"; mkdir -p "$d"
find "$d" -name '*.tar' -mtime +14 -delete 2>/dev/null
f="$d/$(date +%Y%m%d-%H%M%S)-$(basename "$PWD").tar"
git ls-files -mo --exclude-standard -z | tar -cf "$f" --null --no-recursion -T - 2>/dev/null
echo "$f"`
	if out, err := m.shOut(ctx, m.dst, backup, nil); err != nil {
		return fmt.Errorf("back up uncommitted files on %s: %w", m.dst.Label, err)
	} else if strings.TrimSpace(out) != "" {
		m.log("uncommitted files on %s backed up to %s", m.dst.Label, strings.TrimSpace(out))
	}
	m.log("copying %s to %s:%s", root, m.dst.Label, dstRoot)
	pack := "export COPYFILE_DISABLE=1; cd " + shq(root) + " || exit 1\n" + repoList +
		" | tar -cf - --null --no-recursion -T -"
	return m.stream(ctx, pack, dstRoot, nil)
}

// checkSynced compares the source's recently changed files with the target's
// copies, waits a little for the sync to catch up, then copies whatever still
// differs. Returns how many files it had to copy itself.
func (m *mover) checkSynced(ctx context.Context, root string) (int, error) {
	dstRoot, ok := mapHome(root, m.src.Home, m.dst.Home)
	if !ok {
		return 0, errors.New(root + " is outside the home directory")
	}
	// Files changed in the last 6 hours (capped below; BSD head has no -z).
	list := `cd ` + shq(root) + ` || exit 1
find . -type f -mmin -360 -not -path './.git/*' -not -path '*/node_modules/*' -not -name '._*' -not -name '.DS_Store' -print0 2>/dev/null`
	out, err := m.shOut(ctx, m.src, list, nil)
	if err != nil {
		return 0, err
	}
	files := splitNul(out)
	if len(files) == 0 {
		return 0, nil
	}
	if len(files) > 300 {
		files = files[:300]
	}
	sums := func(h Host, dir string) map[string]string {
		var stdin bytes.Buffer
		for _, f := range files {
			stdin.WriteString(f + "\x00")
		}
		script := `cd ` + shq(dir) + ` 2>/dev/null || exit 0
while IFS= read -r -d '' f; do
  if [ -f "$f" ]; then s=$( (sha256sum "$f" 2>/dev/null || shasum -a 256 "$f") | cut -d' ' -f1); printf '%s\t%s\n' "$s" "$f"; fi
done`
		o, _ := m.shOut(ctx, h, script, &stdin)
		res := map[string]string{}
		for _, line := range strings.Split(o, "\n") {
			if s, f, ok := strings.Cut(line, "\t"); ok {
				res[f] = s
			}
		}
		return res
	}
	want := sums(m.src, root)
	var diff []string
	for i := 0; i < 4; i++ {
		have := sums(m.dst, dstRoot)
		diff = diff[:0]
		for f, s := range want {
			if have[f] != s {
				diff = append(diff, f)
			}
		}
		if len(diff) == 0 {
			return 0, nil
		}
		m.log("%d recently changed files not on %s yet, waiting for the sync", len(diff), m.dst.Label)
		time.Sleep(5 * time.Second)
	}
	var stdin bytes.Buffer
	for _, f := range diff {
		stdin.WriteString(f + "\x00")
	}
	pack := "export COPYFILE_DISABLE=1; cd " + shq(root) + " && tar -cf - --null --no-recursion -T -"
	return len(diff), m.stream(ctx, pack, dstRoot, &stdin)
}

// stream runs pack on the source (a script writing a tar to stdout), passes
// the archive through rewrite when given, and unpacks it under dstDir on the
// target.
func (m *mover) stream(ctx context.Context, pack, dstDir string, stdin io.Reader) error {
	return m.streamRewrite(ctx, pack, dstDir, stdin, nil)
}

type rewriter func(hdr *tar.Header, body []byte) (*tar.Header, []byte)

func (m *mover) streamRewrite(ctx context.Context, pack, dstDir string, stdin io.Reader, rw rewriter) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	srcR, srcW := io.Pipe()
	dstR, dstW := io.Pipe()
	errc := make(chan error, 3)
	go func() {
		err := m.sh(ctx, m.src, pack, stdin, srcW)
		srcW.CloseWithError(err)
		errc <- wrap("pack on "+m.src.Label, err)
	}()
	go func() {
		err := m.sh(ctx, m.dst, "mkdir -p "+shq(dstDir)+" && tar -xf - -C "+shq(dstDir), dstR, io.Discard)
		dstR.CloseWithError(err)
		errc <- wrap("unpack on "+m.dst.Label, err)
	}()
	go func() {
		err := m.transform(srcR, dstW, rw)
		dstW.CloseWithError(err)
		if err != nil {
			srcR.CloseWithError(err)
		}
		errc <- err
	}()
	var first error
	for i := 0; i < 3; i++ {
		if err := <-errc; err != nil && first == nil {
			first = err
			cancel()
		}
	}
	return first
}

func (m *mover) transform(in io.Reader, out io.Writer, rw rewriter) error {
	tr := tar.NewReader(in)
	tw := tar.NewWriter(out)
	var total int64
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			// tar pads past its end marker; drain it or the packer blocks
			// writing into a pipe nobody reads.
			_, _ = io.Copy(io.Discard, in)
			break
		}
		if err != nil {
			return err
		}
		total += hdr.Size
		if total > m.o.MaxRepoBytes {
			return fmt.Errorf("more than %d MiB to copy; commit or ignore the large files first", m.o.MaxRepoBytes>>20)
		}
		// Drop pax xattrs (macOS quarantine, provenance) so GNU tar stays quiet.
		hdr.PAXRecords = nil
		hdr.Xattrs = nil //nolint:staticcheck
		hdr.Format = tar.FormatUnknown
		if rw != nil && hdr.Typeflag == tar.TypeReg {
			body, err := io.ReadAll(tr)
			if err != nil {
				return err
			}
			hdr, body = rw(hdr, body)
			if hdr == nil {
				continue
			}
			hdr.Size = int64(len(body))
			if err := tw.WriteHeader(hdr); err != nil {
				return err
			}
			if _, err := tw.Write(body); err != nil {
				return err
			}
			continue
		}
		if rw != nil {
			if hdr, _ = rw(hdr, nil); hdr == nil {
				continue
			}
		}
		if err := tw.WriteHeader(hdr); err != nil {
			return err
		}
		if _, err := io.Copy(tw, tr); err != nil {
			return err
		}
	}
	return tw.Close()
}

// ---------- session files ----------

func (m *mover) copySession(ctx context.Context, a agentPane, dstCwd string) error {
	paths := homeRewriter(m.src.Home, m.dst.Home)
	switch a.Agent {
	case "claude":
		find := `cd "$HOME" || exit 1
id=` + shq(a.Session) + `
t=$(ls .claude/projects/*/"$id".jsonl 2>/dev/null | head -n1)
[ -n "$t" ] || { echo "no transcript for $id under ~/.claude/projects" >&2; exit 3; }
p=$(dirname "$t")
{ printf '%s\0' "$t"
  [ -d "$p/$id" ] && find "$p/$id" -print0
  [ -d ".claude/file-history/$id" ] && find ".claude/file-history/$id" -print0
  for f in .claude/todos/"$id"*.json; do [ -e "$f" ] && printf '%s\0' "$f"; done
} | COPYFILE_DISABLE=1 tar -cf - --null --no-recursion -T -`
		dstProj := ".claude/projects/" + claudeProjectDir(dstCwd) + "/"
		rw := func(hdr *tar.Header, body []byte) (*tar.Header, []byte) {
			name := strings.TrimPrefix(hdr.Name, "./")
			if rest, ok := strings.CutPrefix(name, ".claude/projects/"); ok {
				if i := strings.IndexByte(rest, '/'); i >= 0 {
					hdr.Name = dstProj + rest[i+1:]
				}
			}
			if body != nil && textual(hdr.Name) {
				body = paths(body)
			}
			return hdr, body
		}
		return m.streamRewrite(ctx, find, m.dst.Home, nil, rw)

	case "codex":
		find := `cd "$HOME" || exit 1
t=$(find .codex/sessions -name "*` + a.Session + `*.jsonl" 2>/dev/null | head -n1)
[ -n "$t" ] || { echo "no codex rollout for ` + a.Session + `" >&2; exit 3; }
printf '%s\0' "$t" | tar -cf - --null --no-recursion -T -`
		rw := func(hdr *tar.Header, body []byte) (*tar.Header, []byte) {
			if body != nil {
				body = paths(body)
			}
			return hdr, body
		}
		return m.streamRewrite(ctx, find, m.dst.Home, nil, rw)

	case "opencode":
		out, err := m.shOut(ctx, m.src, "opencode export "+shq(a.Session), nil)
		if err != nil {
			return err
		}
		if i := strings.IndexByte(out, '{'); i > 0 {
			out = out[i:] // export prints a banner line first
		}
		data := paths([]byte(out))
		f := "/tmp/merry-handoff-" + a.Session + ".json"
		_, err = m.shOut(ctx, m.dst, "cat > "+shq(f)+" && opencode import "+shq(f)+" >/dev/null && rm -f "+shq(f), bytes.NewReader(data))
		return err
	}
	return errors.New("unsupported agent " + a.Agent)
}

func textual(name string) bool {
	return strings.HasSuffix(name, ".jsonl") || strings.HasSuffix(name, ".json") || strings.HasSuffix(name, ".txt") || strings.HasSuffix(name, ".md")
}

// ---------- start on target ----------

func (m *mover) startRemote(ctx context.Context, a agentPane, dstCwd string, flags []string) (string, error) {
	// Same workspace label if one exists there, else a new workspace.
	var pane string
	label := a.Workspace
	if label == "" {
		label = path.Base(dstCwd)
	}
	s, err := m.snapshot(ctx, m.dst)
	if err != nil {
		return "", err
	}
	wsID := ""
	for _, w := range s.Snapshot.Workspaces {
		if w.Label == label {
			wsID = w.WorkspaceID
			break
		}
	}
	// Coming back: the pane this session left from is still there as a shell
	// labelled "moved to <source>"; take it over rather than open a new tab.
	if wsID != "" {
		for _, p := range s.Snapshot.Panes {
			if p.WorkspaceID == wsID && p.Label == movedLabel(m.src.Label) && p.Agent == "" {
				pane = p.PaneID
				_, _ = m.herdr(ctx, m.dst, "pane", "rename", pane, a.Agent)
				break
			}
		}
	}
	if pane != "" {
		// reusing a pane
	} else if wsID != "" {
		raw, err := m.herdr(ctx, m.dst, "tab", "create", "--workspace", wsID, "--cwd", dstCwd, "--no-focus")
		if err != nil {
			return "", err
		}
		var t struct {
			RootPane struct {
				PaneID string `json:"pane_id"`
			} `json:"root_pane"`
		}
		_ = json.Unmarshal(raw, &t)
		pane = t.RootPane.PaneID
	} else {
		raw, err := m.herdr(ctx, m.dst, "workspace", "create", "--cwd", dstCwd, "--label", label, "--no-focus")
		if err != nil {
			return "", err
		}
		var w struct {
			RootPane struct {
				PaneID string `json:"pane_id"`
			} `json:"root_pane"`
		}
		_ = json.Unmarshal(raw, &w)
		pane = w.RootPane.PaneID
	}
	if pane == "" {
		return "", errors.New("herdr on " + m.dst.Label + " created no pane")
	}

	m.log("starting %s on %s in %s", a.Agent, m.dst.Label, pane)
	cmd := "cd " + shq(dstCwd) + " && " + launchCommand(a.Agent, a.Session, flags)
	// The fresh shell needs a moment before it takes input.
	time.Sleep(1500 * time.Millisecond)
	if _, err := m.herdr(ctx, m.dst, "pane", "run", pane, cmd); err != nil {
		return pane, err
	}
	// Confirm herdr sees the agent come up in that pane, ideally with the same
	// session id.
	deadline := time.Now().Add(45 * time.Second)
	trusted := false
	for time.Now().Before(deadline) {
		time.Sleep(2 * time.Second)
		s, err := m.snapshot(ctx, m.dst)
		if err != nil {
			continue
		}
		for _, ag := range s.Snapshot.Agents {
			if ag.PaneID != pane || ag.Agent != a.Agent {
				continue
			}
			if ag.AgentStatus != "blocked" {
				return pane, nil
			}
			// A repo copied for the first time hits Claude's folder-trust
			// prompt. The folder was trusted where the session ran, so accept
			// it, once, and only that exact prompt.
			if a.Agent == "claude" && !trusted && m.screenHas(ctx, m.dst, pane, "Yes, I trust this folder") {
				m.log("accepting the folder-trust prompt on %s (it was trusted on %s)", m.dst.Label, m.src.Label)
				_, _ = m.herdr(ctx, m.dst, "pane", "send-keys", pane, "down")
				_, _ = m.herdr(ctx, m.dst, "pane", "send-keys", pane, "enter")
				trusted = true
				continue
			}
			if trusted || time.Until(deadline) < 30*time.Second {
				// Some other prompt: leave it for the phone, it is visible there.
				return pane, nil
			}
		}
	}
	return pane, fmt.Errorf("%s did not come up in %s on %s within 45s (check that pane)", a.Agent, pane, m.dst.Label)
}

// ---------- pure helpers ----------

// resumeFlags keeps the agent's own flags and drops the ones that pick a
// session, so the resume flag added at launch is the only one.
func resumeFlags(agent string, args []string) []string {
	drop := map[string]int{} // flag -> how many values it takes
	switch agent {
	case "claude":
		drop = map[string]int{"--resume": 1, "-r": 1, "--continue": 0, "-c": 0, "--session-id": 1, "--fork-session": 0, "-p": 0, "--print": 0}
	case "codex":
		// `codex resume <id>` / `codex resume --last` as subcommand
		if len(args) > 0 && args[0] == "resume" {
			args = args[1:]
			if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
				args = args[1:]
			}
		}
		drop = map[string]int{"--last": 0}
	case "opencode":
		drop = map[string]int{"--session": 1, "-s": 1, "--continue": 0, "-c": 0, "--fork": 0}
	}
	var out []string
	for i := 0; i < len(args); i++ {
		f := args[i]
		name, _, hasEq := strings.Cut(f, "=")
		if n, ok := drop[name]; ok {
			if !hasEq && n > 0 && i+1 < len(args) && !strings.HasPrefix(args[i+1], "-") {
				i++
			}
			continue
		}
		out = append(out, f)
	}
	return out
}

func launchCommand(agent, session string, flags []string) string {
	q := make([]string, 0, len(flags))
	for _, f := range flags {
		q = append(q, shq(f))
	}
	extra := strings.Join(q, " ")
	if extra != "" {
		extra = " " + extra
	}
	switch agent {
	case "codex":
		return "codex resume " + shq(session) + extra
	case "opencode":
		return "opencode --session " + shq(session) + extra
	default:
		return "claude --resume " + shq(session) + extra
	}
}

// claudeProjectDir is Claude Code's project directory name for a cwd: every
// character outside [A-Za-z0-9] becomes '-'.
func claudeProjectDir(cwd string) string {
	b := []byte(cwd)
	for i, c := range b {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9') {
			b[i] = '-'
		}
	}
	return string(b)
}

// homeRewriter rewrites home-directory paths (and their Claude project-dir
// spelling) from one machine's home to the other's.
func homeRewriter(from, to string) func([]byte) []byte {
	pairs := [][2]string{
		{from + "/", to + "/"},
		{`"` + from + `"`, `"` + to + `"`},
		{claudeProjectDir(from) + "-", claudeProjectDir(to) + "-"},
	}
	return func(b []byte) []byte {
		for _, p := range pairs {
			b = bytes.ReplaceAll(b, []byte(p[0]), []byte(p[1]))
		}
		return b
	}
}

// mapHome translates p under fromHome to the same place under toHome.
func mapHome(p, fromHome, toHome string) (string, bool) {
	if p == fromHome {
		return toHome, true
	}
	if rest, ok := strings.CutPrefix(p, fromHome+"/"); ok {
		return toHome + "/" + rest, true
	}
	return "", false
}

func within(p, dir string) bool {
	dir = strings.TrimSuffix(dir, "/")
	return p == dir || strings.HasPrefix(p, dir+"/")
}

func expandHome(p, home string) string {
	if p == "~" {
		return home
	}
	if rest, ok := strings.CutPrefix(p, "~/"); ok {
		return home + "/" + rest
	}
	return p
}

func splitNul(s string) []string {
	var out []string
	for _, f := range strings.Split(s, "\x00") {
		if f != "" {
			out = append(out, f)
		}
	}
	return out
}

// shq single-quotes s for bash.
func shq(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

func short(id string) string {
	if len(id) > 8 {
		return id[:8]
	}
	return id
}

func wrap(what string, err error) error {
	if err == nil {
		return nil
	}
	return fmt.Errorf("%s: %w", what, err)
}

// screenHas reports whether pane's visible screen contains text.
func (m *mover) screenHas(ctx context.Context, h Host, pane, text string) bool {
	args := []string{"pane", "read", pane}
	if !h.Local() {
		args = append([]string{"--machine", h.Label}, args...)
	}
	var out bytes.Buffer
	if err := m.run(ctx, nil, &out, "herdr", args...); err != nil {
		return false
	}
	return strings.Contains(out.String(), text)
}

func (m *mover) paneStatus(ctx context.Context, h Host, pane string) string {
	s, err := m.snapshot(ctx, h)
	if err != nil {
		return ""
	}
	for _, ag := range s.Snapshot.Agents {
		if ag.PaneID == pane {
			return ag.AgentStatus
		}
	}
	return ""
}

// movedLabel names a pane a session left from. "local" is spelled as this
// machine's short hostname so the label still makes sense on the far side.
func movedLabel(to string) string {
	if to == "local" {
		if h, err := os.Hostname(); err == nil {
			to, _, _ = strings.Cut(h, ".")
		}
	}
	return "moved to " + to
}
