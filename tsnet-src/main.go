// tsnet — userspace Tailscale portable binary
// Connects to Tailscale with no admin rights and no WinTun driver.
// Uses the real Tailscale control plane (standard HTTPS on 443).
//
// Commands:
//   tsnet up              Connect to Tailscale (opens browser for auth if needed)
//   tsnet status          List Tailscale peers as JSON
//   tsnet proxy <h> <p>   TCP proxy for SSH ProxyCommand
//   tsnet version
//
// SSH config example:
//   Host *.tailnet
//     ProxyCommand path\to\tsnet.exe proxy %h %p
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"tailscale.com/tsnet"
)

const version = "1.1.0"

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(1)
	}

	switch os.Args[1] {
	case "up":
		cmdUp()
	case "status":
		cmdStatus()
	case "proxy":
		if len(os.Args) < 3 {
			fmt.Fprintln(os.Stderr, "Usage: tsnet proxy <host:port>  OR  tsnet proxy <host> <port>")
			os.Exit(1)
		}
		target := os.Args[2]
		if len(os.Args) >= 4 {
			target = os.Args[2] + ":" + os.Args[3]
		}
		cmdProxy(target)
	case "version", "--version", "-v":
		fmt.Println(version)
	default:
		usage()
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintf(os.Stderr, `tsnet %s — userspace Tailscale (no admin, no WinTun)

Commands:
  up                   Connect to Tailscale, open auth URL in browser if needed
  status               Print peer list as JSON
  proxy <host> <port>  Pipe stdin/stdout to a Tailscale peer (SSH ProxyCommand)
  version

State is stored in keys/tsnet-state/ (persists auth across runs).

SSH config example:
  Host *
    ProxyCommand C:\path\to\tsnet.exe proxy %%h %%p
`, version)
}

// ── paths ─────────────────────────────────────────────────────────────────────

func binDir() string {
	exe, err := os.Executable()
	if err != nil {
		return "."
	}
	return filepath.Dir(exe)
}

func stateDir() string {
	dir := filepath.Join(binDir(), "..", "keys", "tsnet-state")
	os.MkdirAll(dir, 0700)
	return dir
}

// ── server ────────────────────────────────────────────────────────────────────

var reNotDNS = regexp.MustCompile(`[^a-z0-9\-]`)

// sanitizeHostname makes a system hostname safe for Tailscale (DNS-compatible).
// "CORP-WORKSTATION.domain.example.com" → "corp-workstation"
func sanitizeHostname(h string) string {
	h = strings.ToLower(h)
	// Use only the first label (strip any domain suffix)
	if dot := strings.IndexByte(h, '.'); dot > 0 {
		h = h[:dot]
	}
	h = reNotDNS.ReplaceAllString(h, "-")
	h = strings.Trim(h, "-")
	if len(h) > 63 {
		h = h[:63]
	}
	if h == "" {
		return "device"
	}
	return h
}

func newServer() *tsnet.Server {
	raw, _ := os.Hostname()
	hostname := sanitizeHostname(raw)
	return &tsnet.Server{
		Dir:      stateDir(),
		Hostname: hostname,
		Logf:     func(string, ...interface{}) {}, // suppress internal logs
	}
}

// ── auth / connection wait ────────────────────────────────────────────────────

// waitRunning polls until the tsnet server reaches Running state.
// Prints the auth URL if NeedsLogin, and tries to open it in the browser.
func waitRunning(ctx context.Context, srv *tsnet.Server) error {
	lc, err := srv.LocalClient()
	if err != nil {
		return fmt.Errorf("LocalClient: %w", err)
	}

	lastURL := ""
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		st, err := lc.Status(ctx)
		if err != nil {
			time.Sleep(500 * time.Millisecond)
			continue
		}

		switch st.BackendState {
		case "Running":
			return nil
		case "NeedsLogin":
			if st.AuthURL != "" && st.AuthURL != lastURL {
				lastURL = st.AuthURL
				fmt.Fprintln(os.Stderr, "")
				fmt.Fprintln(os.Stderr, "  Tailscale auth required.")
				fmt.Fprintln(os.Stderr, "  Open this URL in your browser.")
				fmt.Fprintln(os.Stderr, "  (Use your phone if desktop browser is blocked by corporate policy)")
				fmt.Fprintln(os.Stderr, "")
				fmt.Fprintf(os.Stderr, "  %s\n", st.AuthURL)
				fmt.Fprintln(os.Stderr, "")
				fmt.Fprintln(os.Stderr, "  Waiting for auth...")
				openBrowser(st.AuthURL)
			}
		}

		time.Sleep(500 * time.Millisecond)
	}
}

func openBrowser(url string) {
	var cmd *exec.Cmd
	if filepath.Separator == '\\' {
		// Windows
		cmd = exec.Command("cmd", "/c", "start", url)
	} else {
		cmd = exec.Command("xdg-open", url)
	}
	cmd.Start() //nolint:errcheck
}

// ── commands ──────────────────────────────────────────────────────────────────

func cmdUp() {
	srv := newServer()
	defer srv.Close() //nolint:errcheck

	if err := srv.Start(); err != nil {
		fmt.Fprintf(os.Stderr, "Error starting tsnet: %v\n", err)
		os.Exit(1)
	}

	fmt.Fprintln(os.Stderr, "  Connecting to Tailscale...")
	ctx := context.Background()
	if err := waitRunning(ctx, srv); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}

	lc, _ := srv.LocalClient()
	if st, err := lc.Status(ctx); err == nil {
		fmt.Fprintln(os.Stderr, "")
		fmt.Fprintf(os.Stderr, "  Connected!  Node: %s\n", st.Self.HostName)
		fmt.Fprintf(os.Stderr, "  Tailscale IPs: %v\n", st.TailscaleIPs)
		fmt.Fprintf(os.Stderr, "  Peers: %d\n", len(st.Peer))
		fmt.Fprintln(os.Stderr, "")
		fmt.Fprintln(os.Stderr, "  Ctrl+C to disconnect")
		fmt.Fprintln(os.Stderr, "")
	}

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, os.Interrupt)
	<-quit
	fmt.Fprintln(os.Stderr, "  Disconnecting...")
}

// peerInfo is the JSON output shape for `tsnet status`.
type peerInfo struct {
	Name   string   `json:"name"`
	DNS    string   `json:"dns"`
	IPs    []string `json:"ips"`
	OS     string   `json:"os"`
	Online bool     `json:"online"`
	Active bool     `json:"active"`
}

func cmdStatus() {
	srv := newServer()
	defer srv.Close() //nolint:errcheck

	if err := srv.Start(); err != nil {
		fmt.Fprintf(os.Stderr, "Error starting tsnet: %v\n", err)
		os.Exit(1)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	fmt.Fprintln(os.Stderr, "  Connecting (60s timeout)...")
	if err := waitRunning(ctx, srv); err != nil {
		fmt.Fprintf(os.Stderr, "Not connected: %v\n", err)
		fmt.Fprintln(os.Stderr, "  Try running 'tsnet up' first to debug auth/connectivity.")
		os.Exit(1)
	}

	lc, err := srv.LocalClient()
	if err != nil {
		fmt.Fprintf(os.Stderr, "LocalClient error: %v\n", err)
		os.Exit(1)
	}
	st, err := lc.Status(ctx)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Status error: %v\n", err)
		os.Exit(1)
	}

	peers := make([]peerInfo, 0, len(st.Peer))
	for _, p := range st.Peer {
		ips := make([]string, 0, len(p.TailscaleIPs))
		for _, ip := range p.TailscaleIPs {
			ips = append(ips, ip.String())
		}
		peers = append(peers, peerInfo{
			Name:   p.HostName,
			DNS:    p.DNSName,
			IPs:    ips,
			OS:     p.OS,
			Online: p.Online,
			Active: p.Active,
		})
	}

	enc, _ := json.MarshalIndent(peers, "", "  ")
	fmt.Println(string(enc))
}

func cmdProxy(target string) {
	srv := newServer()

	if err := srv.Start(); err != nil {
		fmt.Fprintf(os.Stderr, "tsnet: start error: %v\n", err)
		os.Exit(1)
	}
	defer srv.Close() //nolint:errcheck

	// Use a timeout for the initial connection; once dialed we run until pipe closes.
	connectCtx, connectCancel := context.WithTimeout(context.Background(), 60*time.Second)
	if err := waitRunning(connectCtx, srv); err != nil {
		connectCancel()
		fmt.Fprintf(os.Stderr, "tsnet: not connected within 60s: %v\n", err)
		fmt.Fprintln(os.Stderr, "  Run 'tsnet up' to check auth and connectivity.")
		os.Exit(1)
	}
	connectCancel()

	ctx := context.Background()
	conn, err := srv.Dial(ctx, "tcp", target)
	if err != nil {
		fmt.Fprintf(os.Stderr, "tsnet: dial %s: %v\n", target, err)
		os.Exit(1)
	}
	defer conn.Close()

	done := make(chan struct{}, 2)
	go func() { io.Copy(conn, os.Stdin); done <- struct{}{} }()   //nolint:errcheck
	go func() { io.Copy(os.Stdout, conn); done <- struct{}{} }()  //nolint:errcheck
	<-done
}
