// Standalone libp2p circuit relay v2 server for ShareThing hole punching.
// Run on a publicly reachable host; clients pass its multiaddr as a relay address.
package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"os"
	"os/signal"
	"sort"
	"strings"
	"syscall"

	libp2p "github.com/libp2p/go-libp2p"
	"github.com/libp2p/go-libp2p/core/crypto"
	"github.com/libp2p/go-libp2p/core/host"
	relayv2 "github.com/libp2p/go-libp2p/p2p/protocol/circuitv2/relay"
	"github.com/multiformats/go-multiaddr"
)

func main() {
	port := flag.Int("port", 4100, "TCP port to listen on")
	keyFile := flag.String("key", "relay.key", "Path to persist the relay's Ed25519 private key (base64)")
	flag.Parse()

	privKey, err := loadOrCreateKey(*keyFile)
	if err != nil {
		fmt.Fprintf(os.Stderr, "key: %v\n", err)
		os.Exit(1)
	}

	h, err := libp2p.New(
		libp2p.Identity(privKey),
		libp2p.ListenAddrStrings(
			fmt.Sprintf("/ip4/0.0.0.0/tcp/%d", *port),
			fmt.Sprintf("/ip4/0.0.0.0/udp/%d/quic-v1", *port),
		),
		libp2p.EnableRelayService(relayv2.WithInfiniteLimits()),
		libp2p.ForceReachabilityPublic(),
		libp2p.EnableNATService(),
	)
	if err != nil {
		fmt.Fprintf(os.Stderr, "host: %v\n", err)
		os.Exit(1)
	}
	defer h.Close()

	fmt.Printf("Relay peer ID: %s\n", h.ID())
	for _, addr := range advertisedRelayAddresses(h) {
		fmt.Printf("Relay address: %s\n", addr)
	}
	fmt.Println("Relay running. Ctrl-C to stop.")

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM)
	select {
	case <-sigs:
	case <-ctx.Done():
	}
}

func advertisedRelayAddresses(h host.Host) []string {
	peerID := h.ID().String()
	seen := map[string]struct{}{}
	var addrs []string

	appendAddr := func(addr string) {
		if addr == "" {
			return
		}
		if _, ok := seen[addr]; ok {
			return
		}
		seen[addr] = struct{}{}
		addrs = append(addrs, addr)
	}

	for _, addr := range h.Addrs() {
		if ip, err := addr.ValueForProtocol(multiaddr.P_IP4); err == nil {
			parsed := net.ParseIP(ip)
			if parsed == nil || parsed.IsLoopback() || parsed.IsUnspecified() {
				continue
			}
		}
		appendAddr(fmt.Sprintf("%s/p2p/%s", addr, peerID))
	}

	publicIP := preferredLocalIPv4()
	if publicIP != "" {
		if tcpPort := currentPort(h, "tcp"); tcpPort > 0 {
			appendAddr(fmt.Sprintf("/ip4/%s/tcp/%d/p2p/%s", publicIP, tcpPort, peerID))
		}
		if quicPort := currentPort(h, "quic-v1"); quicPort > 0 {
			appendAddr(fmt.Sprintf("/ip4/%s/udp/%d/quic-v1/p2p/%s", publicIP, quicPort, peerID))
		}
	}

	sort.Strings(addrs)
	return addrs
}

func currentPort(h host.Host, protocol string) int {
	for _, addr := range h.Addrs() {
		if protocol == "tcp" {
			value, err := addr.ValueForProtocol(multiaddr.P_TCP)
			if err == nil {
				var port int
				if _, scanErr := fmt.Sscanf(value, "%d", &port); scanErr == nil {
					return port
				}
			}
		}
		if protocol == "quic-v1" {
			if _, err := addr.ValueForProtocol(multiaddr.P_QUIC_V1); err == nil {
				value, udpErr := addr.ValueForProtocol(multiaddr.P_UDP)
				if udpErr == nil {
					var port int
					if _, scanErr := fmt.Sscanf(value, "%d", &port); scanErr == nil {
						return port
					}
				}
			}
		}
	}
	return 0
}

func preferredLocalIPv4() string {
	if conn, err := net.Dial("udp4", "8.8.8.8:80"); err == nil {
		defer conn.Close()
		if addr, ok := conn.LocalAddr().(*net.UDPAddr); ok && !addr.IP.IsLoopback() {
			if ip := addr.IP.To4(); ip != nil {
				return ip.String()
			}
		}
	}

	ifaces, err := net.Interfaces()
	if err != nil {
		return ""
	}

	virtualKeywords := []string{"virtualbox", "vmware", "hyper-v", "vethernet", "vbox", "virtual"}
	matchVirtual := func(name string) bool {
		lower := strings.ToLower(name)
		for _, keyword := range virtualKeywords {
			if strings.Contains(lower, keyword) {
				return true
			}
		}
		return false
	}

	var fallback string
	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, addrErr := iface.Addrs()
		if addrErr != nil {
			continue
		}
		for _, addr := range addrs {
			var ip net.IP
			switch value := addr.(type) {
			case *net.IPNet:
				ip = value.IP
			case *net.IPAddr:
				ip = value.IP
			}
			if ip == nil {
				continue
			}
			ip = ip.To4()
			if ip == nil || ip.IsLoopback() {
				continue
			}
			if !matchVirtual(iface.Name) && !matchVirtual(iface.HardwareAddr.String()) {
				return ip.String()
			}
			if fallback == "" {
				fallback = ip.String()
			}
		}
	}
	return fallback
}

type storedKey struct {
	PrivateKey string `json:"privateKey"`
}

func loadOrCreateKey(path string) (crypto.PrivKey, error) {
	if data, err := os.ReadFile(path); err == nil {
		var s storedKey
		if json.Unmarshal(data, &s) == nil {
			decoded, err := base64.StdEncoding.DecodeString(s.PrivateKey)
			if err == nil {
				key, err := crypto.UnmarshalPrivateKey(decoded)
				if err == nil {
					return key, nil
				}
			}
		}
	}

	key, _, err := crypto.GenerateEd25519Key(nil)
	if err != nil {
		return nil, err
	}

	raw, err := crypto.MarshalPrivateKey(key)
	if err != nil {
		return nil, err
	}
	s := storedKey{PrivateKey: base64.StdEncoding.EncodeToString(raw)}
	data, _ := json.MarshalIndent(s, "", "  ")
	_ = os.WriteFile(path, data, 0600)
	return key, nil
}
