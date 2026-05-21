// Standalone libp2p circuit relay v2 server for ShareThing hole punching.
// Run on a publicly reachable host; clients pass its multiaddr as a relay address.
package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	libp2p "github.com/libp2p/go-libp2p"
	"github.com/libp2p/go-libp2p/core/crypto"
	relayv2 "github.com/libp2p/go-libp2p/p2p/protocol/circuitv2/relay"
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
	for _, addr := range h.Addrs() {
		fmt.Printf("Relay address: %s/p2p/%s\n", addr, h.ID())
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
