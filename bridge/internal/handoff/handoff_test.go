package handoff

import (
	"archive/tar"
	"bytes"
	"io"
	"reflect"
	"testing"
)

func TestResumeFlags(t *testing.T) {
	cases := []struct {
		agent string
		in    []string
		want  []string
	}{
		{"claude", []string{"--dangerously-skip-permissions"}, []string{"--dangerously-skip-permissions"}},
		{"claude", []string{"--resume", "abc", "--model", "haiku", "-c"}, []string{"--model", "haiku"}},
		{"claude", []string{"--resume=abc", "--permission-mode", "auto"}, []string{"--permission-mode", "auto"}},
		{"claude", []string{"-r", "--model", "opus"}, []string{"--model", "opus"}}, // bare -r opens the picker
		{"codex", []string{"resume", "019a", "--yolo"}, []string{"--yolo"}},
		{"codex", []string{"resume", "--last"}, nil},
		{"opencode", []string{"-s", "ses_1", "--model", "x"}, []string{"--model", "x"}},
	}
	for _, c := range cases {
		if got := resumeFlags(c.agent, c.in); !reflect.DeepEqual(got, c.want) {
			t.Errorf("resumeFlags(%s, %q) = %q, want %q", c.agent, c.in, got, c.want)
		}
	}
}

func TestLaunchCommandQuotes(t *testing.T) {
	got := launchCommand("claude", "d5d0", []string{"--append-system-prompt", "it's fine"})
	want := `claude --resume 'd5d0' '--append-system-prompt' 'it'\''s fine'`
	if got != want {
		t.Fatalf("got %s\nwant %s", got, want)
	}
}

func TestClaudeProjectDir(t *testing.T) {
	if got := claudeProjectDir("/home/marlin/work/a_b.c"); got != "-home-marlin-work-a-b-c" {
		t.Fatal(got)
	}
}

func TestMapHome(t *testing.T) {
	if p, ok := mapHome("/Users/marlin/x/y", "/Users/marlin", "/home/marlin"); !ok || p != "/home/marlin/x/y" {
		t.Fatal(p, ok)
	}
	if _, ok := mapHome("/Users/marlinx/y", "/Users/marlin", "/home/marlin"); ok {
		t.Fatal("prefix without a slash must not map")
	}
	if _, ok := mapHome("/tmp/x", "/Users/marlin", "/home/marlin"); ok {
		t.Fatal("outside home must not map")
	}
}

func TestHomeRewriter(t *testing.T) {
	rw := homeRewriter("/Users/marlin", "/home/marlin")
	in := `{"cwd":"/Users/marlin/wrinkles","home":"/Users/marlin","p":"~/.claude/projects/-Users-marlin-wrinkles/x","other":"/Users/marlinx"}`
	want := `{"cwd":"/home/marlin/wrinkles","home":"/home/marlin","p":"~/.claude/projects/-home-marlin-wrinkles/x","other":"/Users/marlinx"}`
	if got := string(rw([]byte(in))); got != want {
		t.Fatalf("got  %s\nwant %s", got, want)
	}
}

// The transform must consume tar's trailing padding, or the packing process
// blocks on a full pipe (the hang found in the first live run).
func TestTransformDrainsPadding(t *testing.T) {
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	body := []byte(`{"cwd":"/Users/marlin/r"}`)
	_ = tw.WriteHeader(&tar.Header{Name: ".claude/projects/-Users-marlin-r/s.jsonl", Mode: 0o644, Size: int64(len(body)), Typeflag: tar.TypeReg})
	_, _ = tw.Write(body)
	_ = tw.Close()
	buf.Write(make([]byte, 8192)) // record padding, as bsdtar/GNU tar emit
	in := bytes.NewReader(buf.Bytes())

	m := &mover{o: Options{MaxRepoBytes: 1 << 20}}
	var out bytes.Buffer
	rw := func(h *tar.Header, b []byte) (*tar.Header, []byte) {
		h.Name = ".claude/projects/-home-marlin-r/s.jsonl"
		return h, homeRewriter("/Users/marlin", "/home/marlin")(b)
	}
	if err := m.transform(in, &out, rw); err != nil {
		t.Fatal(err)
	}
	if in.Len() != 0 {
		t.Fatalf("%d bytes left unread", in.Len())
	}
	tr := tar.NewReader(&out)
	h, err := tr.Next()
	if err != nil {
		t.Fatal(err)
	}
	got, _ := io.ReadAll(tr)
	if h.Name != ".claude/projects/-home-marlin-r/s.jsonl" || string(got) != `{"cwd":"/home/marlin/r"}` {
		t.Fatalf("%s %s", h.Name, got)
	}
}

func TestTransformSizeCap(t *testing.T) {
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	_ = tw.WriteHeader(&tar.Header{Name: "big", Mode: 0o644, Size: 100, Typeflag: tar.TypeReg})
	_, _ = tw.Write(make([]byte, 100))
	_ = tw.Close()
	m := &mover{o: Options{MaxRepoBytes: 50}}
	if err := m.transform(&buf, io.Discard, nil); err == nil {
		t.Fatal("want a size-cap error")
	}
}
