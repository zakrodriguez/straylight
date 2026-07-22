// cf-pqc-probe: connects to a host:port with TLS 1.3 + X25519MLKEM768 as
// the only offered key-exchange group. Success → server supports PQC.
// Failure → server does not. Emits a single JSON line on stdout.
//
// Used by the cloudflare_pqc Ansible role on scanner1 to probe public CF
// PQC endpoints. The Go-stdlib MLKEM impl is upstreamed from Cloudflare's
// CIRCL library, so the "stack" we report is effectively the same.
package main

import (
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"os"
	"time"
)

type Result struct {
	Endpoint           string `json:"endpoint"`
	Stack              string `json:"stack"`
	Success            bool   `json:"success"`
	TLSVersion         string `json:"tls_version,omitempty"`
	Cipher             string `json:"cipher,omitempty"`
	KexGroupOffered    string `json:"kex_group_offered,omitempty"`
	HandshakeMs        int64  `json:"handshake_ms,omitempty"`
	CertFprintSHA256   string `json:"server_cert_fingerprint_sha256,omitempty"`
	CertIssuer         string `json:"server_cert_issuer,omitempty"`
	Error              string `json:"error,omitempty"`
}

func tlsVersionName(v uint16) string {
	switch v {
	case tls.VersionTLS13:
		return "TLSv1.3"
	case tls.VersionTLS12:
		return "TLSv1.2"
	default:
		return fmt.Sprintf("0x%04x", v)
	}
}

// Exit codes:
//   0 — probe completed; success/failure reflected in JSON "success" field
//   2 — usage error or fatal probe error (no JSON emitted)
func main() {
	endpoint := flag.String("endpoint", "", "host:port to probe (e.g. cloudflare.com:443)")
	flag.Parse()
	if *endpoint == "" {
		fmt.Fprintln(os.Stderr, "usage: cf-pqc-probe --endpoint host:port")
		os.Exit(2)
	}

	// Note: IPv6 literals MUST be bracketed (e.g. "[2606:4700::1111]" or
	// "[2606:4700::1111]:443") because net.SplitHostPort cannot otherwise
	// disambiguate the trailing hextet from a port.
	host, _, err := net.SplitHostPort(*endpoint)
	if err != nil {
		// Allow bare hostname; default to :443.
		host = *endpoint
		*endpoint = *endpoint + ":443"
	}

	result := Result{
		Endpoint:        *endpoint,
		Stack:           "go-stdlib-mlkem",
		KexGroupOffered: "X25519MLKEM768",
	}

	cfg := &tls.Config{
		ServerName:       host,
		CurvePreferences: []tls.CurveID{tls.X25519MLKEM768},
		MinVersion:       tls.VersionTLS13,
	}

	dialer := &net.Dialer{Timeout: 10 * time.Second}
	start := time.Now()
	conn, err := tls.DialWithDialer(dialer, "tcp", *endpoint, cfg)
	elapsed := time.Since(start)

	if err != nil {
		result.Error = err.Error()
		_ = json.NewEncoder(os.Stdout).Encode(result)
		os.Exit(0)
	}
	defer conn.Close()

	state := conn.ConnectionState()
	result.Success = true
	result.HandshakeMs = elapsed.Milliseconds()
	result.TLSVersion = tlsVersionName(state.Version)
	result.Cipher = tls.CipherSuiteName(state.CipherSuite)
	if len(state.PeerCertificates) > 0 {
		c := state.PeerCertificates[0]
		fp := sha256.Sum256(c.Raw)
		result.CertFprintSHA256 = hex.EncodeToString(fp[:])
		result.CertIssuer = c.Issuer.String()
	}

	_ = json.NewEncoder(os.Stdout).Encode(result)
}
