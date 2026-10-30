package pair

import (
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"net"
	"os"
	"os/exec"
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
	if host == "" {
		// No reachable LAN address (WSL NAT, VPN-only box): point the LAN
		// field at the tailnet host too, so the phone never tries a dead route.
		host = tailscaleHost
	}
	if host == "" {
		return fmt.Errorf("no address the phone can reach: this machine has no private LAN address " +
			"(WSL NAT networking, or a public-only host). Re-run with --tailscale for remote access, " +
			"or switch WSL to networkingMode=mirrored")
	}

	url := fmt.Sprintf("cmux-bridge://pair?host=%s&port=%d&token=%s", host, port, token)
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
		fmt.Println("  For remote access, re-run:  cmux-bridge --pair --tailscale")
	}
	fmt.Println()

	return nil
}

// primaryLANIP returns the IPv4 address the phone should use to reach this
// machine on the local network, or "" when there is none it could reach.
func primaryLANIP() string {
	if wslNATMode() {
		// Under WSL's default NAT networking every address inside the distro
		// is on a virtual switch the phone can never route to. Return nothing
		// so the pairing falls back to the tailnet host.
		return ""
	}
	ifaces, err := net.Interfaces()
	if err != nil {
		return ""
	}
	var cands []lanCandidate
	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			switch v := addr.(type) {
			case *net.IPNet:
				cands = append(cands, lanCandidate{iface: iface.Name, ip: v.IP})
			case *net.IPAddr:
				cands = append(cands, lanCandidate{iface: iface.Name, ip: v.IP})
			}
		}
	}
	return pickLANIP(cands)
}

type lanCandidate struct {
	iface string
	ip    net.IP
}

// virtualIfacePrefixes name interfaces whose addresses a phone on the Wi-Fi
// cannot reach: container bridges, VM switches and VPN tunnels.
var virtualIfacePrefixes = []string{"docker", "br-", "veth", "virbr", "cni", "flannel", "tailscale", "utun", "wg", "zt"}

// tailnetRange is the CGNAT block Tailscale hands out. An address in it is a
// tailnet address, not a LAN one, even when it sits on an ordinary-looking
// interface (WSL's mirrored networking presents it as eth0).
var tailnetRange = &net.IPNet{IP: net.IPv4(100, 64, 0, 0), Mask: net.CIDRMask(10, 32)}

// pickLANIP chooses the first private IPv4 address on a physical-looking
// interface. Public addresses never qualify: the pairing token travels over
// plaintext ws://, so a public-only host must pair through the tailnet. It
// returns "" when nothing qualifies.
func pickLANIP(cands []lanCandidate) string {
	for _, c := range cands {
		ip4 := c.ip.To4()
		if ip4 == nil || ip4.IsLoopback() || ip4.IsLinkLocalUnicast() || tailnetRange.Contains(ip4) {
			continue
		}
		if isVirtualIface(c.iface) {
			continue
		}
		if ip4.IsPrivate() {
			return ip4.String()
		}
	}
	return ""
}

func isVirtualIface(name string) bool {
	for _, p := range virtualIfacePrefixes {
		if strings.HasPrefix(name, p) {
			return true
		}
	}
	return false
}

// wslNATMode reports whether this is a WSL2 distro using NAT networking.
// Mirrored mode shares the Windows host's addresses, so it is not NAT.
var wslNATMode = func() bool {
	// The kernel release ("...-microsoft-standard-WSL2") is present even when
	// interop, and with it the binfmt_misc WSLInterop marker, is turned off.
	release, err := os.ReadFile("/proc/sys/kernel/osrelease")
	if err != nil || !strings.Contains(strings.ToLower(string(release)), "wsl2") {
		return false
	}
	out, err := exec.Command("wslinfo", "--networking-mode").Output()
	if err != nil {
		// Older WSL without wslinfo only had NAT networking.
		return true
	}
	return strings.TrimSpace(string(out)) == "nat"
}
