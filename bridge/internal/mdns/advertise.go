package mdns

import (
	"fmt"
	"log"
	"os"

	"github.com/hashicorp/mdns"
)

// Advertise starts a Bonjour _merry-bridge._tcp service advertisement on the
// given port. It returns a stop function that shuts the advertisement down.
func Advertise(port int) (stop func(), err error) {
	hostname, _ := os.Hostname()

	info := []string{
		"version=1",
		fmt.Sprintf("host=%s", hostname),
	}

	service, err := mdns.NewMDNSService(
		hostname,         // instance name
		"_merry-bridge._tcp", // service type
		"",               // domain (empty = .local.)
		"",               // host name (empty = system default)
		port,
		nil, // IPs (nil = all interfaces)
		info,
	)
	if err != nil {
		return nil, fmt.Errorf("mdns service: %w", err)
	}

	server, err := mdns.NewServer(&mdns.Config{Zone: service})
	if err != nil {
		return nil, fmt.Errorf("mdns server: %w", err)
	}

	log.Printf("mdns: advertising _merry-bridge._tcp on port %d", port)

	return func() { _ = server.Shutdown() }, nil
}
