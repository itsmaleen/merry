package poller

import (
	"encoding/json"
	"log"
	"sync"
	"time"

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

// Event is emitted by the poller to subscribers.
// Data is any so that non-notification events (cmux.connected, cmux.disconnected)
// can also be broadcast through the same channel.
type Event struct {
	Type string
	Data any
}

// Poller polls notification.list on an interval and broadcasts new events.
type Poller struct {
	client   *socket.Client
	interval time.Duration

	mu          sync.Mutex
	subscribers []chan Event
	seenIDs     map[string]struct{}
}

func New(client *socket.Client, interval time.Duration) *Poller {
	return &Poller{
		client:   client,
		interval: interval,
		seenIDs:  make(map[string]struct{}),
	}
}

// Subscribe returns a buffered channel that receives events.
// Slow consumers drop events rather than blocking the poller.
func (p *Poller) Subscribe() <-chan Event {
	ch := make(chan Event, 32)
	p.mu.Lock()
	p.subscribers = append(p.subscribers, ch)
	p.mu.Unlock()
	return ch
}

// Unsubscribe removes a subscriber. The channel is NOT closed — closing a
// channel that the poller might concurrently be sending to causes a panic.
// The WS handler detects disconnection via other signals (ctx, incoming closed).
func (p *Poller) Unsubscribe(ch <-chan Event) {
	p.mu.Lock()
	defer p.mu.Unlock()
	for i, sub := range p.subscribers {
		if sub == ch {
			p.subscribers = append(p.subscribers[:i], p.subscribers[i+1:]...)
			return
		}
	}
}

// Broadcast sends an event to all current subscribers directly.
// Used to push cmux connection state changes.
func (p *Poller) Broadcast(ev Event) {
	p.mu.Lock()
	subs := make([]chan Event, len(p.subscribers))
	copy(subs, p.subscribers)
	p.mu.Unlock()

	for _, sub := range subs {
		select {
		case sub <- ev:
		default:
			// slow consumer; drop
		}
	}
}

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

	p.mu.Lock()
	var newOnes []Notification
	for _, n := range payload.Notifications {
		if _, seen := p.seenIDs[n.ID]; !seen {
			p.seenIDs[n.ID] = struct{}{}
			newOnes = append(newOnes, n)
		}
	}
	subs := make([]chan Event, len(p.subscribers))
	copy(subs, p.subscribers)
	p.mu.Unlock()

	for _, n := range newOnes {
		ev := Event{Type: "notification.created", Data: n}
		for _, sub := range subs {
			select {
			case sub <- ev:
			default:
				// slow consumer; drop
			}
		}
	}
}

// ResetSeenIDs clears the seen-ID set. Called after notification.clear so that
// notifications which reappear after a clear ARE emitted again.
func (p *Poller) ResetSeenIDs() {
	p.mu.Lock()
	p.seenIDs = make(map[string]struct{})
	p.mu.Unlock()
}
