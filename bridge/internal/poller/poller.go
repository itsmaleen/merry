package poller

import (
	"encoding/json"
	"log"
	"sync"
	"time"

	"github.com/itsmaleen/cmux-companion/bridge/internal/backend"
	"github.com/itsmaleen/cmux-companion/bridge/internal/socket"
)

// Notification mirrors the fields we care about from cmux's notification object.
type Notification struct {
	ID          string `json:"id"`
	Title       string `json:"title"`
	Subtitle    string `json:"subtitle"`
	Body        string `json:"body"`
	WorkspaceID string `json:"workspace_id"`
	SurfaceID   string `json:"surface_id"`
	IsRead      bool   `json:"is_read"`
}

// Event is the push-event type the poller publishes; it is the backend Hub's.
type Event = backend.Event

// Poller polls cmux's notification.list on an interval and publishes each
// unseen notification to the Hub as a notification.created event.
type Poller struct {
	client   *socket.Client
	interval time.Duration
	hub      *backend.Hub

	mu      sync.Mutex
	seenIDs map[string]struct{}
	// Bumped by ResetSeenIDs. A poll captures it before its network call and
	// discards its result if it changed meanwhile, so a notification.list issued
	// before a clear can't repopulate seenIDs with pre-clear IDs afterward.
	generation uint64
}

func New(client *socket.Client, interval time.Duration, hub *backend.Hub) *Poller {
	if hub == nil {
		hub = backend.NewHub()
	}
	return &Poller{
		client:   client,
		interval: interval,
		hub:      hub,
		seenIDs:  make(map[string]struct{}),
	}
}

// Hub returns the hub this poller publishes to.
func (p *Poller) Hub() *backend.Hub { return p.hub }

// Broadcast publishes an event to every subscriber of the poller's hub.
func (p *Poller) Broadcast(ev Event) { p.hub.Broadcast(ev) }

// Run starts the polling loop. It blocks until stop is closed.
func (p *Poller) Run(stop <-chan struct{}) {
	ticker := time.NewTicker(p.interval)
	defer ticker.Stop()

	for {
		select {
		case <-stop:
			return
		case <-ticker.C:
			p.poll()
		}
	}
}

func (p *Poller) poll() {
	// Capture the generation before the network call; if a clear lands while
	// we're waiting on cmux, ingest() will discard this now-stale result.
	p.mu.Lock()
	gen := p.generation
	p.mu.Unlock()

	result, err := p.client.Send("notification.list", nil)
	if err != nil {
		log.Printf("poller: notification.list error: %v", err)
		return
	}

	var payload struct {
		Notifications []Notification `json:"notifications"`
	}
	if err := json.Unmarshal(result, &payload); err != nil {
		log.Printf("poller: parse error: %v", err)
		return
	}

	newOnes, ok := p.ingest(payload.Notifications, gen)
	if !ok {
		return
	}
	for _, n := range newOnes {
		p.hub.Broadcast(Event{Type: "notification.created", Data: n})
	}
}

// ingest records unseen notifications and returns the new ones. ok is false
// when the generation changed since the poll began (a notification.clear
// happened mid-flight): the whole batch is discarded so stale IDs don't get
// re-marked as seen.
func (p *Poller) ingest(notifs []Notification, gen uint64) (newOnes []Notification, ok bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.generation != gen {
		return nil, false
	}
	for _, n := range notifs {
		if _, seen := p.seenIDs[n.ID]; !seen {
			p.seenIDs[n.ID] = struct{}{}
			newOnes = append(newOnes, n)
		}
	}
	return newOnes, true
}

// ResetSeenIDs clears the seen-ID set. Called after notification.clear so that
// notifications which reappear after a clear ARE emitted again. Bumping the
// generation also invalidates any notification.list poll already in flight.
func (p *Poller) ResetSeenIDs() {
	p.mu.Lock()
	p.seenIDs = make(map[string]struct{})
	p.generation++
	p.mu.Unlock()
}
