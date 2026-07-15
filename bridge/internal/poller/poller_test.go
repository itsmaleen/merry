package poller

import "testing"

func notifs(ids ...string) []Notification {
	out := make([]Notification, len(ids))
	for i, id := range ids {
		out[i] = Notification{ID: id}
	}
	return out
}

func ids(ns []Notification) []string {
	out := make([]string, len(ns))
	for i, n := range ns {
		out[i] = n.ID
	}
	return out
}

func TestIngestDedupes(t *testing.T) {
	p := New(nil, 0)
	gen := p.generation

	first, _ := p.ingest(notifs("a", "b"), gen)
	if got := ids(first); len(got) != 2 {
		t.Fatalf("first ingest returned %v, want [a b]", got)
	}
	// Same IDs again — already seen, nothing new.
	second, _ := p.ingest(notifs("a", "b"), gen)
	if len(second) != 0 {
		t.Fatalf("second ingest returned %v, want none", ids(second))
	}
	// A genuinely new ID surfaces.
	third, _ := p.ingest(notifs("a", "b", "c"), gen)
	if got := ids(third); len(got) != 1 || got[0] != "c" {
		t.Fatalf("third ingest returned %v, want [c]", got)
	}
}

func TestResetSeenIDsReEmits(t *testing.T) {
	p := New(nil, 0)
	gen := p.generation
	p.ingest(notifs("a"), gen)

	p.ResetSeenIDs()
	// After a clear, the same notification must be emitted again — using the
	// NEW generation, as a fresh poll would.
	again, _ := p.ingest(notifs("a"), p.generation)
	if got := ids(again); len(got) != 1 || got[0] != "a" {
		t.Fatalf("post-reset ingest returned %v, want [a] (re-emit)", got)
	}
}

// The TOCTOU guard: a poll that captured its generation BEFORE a clear must be
// discarded — it must not re-mark the just-cleared IDs as seen (which would
// suppress the re-emit the clear is meant to produce).
func TestIngestDiscardsStaleGeneration(t *testing.T) {
	p := New(nil, 0)
	staleGen := p.generation // captured before the clear

	// A clear happens while the poll's notification.list is in flight.
	p.ResetSeenIDs()

	// The in-flight result arrives with the pre-clear generation → discarded.
	discarded, subs := p.ingest(notifs("a", "b"), staleGen)
	if discarded != nil || subs != nil {
		t.Fatalf("stale-generation ingest returned %v/%v, want nil/nil", ids(discarded), subs)
	}
	// seenIDs must remain empty, so a subsequent fresh poll re-emits.
	fresh, _ := p.ingest(notifs("a", "b"), p.generation)
	if got := ids(fresh); len(got) != 2 {
		t.Fatalf("fresh ingest after discard returned %v, want [a b]", got)
	}
}
