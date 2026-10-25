// Integration probe for an isolated fixture; never removes a production key.
package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/Jigsaw-Code/outline-sdk/transport"
	ss "github.com/Jigsaw-Code/outline-sdk/transport/shadowsocks"
)

type endpoint string

func (e endpoint) ConnectStream(ctx context.Context) (transport.StreamConn, error) {
	c, err := (&net.Dialer{}).DialContext(ctx, "tcp", string(e))
	if err != nil {
		return nil, err
	}
	return c.(*net.TCPConn), nil
}
func (e endpoint) ConnectPacket(ctx context.Context) (net.Conn, error) {
	return (&net.Dialer{}).DialContext(ctx, "udp", string(e))
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}
func require(ok bool, message string) {
	if !ok {
		panic(message)
	}
}

type accessKey struct {
	ID  string `json:"id"`
	URL string `json:"accessUrl"`
}

func stream(raw string) *ss.StreamDialer {
	u, err := url.Parse(raw)
	must(err)
	require(u.Query().Get("outline") == "1" && u.Query().Get("prefix") == "POST ", "complete Outline prefix missing")
	decoded, err := base64.RawURLEncoding.DecodeString(u.User.Username())
	must(err)
	method, password, ok := strings.Cut(string(decoded), ":")
	require(ok, "missing credential")
	key, err := ss.NewEncryptionKey(method, password)
	must(err)
	dialer, err := ss.NewStreamDialer(endpoint(u.Host), key)
	must(err)
	dialer.SaltGenerator = ss.NewPrefixSaltGenerator([]byte(u.Query().Get("prefix")))
	return dialer
}

func packet(raw string) net.PacketConn {
	u, err := url.Parse(raw)
	must(err)
	decoded, err := base64.RawURLEncoding.DecodeString(u.User.Username())
	must(err)
	method, password, _ := strings.Cut(string(decoded), ":")
	key, err := ss.NewEncryptionKey(method, password)
	must(err)
	listener, err := ss.NewPacketListener(endpoint(u.Host), key)
	must(err)
	c, err := listener.ListenPacket(context.Background())
	must(err)
	return c
}

func echo(c net.Conn) error {
	c.SetDeadline(time.Now().Add(2 * time.Second))
	if _, err := c.Write([]byte("ping")); err != nil {
		return err
	}
	b := make([]byte, 4)
	if _, err := io.ReadFull(c, b); err != nil {
		return err
	}
	if string(b) != "ping" {
		return fmt.Errorf("bad echo")
	}
	return nil
}

func udpEcho(c net.PacketConn, target net.Addr) error {
	c.SetDeadline(time.Now().Add(time.Second))
	if _, err := c.WriteTo([]byte("ping"), target); err != nil {
		return err
	}
	b := make([]byte, 32)
	n, _, err := c.ReadFrom(b)
	if err != nil {
		return err
	}
	if string(b[:n]) != "ping" {
		return fmt.Errorf("bad UDP echo")
	}
	return nil
}

// Check existing live keys without creating, changing or revoking any key.
func checkLive(state, bindHost, serverHost string) {
	var config struct {
		Keys []struct {
			Method   string `json:"encryptionMethod"`
			Password string `json:"password"`
			Port     int    `json:"port"`
		} `json:"accessKeys"`
	}
	data, err := os.ReadFile(filepath.Join(state, "shadowbox_config.json"))
	must(err)
	must(json.Unmarshal(data, &config))
	require(len(config.Keys) > 0, "no existing keys")
	tcp, err := net.Listen("tcp", net.JoinHostPort(bindHost, "0"))
	must(err)
	defer tcp.Close()
	go func() {
		for {
			c, err := tcp.Accept()
			if err != nil {
				return
			}
			go func() { defer c.Close(); io.Copy(c, c) }()
		}
	}()
	udp, err := net.ListenPacket("udp", net.JoinHostPort(bindHost, "0"))
	must(err)
	defer udp.Close()
	go func() {
		b := make([]byte, 8192)
		for {
			n, addr, err := udp.ReadFrom(b)
			if err != nil {
				return
			}
			udp.WriteTo(b[:n], addr)
		}
	}()
	for _, key := range config.Keys {
		credentials := base64.RawURLEncoding.EncodeToString([]byte(key.Method + ":" + key.Password))
		raw := fmt.Sprintf("ss://%s@%s/?outline=1&prefix=POST%%20", credentials, net.JoinHostPort(serverHost, fmt.Sprint(key.Port)))
		c, err := stream(raw).DialStream(context.Background(), tcp.Addr().String())
		must(err)
		must(echo(c))
		c.Close()
		p := packet(raw)
		must(udpEcho(p, udp.LocalAddr()))
		p.Close()
	}
	json.NewEncoder(os.Stdout).Encode(map[string]any{"keys_tested": len(config.Keys),
		"private_tcp": true, "private_udp": true, "full_post_prefix": true, "keys_modified": false})
}

func main() {
	time.AfterFunc(45*time.Second, func() { fmt.Fprintln(os.Stderr, "integration probe timed out"); os.Exit(2) })
	if len(os.Args) == 3 && os.Args[1] == "--check-live" {
		checkLive(os.Args[2], "10.0.0.33", "127.0.0.1")
		return
	}
	if len(os.Args) == 5 && os.Args[1] == "--check-live-external" {
		checkLive(os.Args[2], os.Args[3], os.Args[4])
		return
	}
	require(len(os.Args) == 4, "usage: probe BASE_URL CERTIFICATE ECHO_TARGET")
	base, certificate, target := os.Args[1], os.Args[2], os.Args[3]
	cert, err := os.ReadFile(certificate)
	must(err)
	pool := x509.NewCertPool()
	require(pool.AppendCertsFromPEM(cert), "bad fixture certificate")
	tlsConfig := &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12}
	client := &http.Client{Transport: &http.Transport{TLSClientConfig: tlsConfig}, Timeout: 5 * time.Second}
	request := func(method, path string, body any, want int) []byte {
		var reader io.Reader
		if body != nil {
			data, e := json.Marshal(body)
			must(e)
			reader = bytes.NewReader(data)
		}
		r, e := http.NewRequest(method, base+path, reader)
		must(e)
		if body != nil {
			r.Header.Set("Content-Type", "application/json")
		}
		response, e := client.Do(r)
		must(e)
		defer response.Body.Close()
		data, e := io.ReadAll(io.LimitReader(response.Body, 2*1024*1024))
		must(e)
		require(response.StatusCode == want, fmt.Sprintf("%s %s: got %d, want %d", method, path, response.StatusCode, want))
		return data
	}
	var identity struct {
		ID string `json:"serverId"`
	}
	must(json.Unmarshal(request("GET", "/server", nil, 200), &identity))
	require(identity.ID == "00000000-0000-4000-8000-000000000000", "refusing to modify a non-fixture server")
	var keys struct {
		Keys []accessKey `json:"accessKeys"`
	}
	must(json.Unmarshal(request("GET", "/access-keys", nil, 200), &keys))
	require(len(keys.Keys) == 1, "original key was not retained")
	original := keys.Keys[0]
	loopbackClient := &http.Client{Timeout: 5 * time.Second, Transport: &http.Transport{
		DialContext: func(ctx context.Context, _, address string) (net.Conn, error) {
			return stream(original.URL).DialStream(ctx, address)
		},
	}}
	loopbackResponse, err := loopbackClient.Get("http://127.0.0.1:9090/-/ready")
	if loopbackResponse != nil {
		loopbackResponse.Body.Close()
	}
	require(err != nil, "VPN key bypassed loopback target restrictions")
	stable, err := stream(original.URL).DialStream(context.Background(), target)
	must(err)
	defer stable.Close()
	must(echo(stable))
	var created accessKey
	must(json.Unmarshal(request("POST", "/access-keys", map[string]string{"name": "revocation-fixture"}, 201), &created))
	live, err := stream(created.URL).DialStream(context.Background(), target)
	must(err)
	defer live.Close()
	must(echo(live))
	udp := packet(created.URL)
	defer udp.Close()
	address, err := net.ResolveUDPAddr("udp", target)
	must(err)
	must(udpEcho(udp, address))
	u, err := url.Parse(base)
	must(err)
	management, err := stream(original.URL).DialStream(context.Background(), u.Host)
	must(err)
	tunnelConfig := tlsConfig.Clone()
	tunnelConfig.ServerName = "audit.invalid"
	tunnelTLS := tls.Client(management, tunnelConfig)
	must(tunnelTLS.Handshake())
	_, err = fmt.Fprintf(tunnelTLS, "GET %s/server HTTP/1.1\r\nHost: audit.invalid\r\nConnection: close\r\n\r\n", u.Path)
	must(err)
	response := make([]byte, 64)
	n, err := tunnelTLS.Read(response)
	must(err)
	require(strings.Contains(string(response[:n]), "200"), "VPN management failed")
	tunnelTLS.Close()
	request("DELETE", "/access-keys/"+created.ID, nil, 204)
	require(echo(live) != nil, "revoked established TCP stream survived HTTP success")
	fresh, err := stream(created.URL).DialStream(context.Background(), target)
	if err == nil {
		defer fresh.Close()
		require(echo(fresh) != nil, "revoked key created a new TCP stream")
	}
	require(udpEcho(udp, address) != nil, "revoked UDP association survived")
	must(echo(stable))
	request("GET", "/metrics/transfer", nil, 200)
	request("GET", "/experimental/server/metrics", nil, 400)
	request("GET", "/experimental/server/metrics?since=1h", nil, 200)
	request("PUT", "/name", map[string]string{"name": strings.Repeat("x", 70000)}, 413)
	request("PUT", "/server/hostname-for-access-keys", map[string]string{"hostname": "2001:db8::7"}, 204)
	var ipv6Key accessKey
	must(json.Unmarshal(request("POST", "/access-keys", map[string]string{"name": "IPv6-format-fixture"}, 201), &ipv6Key))
	require(strings.Contains(ipv6Key.URL, "@[2001:db8::7]:80/"), "IPv6 key URL is invalid")
	request("PUT", "/server/hostname-for-access-keys", map[string]string{"hostname": u.Hostname()}, 204)
	request("DELETE", "/access-keys/"+ipv6Key.ID, nil, 204)
	json.NewEncoder(os.Stdout).Encode(map[string]bool{
		"initial_key_preserved": true, "post_prefix_used": true, "private_tcp": true, "private_udp": true,
		"manager_over_outline": true, "delete_waits_for_backend": true, "revoked_tcp_closed": true,
		"revoked_new_tcp_denied": true, "revoked_udp_denied": true, "unrelated_stream_preserved": true,
		"metrics_apis": true, "oversized_body_rejected": true, "ipv6_key_format": true,
		"loopback_targets_blocked": true,
	})
}
