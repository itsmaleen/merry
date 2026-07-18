package pair

import (
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"

	qrcode "github.com/skip2/go-qrcode"
)

const tokenFile = "token"

// LoadOrCreateToken reads the pairing token from disk, generating one if absent.
func LoadOrCreateToken(configDir string) (string, error) {
	path := filepath.Join(configDir, tokenFile)

	data, err := os.ReadFile(path)
	if err == nil {
		if t := strings.TrimSpace(string(data)); t != "" {
			return t, nil
		}
	}

	// Generate 256-bit token
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", fmt.Errorf("generate token: %w", err)
	}
	token := base64.RawURLEncoding.EncodeToString(raw)

	if err := os.MkdirAll(configDir, 0o700); err != nil {
		return "", fmt.Errorf("create config dir: %w", err)
	}
	if err := os.WriteFile(path, []byte(token+"\n"), 0o600); err != nil {
		return "", fmt.Errorf("write token: %w", err)
	}
	return token, nil
}

// PrintQR generates and prints the pairing QR code to stdout.
// tailscaleHost is optional; if non-empty it's included in the QR URL.
func PrintQR(host string, port int, token string, tailscaleHost string) error {
	if host == "" {
		host = primaryLANIP()
	}

	url := fmt.Sprintf("cmux-bridge://pair?host=%s&port=%d&token=%s", host, port, token)
	if tailscaleHost != "" {
		url += "&tailscale_host=" + tailscaleHost
	}

	qr, err := qrcode.New(url, qrcode.Medium)
	if err != nil {
		return fmt.Errorf("generate qr: %w", err)
	}

	art := qr.ToString(false)

	fmt.Println()
	fmt.Println("┌─────────────────────────────────────────┐")
	fmt.Println("│         Scan to pair cmux companion      │")
	fmt.Println("└─────────────────────────────────────────┘")
	fmt.Println(art)
	fmt.Printf("URL: %s\n\n", url)

	// Make the remote-access state unmistakable — pairing without a tailnet host
	// is the #1 reason the phone works on Wi-Fi but is stuck "reconnecting" off it.
	if tailscaleHost != "" {
		fmt.Printf("✓ Remote access: this pairing includes tailnet host %q,\n", tailscaleHost)
		fmt.Println("  so the phone can reach the bridge off Wi-Fi (needs Tailscale on the phone).")
	} else {
		fmt.Println("⚠ LAN ONLY: this pairing has NO Tailscale host — the phone will only")
		fmt.Println("  connect on the same Wi-Fi and will show \"reconnecting\" elsewhere.")
		fmt.Println("  For remote access, re-run:  cmux-bridge --pair --tailscale")
	}
	fmt.Println()

	return nil
}

// primaryLANIP returns the best non-loopback IPv4 address of this machine.
func primaryLANIP() string {
	ifaces, err := net.Interfaces()
	if err != nil {
		return "127.0.0.1"
	}
	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			var ip net.IP
			switch v := addr.(type) {
			case *net.IPNet:
				ip = v.IP
			case *net.IPAddr:
				ip = v.IP
			}
			if ip == nil || ip.IsLoopback() {
				continue
			}
			if ip4 := ip.To4(); ip4 != nil {
				return ip4.String()
			}
		}
	}
	return "127.0.0.1"
}
