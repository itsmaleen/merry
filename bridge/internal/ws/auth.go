package ws

import (
	"crypto/subtle"
	"net/http"
	"strings"
)

// validateBearer checks the Authorization header against the expected token.
// Returns true if the request is authenticated.
func validateBearer(r *http.Request, token string) bool {
	auth := r.Header.Get("Authorization")
	if auth == "" {
		// Also accept token as a query parameter for clients that can't set headers
		// (e.g. browser WebSocket API). The token must still be the same value.
		auth = "Bearer " + r.URL.Query().Get("token")
	}
	if !strings.HasPrefix(auth, "Bearer ") {
		return false
	}
	provided := strings.TrimPrefix(auth, "Bearer ")
	return provided != "" && subtle.ConstantTimeCompare([]byte(provided), []byte(token)) == 1
}
