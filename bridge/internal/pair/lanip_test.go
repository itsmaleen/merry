package pair

import (
	"net"
	"testing"
)

func cand(iface, ip string) lanCandidate {
	return lanCandidate{iface: iface, ip: net.ParseIP(ip)}
}

func TestPickLANIP(t *testing.T) {
	tests := []struct {
		name  string
		cands []lanCandidate
		want  string
	}{
		{
			// WSL mirrored networking lists the Windows host's tailnet address
			// on eth0 ahead of the real LAN address on eth1.
			name:  "wsl mirrored skips tailnet address on eth0",
			cands: []lanCandidate{cand("lo", "127.0.0.1"), cand("eth0", "100.120.252.118"), cand("eth1", "192.168.1.38")},
			want:  "192.168.1.38",
		},
		{
			name:  "docker bridge is not the LAN",
			cands: []lanCandidate{cand("docker0", "172.17.0.1"), cand("en0", "10.0.0.12")},
			want:  "10.0.0.12",
		},
		{
			name:  "tailscale interface is skipped by name",
			cands: []lanCandidate{cand("tailscale0", "100.100.1.1"), cand("wlan0", "192.168.0.20")},
			want:  "192.168.0.20",
		},
		{
			name:  "private address preferred over public",
			cands: []lanCandidate{cand("eth0", "203.0.113.5"), cand("eth1", "192.168.1.9")},
			want:  "192.168.1.9",
		},
		{
			// The token goes over plaintext ws://, so never advertise a public address.
			name:  "public address only yields nothing",
			cands: []lanCandidate{cand("eth0", "203.0.113.5")},
			want:  "",
		},
		{
			name:  "link-local and IPv6 only yields nothing",
			cands: []lanCandidate{cand("eth0", "169.254.10.1"), cand("eth0", "fe80::1"), cand("eth0", "fd00::2")},
			want:  "",
		},
		{
			name:  "tailnet only yields nothing",
			cands: []lanCandidate{cand("eth0", "100.64.0.7")},
			want:  "",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := pickLANIP(tt.cands); got != tt.want {
				t.Fatalf("pickLANIP = %q, want %q", got, tt.want)
			}
		})
	}
}
