package pair

import (
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	qrcode "github.com/skip2/go-qrcode"
)

const tokenFile = "token"

// LoadOrCreateToken reads the pairing token from disk, generating one if absent.
//
// The token is the bridge's only authentication, so an existing file is only
// trusted when it — and the directory holding it — belong to this user and
// are private: a pre-created world-writable directory (say, a predictable
// path under /tmp handed to --config-dir) must not be able to plant a token
// the bridge then accepts from the network.
func LoadOrCreateToken(configDir string) (string, error) {
	if err := EnsurePrivateDir(configDir); err != nil {
		return "", err
	}
	path := filepath.Join(configDir, tokenFile)

	info, err := os.Lstat(path)
	if err == nil {
		if err := checkPrivateFile(path, info); err != nil {
			return "", err
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return "", fmt.Errorf("read token: %w", err)
		}
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

	// Exclusive create: never follow a symlink or overwrite something that
	// appeared between the stat above and here.
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL|os.O_TRUNC, 0o600)
	if err != nil {
		return "", fmt.Errorf("write token: %w", err)
	}
	if _, err := f.WriteString(token + "\n"); err != nil {
		f.Close()
		return "", fmt.Errorf("write token: %w", err)
	}
	if err := f.Close(); err != nil {
		return "", fmt.Errorf("write token: %w", err)
	}
	return token, nil
}

// EnsurePrivateDir creates dir (0700) if missing and otherwise requires it to
// be a real directory (not a symlink) owned by the current user with no
// group/other permission bits — the config directory holds the pairing token
// and the socket/port configuration.
func EnsurePrivateDir(dir string) error {
	info, err := os.Lstat(dir)
	if os.IsNotExist(err) {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return fmt.Errorf("create config dir: %w", err)
		}
		info, err = os.Lstat(dir)
	}
	if err != nil {
		return fmt.Errorf("config dir %s: %w", dir, err)
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("config dir %s is a symlink; refusing to use it", dir)
	}
	if !info.IsDir() {
		return fmt.Errorf("config dir %s is not a directory", dir)
	}
	if err := checkOwnedByUs(dir, info); err != nil {
		return err
	}
	if perm := info.Mode().Perm(); perm&0o077 != 0 {
		return fmt.Errorf("config dir %s is accessible to other users (mode %04o); run: chmod 700 %s", dir, perm, dir)
	}
	return nil
}

func checkPrivateFile(path string, info os.FileInfo) error {
	if info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("token file %s is a symlink; refusing to use it", path)
	}
	if !info.Mode().IsRegular() {
		return fmt.Errorf("token file %s is not a regular file", path)
	}
	if err := checkOwnedByUs(path, info); err != nil {
		return err
	}
	if perm := info.Mode().Perm(); perm&0o077 != 0 {
		return fmt.Errorf("token file %s is readable by other users (mode %04o); run: chmod 600 %s", path, perm, path)
	}
	return nil
}

func checkOwnedByUs(path string, info os.FileInfo) error {
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return nil // no ownership info on this platform
	}
	if int(st.Uid) != os.Geteuid() {
		return fmt.Errorf("%s is owned by uid %d, not by this user (uid %d); refusing to use it", path, st.Uid, os.Geteuid())
	}
	return nil
}

// PrintQR generates and prints the pairing QR code to stdout.
// tailscaleHost is optional; if non-empty it's included in the QR URL.
// backend names the runtime the bridge fronts ("cmux", "herdr"); it is
// informational for the phone, which learns the live value on connect.
func PrintQR(host string, port int, token string, tailscaleHost string, backend string) error {
	if host == "" {
		host = primaryLANIP()
	}

	url := fmt.Sprintf("merry-bridge://pair?host=%s&port=%d&token=%s", host, port, token)
	if tailscaleHost != "" {
		url += "&tailscale_host=" + tailscaleHost
	}
	if backend != "" {
		url += "&backend=" + backend
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
		fmt.Println("  For remote access, re-run:  merry-bridge --pair --tailscale")
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
