package p2p

import (
	"context"
	"fmt"
	"testing"
	"time"

	libp2p "github.com/libp2p/go-libp2p"
	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/core/network"
	"github.com/libp2p/go-libp2p/core/peer"
	circuitclient "github.com/libp2p/go-libp2p/p2p/protocol/circuitv2/client"
	relayv2 "github.com/libp2p/go-libp2p/p2p/protocol/circuitv2/relay"
	"github.com/multiformats/go-multiaddr"
)

func newRelayHost(t *testing.T) (host.Host, peer.AddrInfo) {
	t.Helper()
	h, err := libp2p.New(
		libp2p.ListenAddrStrings("/ip4/127.0.0.1/tcp/0"),
		libp2p.EnableRelayService(relayv2.WithInfiniteLimits()),
		libp2p.ForceReachabilityPublic(),
	)
	if err != nil {
		t.Fatalf("relay host: %v", err)
	}
	t.Cleanup(func() { h.Close() })
	return h, peer.AddrInfo{ID: h.ID(), Addrs: h.Addrs()}
}

func newClientHost(t *testing.T, relayInfo *peer.AddrInfo) (host.Host, peer.AddrInfo) {
	t.Helper()
	opts := []libp2p.Option{
		libp2p.ListenAddrStrings("/ip4/127.0.0.1/tcp/0"),
		libp2p.EnableHolePunching(),
		libp2p.EnableAutoNATv2(),
	}
	if relayInfo != nil {
		opts = append(opts,
			libp2p.EnableAutoRelayWithStaticRelays([]peer.AddrInfo{*relayInfo}),
			libp2p.ForceReachabilityPrivate(),
		)
	}
	h, err := libp2p.New(opts...)
	if err != nil {
		t.Fatalf("client host: %v", err)
	}
	t.Cleanup(func() { h.Close() })
	return h, peer.AddrInfo{ID: h.ID(), Addrs: h.Addrs()}
}

func connectToRelay(ctx context.Context, t *testing.T, h host.Host, relayInfo peer.AddrInfo) multiaddr.Multiaddr {
	t.Helper()

	if _, err := circuitclient.Reserve(ctx, h, relayInfo); err != nil {
		t.Fatalf("relay reserve: %v", err)
	}

	fullAddr, err := multiaddr.NewMultiaddr(
		fmt.Sprintf("/p2p/%s/p2p-circuit/p2p/%s", relayInfo.ID, h.ID()),
	)
	if err != nil {
		t.Fatalf("build full relay addr: %v", err)
	}
	return fullAddr
}


func TestRelayHostStart(t *testing.T) {
	_, info := newRelayHost(t)
	if info.ID == "" {
		t.Fatal("relay has no peer ID")
	}
	if len(info.Addrs) == 0 {
		t.Fatal("relay has no listen addresses")
	}
	t.Logf("relay %s @ %v", info.ID, info.Addrs)
}


func TestClientHostWithRelay(t *testing.T) {
	_, relayInfo := newRelayHost(t)
	_, clientInfo := newClientHost(t, &relayInfo)
	if clientInfo.ID == "" {
		t.Fatal("client has no peer ID")
	}
	t.Logf("client %s", clientInfo.ID)
}


func TestRelayConnectivity(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	_, relayInfo := newRelayHost(t)
	hA, _ := newClientHost(t, nil)
	hB, infoB := newClientHost(t, nil)

	const testProto = "/sharething-test/1.0.0"
	streamOpened := make(chan string, 1)
	hB.SetStreamHandler(testProto, func(s network.Stream) {
		defer s.Reset()
		buf := make([]byte, 1)
		s.Read(buf)
		select {
		case streamOpened <- string(buf):
		default:
		}
	})

	// B reserves a slot on the relay and gets its relay-circuit address.
	bRelayAddr := connectToRelay(ctx, t, hB, relayInfo)
	t.Logf("B relay addr: %s", bRelayAddr)

	// A must know the relay's addresses before it can use it to reach B.
	// In production, peers learn relay addresses via discovery server or
	// Identify. In the test we seed A's peerstore directly.
	hA.Peerstore().AddAddrs(relayInfo.ID, relayInfo.Addrs, time.Hour)

	// A dials B via the relay.
	targetAddrInfo := peer.AddrInfo{
		ID:    infoB.ID,
		Addrs: []multiaddr.Multiaddr{bRelayAddr},
	}

	// Give the relay a moment to finish the reservation handshake.
	time.Sleep(200 * time.Millisecond)

	if err := hA.Connect(ctx, targetAddrInfo); err != nil {
		t.Fatalf("connect via relay: %v", err)
	}
	t.Log("A connected to B via relay")

	s, err := hA.NewStream(ctx, infoB.ID, testProto)
	if err != nil {
		t.Fatalf("open stream via relay: %v", err)
	}
	defer s.Reset()

	if _, err := s.Write([]byte(".")); err != nil {
		t.Fatalf("write to relay stream: %v", err)
	}

	select {
	case <-streamOpened:
		t.Log("data traversed relay to peer B — relay connectivity OK")
	case <-ctx.Done():
		t.Fatal("timed out waiting for data at peer B")
	}
}

func TestRelayAndHolePunchSetup(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	_, relayInfo := newRelayHost(t)
	hA, _ := newClientHost(t, nil)
	hB, infoB := newClientHost(t, nil)

	bRelayAddr := connectToRelay(ctx, t, hB, relayInfo)
	time.Sleep(200 * time.Millisecond)

	hA.Peerstore().AddAddrs(relayInfo.ID, relayInfo.Addrs, time.Hour)

	targetAddr := peer.AddrInfo{
		ID:    infoB.ID,
		Addrs: []multiaddr.Multiaddr{bRelayAddr},
	}

	if err := hA.Connect(ctx, targetAddr); err != nil {
		t.Fatalf("connect via relay: %v", err)
	}

	time.Sleep(500 * time.Millisecond)

	connected := false
	for _, p := range hA.Network().Peers() {
		if p == infoB.ID {
			connected = true
			break
		}
	}
	if !connected {
		t.Fatal("A is not connected to B after relay connect")
	}

	for _, conn := range hA.Network().ConnsToPeer(infoB.ID) {
		t.Logf("connection to B: local=%s remote=%s via=%s",
			conn.LocalMultiaddr(), conn.RemoteMultiaddr(),
			func() string {
				if conn.Stat().Limited {
					return "relay"
				}
				return "direct"
			}(),
		)
	}
}

func TestParseRelayAddrs(t *testing.T) {
	const raw = "/ip4/1.2.3.4/tcp/4100/p2p/12D3KooWGCmWvMETHsefkMeHqyzEANYdbL4ouWGFxXcsPeSePv7B;" +
		"/ip4/5.6.7.8/tcp/4100/p2p/12D3KooWGCmWvMETHsefkMeHqyzEANYdbL4ouWGFxXcsPeSePv7C"
	infos := parseRelayAddrs(raw)
	if len(infos) != 2 {
		t.Fatalf("expected 2 relay infos, got %d", len(infos))
	}
}


func TestParseRelayAddrsEmpty(t *testing.T) {
	for _, raw := range []string{"", "   ", ";;;"} {
		if got := parseRelayAddrs(raw); len(got) != 0 {
			t.Fatalf("expected 0 for %q, got %d", raw, len(got))
		}
	}
}
