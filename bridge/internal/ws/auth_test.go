package ws

import (
	"net/http"
	"testing"
)

func reqWithHeader(value string) *http.Request {
	r, _ := http.NewRequest("GET", "http://example/ws", nil)
	if value != "" {
		r.Header.Set("Authorization", value)
	}
	return r
}

func reqWithQuery(token string) *http.Request {
	r, _ := http.NewRequest("GET", "http://example/ws?token="+token, nil)
	return r
}

func TestValidateBearer(t *testing.T) {
	const token = "s3cr3t-token-value"

	cases := []struct {
		name string
		req  *http.Request
		want bool
	}{
		{"valid header", reqWithHeader("Bearer " + token), true},
		{"valid query param", reqWithQuery(token), true},
		{"wrong token", reqWithHeader("Bearer nope"), false},
		{"wrong query token", reqWithQuery("nope"), false},
		{"empty bearer", reqWithHeader("Bearer "), false},
		{"missing prefix", reqWithHeader(token), false},
		{"no auth at all", reqWithHeader(""), false},
		{"prefix of token", reqWithHeader("Bearer " + token[:len(token)-1]), false},
		{"token plus suffix", reqWithHeader("Bearer " + token + "x"), false},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := validateBearer(tc.req, token); got != tc.want {
				t.Fatalf("validateBearer = %v, want %v", got, tc.want)
			}
		})
	}
}

// An empty configured token must never authenticate, even if a client sends
// an empty bearer — otherwise a misconfigured bridge would be wide open.
func TestValidateBearerEmptyTokenRejects(t *testing.T) {
	if validateBearer(reqWithHeader("Bearer "), "") {
		t.Fatal("empty token accepted an empty bearer")
	}
	if validateBearer(reqWithQuery(""), "") {
		t.Fatal("empty token accepted an empty query token")
	}
}
