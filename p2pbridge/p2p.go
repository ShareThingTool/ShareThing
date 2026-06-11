package p2p

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"

	libp2p "github.com/libp2p/go-libp2p"
	"github.com/libp2p/go-libp2p/core/crypto"
	"github.com/libp2p/go-libp2p/core/event"
	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/core/network"
	"github.com/libp2p/go-libp2p/core/peer"
	"github.com/libp2p/go-libp2p/p2p/discovery/mdns"
	dht "github.com/libp2p/go-libp2p-kad-dht"
	drouting "github.com/libp2p/go-libp2p/p2p/discovery/routing"
	dutil "github.com/libp2p/go-libp2p/p2p/discovery/util"
	"github.com/multiformats/go-multiaddr"
	"lukechampine.com/blake3"
)

const (
	fileProtocol      = "/sharething/files/1.0.0"
	helloProtocol     = "/sharething/hello/1.0.0"
	dhtRendezvous     = "/sharething/peers/1.0.0"
	mdnsServiceTag    = "_sharething._tcp.local."
	defaultPort       = 4101
	maxControlBytes   = 1 * 1024 * 1024
	peerStaleMillis   = 25_000
	sweepIntervalSecs = 10
)

type EventListener interface {
	OnEvent(eventJson string)
}

type StartConfig struct {
	Nickname            string
	DiscoveryServersRaw string
	RelayAddrsRaw       string
	DeviceIP            string
	Platform            string
}

var (
	nodeMu  sync.Mutex
	node    host.Host
	nodeKey crypto.PrivKey
	nodeDHT *dht.IpfsDHT

	dataDir      string
	nodePeerID   string
	nodeNickname string
	nodePlatform string
	cancelFn     context.CancelFunc

	eventListenerMu sync.RWMutex
	eventListener EventListener

	peersMu    sync.RWMutex
	knownPeers = map[string]*knownPeer{}

	pendingMu        sync.Mutex
	pendingTransfers = map[string]*pendingTransfer{}
)

type knownPeer struct {
	PeerID    string
	Nickname  string
	Addresses []string
	LastSeen  time.Time
}

type pendingTransfer struct {
	TransferID  string
	PeerID      string
	Filename    string
	TotalBytes  int64
	TextContent string
	once        sync.Once
	decision    chan transferDecision
}

type transferDecision struct {
	accepted bool
	savePath string
}

func (pt *pendingTransfer) resolve(d transferDecision) {
	pt.once.Do(func() { pt.decision <- d })
}

type controlMsg struct {
	Type          string `json:"type"`
	TransferID    string `json:"transferId,omitempty"`
	PeerID        string `json:"peerId,omitempty"`
	Nickname      string `json:"nickname,omitempty"`
	Filename      string `json:"filename,omitempty"`
	TotalBytes    int64  `json:"totalBytes,omitempty"`
	Accepted      *bool  `json:"accepted,omitempty"`
	Completed     *bool  `json:"completed,omitempty"`
	Message       string `json:"message,omitempty"`
	BytesReceived int64  `json:"bytesReceived,omitempty"`
	Blake3Hash    string `json:"blake3Hash,omitempty"`
	TextContent   string `json:"textContent,omitempty"`
}

type discoveryRegisterRequest struct {
	PeerID    string   `json:"peerId"`
	Nick      string   `json:"nick"`
	Addresses []string `json:"addresses"`
	Platform  string   `json:"platform"`
}

type discoveryPeer struct {
	PeerID    string   `json:"peerId"`
	Nick      string   `json:"nick"`
	Addresses []string `json:"addresses"`
}

type discoveryPeersResponse struct {
	Peers []discoveryPeer `json:"peers"`
}

func SetEventListener(l EventListener) {
	eventListenerMu.Lock()
	defer eventListenerMu.Unlock()
	eventListener = l
}

func SetDataDir(path string) {
	dataDir = path
}

func SetPlatform(platform string) {
	nodePlatform = strings.TrimSpace(platform)
}

// Start launches the libp2p node.
//
// relayAddrs is a semicolon-separated list of relay multiaddresses
// (e.g. "/ip4/1.2.3.4/tcp/4100/p2p/12D3…"). When provided, the node
// enables AutoRelay (connecting to those relays) and hole punching via
// DCUtR so it can reach peers behind NAT.
func Start(nick, discoveryServers, relayAddrs, deviceIP string) error {
	return StartWithConfig(StartConfig{
		Nickname:            nick,
		DiscoveryServersRaw: discoveryServers,
		RelayAddrsRaw:       relayAddrs,
		DeviceIP:            deviceIP,
		Platform:            "android",
	})
}

func StartWithConfig(cfg StartConfig) error {
	nodeMu.Lock()
	defer nodeMu.Unlock()

	if cfg.DeviceIP == "" {
		cfg.DeviceIP = preferredLocalIPv4()
	}

	if node != nil {
		emitNodeStarted(node, cfg.DeviceIP)
		return nil
	}

	nodeNickname = cfg.Nickname
	nodePlatform = strings.TrimSpace(cfg.Platform)
	if nodePlatform == "" {
		nodePlatform = defaultPlatformLabel()
	}
	if strings.TrimSpace(dataDir) == "" {
		dataDir = defaultDataDir(nodePlatform)
	}
	privKey, err := loadOrCreateKey()
	if err != nil {
		return fmt.Errorf("identity: %w", err)
	}

	relayInfos := parseRelayAddrs(cfg.RelayAddrsRaw)

	opts := []libp2p.Option{
		libp2p.Identity(privKey),
		libp2p.ListenAddrStrings(
			fmt.Sprintf("/ip4/0.0.0.0/tcp/%d", defaultPort),
			fmt.Sprintf("/ip4/0.0.0.0/udp/%d/quic-v1", defaultPort),
		),
		libp2p.EnableNATService(),
		libp2p.EnableAutoNATv2(),
		libp2p.EnableHolePunching(),
		libp2p.NATPortMap(),
	}

	if cfg.DeviceIP != "" {
		tcpMA, err1 := multiaddr.NewMultiaddr(fmt.Sprintf("/ip4/%s/tcp/%d", cfg.DeviceIP, defaultPort))
		quicMA, err2 := multiaddr.NewMultiaddr(fmt.Sprintf("/ip4/%s/udp/%d/quic-v1", cfg.DeviceIP, defaultPort))
		var announced []multiaddr.Multiaddr
		if err1 == nil {
			announced = append(announced, tcpMA)
		}
		if err2 == nil {
			announced = append(announced, quicMA)
		}
		if len(announced) > 0 {
			opts = append(opts, libp2p.AddrsFactory(func(_ []multiaddr.Multiaddr) []multiaddr.Multiaddr {
				return announced
			}))
		}
	}

	if len(relayInfos) > 0 {
		opts = append(opts, libp2p.EnableAutoRelayWithStaticRelays(relayInfos))
	} else {
		opts = append(opts, libp2p.EnableAutoRelayWithPeerSource(bootstrapRelaySource))
	}

	h, err := libp2p.New(opts...)
	if err != nil {
		// Fall back without explicit listen addresses (OS picks port)
		h, err = libp2p.New(
			libp2p.Identity(privKey),
			libp2p.EnableNATService(),
			libp2p.EnableAutoNATv2(),
			libp2p.EnableHolePunching(),
		)
		if err != nil {
			return fmt.Errorf("host: %w", err)
		}
	}

	node = h
	nodeKey = privKey
	nodePeerID = h.ID().String()

	h.SetStreamHandler(fileProtocol, handleIncomingStream)
	h.SetStreamHandler(helloProtocol, handleHelloStream)

	ctx, cancel := context.WithCancel(context.Background())
	cancelFn = cancel

	addrUpdated := make(chan struct{}, 1)

	if d, dhtErr := dht.New(ctx, h, dht.Mode(dht.ModeAuto)); dhtErr == nil {
		nodeDHT = d
		_ = d.Bootstrap(ctx)
		go connectBootstrapPeers(ctx, h)
		go runDHTDiscovery(ctx, h, d, addrUpdated)
	}

	go watchAddressChanges(ctx, h, cfg.DeviceIP, addrUpdated)
	go startMDNS(ctx, h)
	go runPeerSweep(ctx)
	go runLANBroadcast(ctx, h)

	servers := splitServers(cfg.DiscoveryServersRaw)
	if len(servers) > 0 {
		go runDiscoveryLoop(ctx, h, servers)
	}
	emitNodeStarted(h, cfg.DeviceIP)
	return nil
}

func Stop() {
	nodeMu.Lock()
	defer nodeMu.Unlock()

	if cancelFn != nil {
		cancelFn()
		cancelFn = nil
	}
	if nodeDHT != nil {
		nodeDHT.Close()
		nodeDHT = nil
	}
	if node != nil {
		node.Close()
		node = nil
	}

	peersMu.Lock()
	knownPeers = map[string]*knownPeer{}
	peersMu.Unlock()

	pendingMu.Lock()
	pendingTransfers = map[string]*pendingTransfer{}
	pendingMu.Unlock()

	emitJSON(map[string]interface{}{"type": "NODE_STOPPED"})
}

func SendFile(peerID, filePath, addrsStr string) error {
	h := node
	if h == nil {
		return fmt.Errorf("node not running")
	}

	kp, err := resolvePeer(h, peerID, addrsStr)
	if err != nil {
		return err
	}

	info, err := os.Stat(filePath)
	if err != nil || info.IsDir() {
		return fmt.Errorf("file not accessible: %s", filePath)
	}

	transferID := newUUID()
	totalBytes := info.Size()
	filename := filepath.Base(filePath)

	emitTransferUpdate(transferID, "OUTGOING", 0, totalBytes, 0, "QUEUED", peerID, filename, "", "")

	go func() {
		if err := doSendFile(h, kp, transferID, filePath, filename, totalBytes); err != nil {
			emitTransferUpdate(transferID, "OUTGOING", 0, totalBytes, 0, "FAILED", peerID, filename, err.Error(), "")
		}
	}()
	return nil
}

func AcceptFile(transferID, savePath string) error {
	pendingMu.Lock()
	pt := pendingTransfers[transferID]
	pendingMu.Unlock()
	if pt == nil {
		return fmt.Errorf("unknown transfer: %s", transferID)
	}
	pt.resolve(transferDecision{accepted: true, savePath: savePath})
	emitTransferUpdate(transferID, "INCOMING", 0, pt.TotalBytes, 0, "IN_PROGRESS", pt.PeerID, pt.Filename, "", "")
	return nil
}

func RejectFile(transferID string) error {
	pendingMu.Lock()
	pt := pendingTransfers[transferID]
	delete(pendingTransfers, transferID)
	pendingMu.Unlock()
	if pt == nil {
		return fmt.Errorf("unknown transfer: %s", transferID)
	}
	pt.resolve(transferDecision{accepted: false})
	return nil
}

func GetId() string { return nodePeerID }

func GetMultiaddr() string {
	h := node
	if h == nil || len(h.Addrs()) == 0 {
		return ""
	}
	return fmt.Sprintf("%s/p2p/%s", h.Addrs()[0], h.ID())
}

func ExportPrivateKey() string {
	if nodeKey == nil {
		return ""
	}
	b, err := crypto.MarshalPrivateKey(nodeKey)
	if err != nil {
		return ""
	}
	return base64.StdEncoding.EncodeToString(b)
}

func resolvePeer(h host.Host, peerID, addrsStr string) (*knownPeer, error) {
	peersMu.RLock()
	kp := knownPeers[peerID]
	peersMu.RUnlock()
	if kp != nil {
		return kp, nil
	}

	pid, err := peer.Decode(peerID)
	if err != nil {
		return nil, fmt.Errorf("invalid peer id: %s", peerID)
	}

	addrs := h.Peerstore().Addrs(pid)
	if len(addrs) == 0 && addrsStr != "" {
		for _, s := range strings.Split(addrsStr, ";") {
			s = strings.TrimSpace(s)
			if s == "" {
				continue
			}
			if ma, maErr := multiaddr.NewMultiaddr(s); maErr == nil {
				addrs = append(addrs, ma)
			}
		}
	}

	if len(addrs) == 0 {
		if d := nodeDHT; d != nil {
			findCtx, findCancel := context.WithTimeout(context.Background(), 30*time.Second)
			info, dhtErr := d.FindPeer(findCtx, pid)
			findCancel()
			if dhtErr == nil {
				addrs = info.Addrs
			}
		}
	}

	if len(addrs) == 0 {
		return nil, fmt.Errorf("peer not found: %s", peerID)
	}

	connectCtx, connectCancel := context.WithTimeout(context.Background(), 10*time.Second)
	connectErr := h.Connect(connectCtx, peer.AddrInfo{ID: pid, Addrs: addrs})
	connectCancel()
	if connectErr != nil {
		return nil, fmt.Errorf("could not connect to peer: %w", connectErr)
	}

	var addrStrs []string
	for _, a := range addrs {
		addrStrs = append(addrStrs, fmt.Sprintf("%s/p2p/%s", a, peerID))
	}
	upsertPeer(peerID, peerID, addrStrs)
	go sayHello(h, peerID)

	peersMu.RLock()
	kp = knownPeers[peerID]
	peersMu.RUnlock()
	return kp, nil
}

func runDHTDiscovery(ctx context.Context, h host.Host, d *dht.IpfsDHT, addrUpdated <-chan struct{}) {
	// Give bootstrap connections time to establish before advertising.
	select {
	case <-time.After(5 * time.Second):
	case <-ctx.Done():
		return
	}

	rd := drouting.NewRoutingDiscovery(d)
	fmt.Fprintf(os.Stderr, "[dht] advertising at rendezvous, network peers: %d\n", len(h.Network().Peers()))
	dutil.Advertise(ctx, rd, dhtRendezvous)

	scan := func() {
		fmt.Fprintf(os.Stderr, "[dht] scanning rendezvous, network peers: %d\n", len(h.Network().Peers()))
		peerChan, err := rd.FindPeers(ctx, dhtRendezvous)
		if err != nil {
			fmt.Fprintf(os.Stderr, "[dht] FindPeers error: %v\n", err)
			return
		}
		found := 0
		for p := range peerChan {
			if p.ID.String() == nodePeerID || len(p.Addrs) == 0 {
				continue
			}
			found++
			fmt.Fprintf(os.Stderr, "[dht] found peer %s addrs=%v\n", p.ID, p.Addrs)
			dialCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
			if err := h.Connect(dialCtx, p); err == nil {
				fmt.Fprintf(os.Stderr, "[dht] connected to %s\n", p.ID)
				go sayHello(h, p.ID.String())
			} else {
				fmt.Fprintf(os.Stderr, "[dht] connect FAIL %s: %v\n", p.ID, err)
			}
			cancel()
		}
		fmt.Fprintf(os.Stderr, "[dht] scan done, found %d peers at rendezvous\n", found)
	}

	scan()
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-addrUpdated:
			fmt.Fprintf(os.Stderr, "[dht] addresses updated, re-advertising\n")
			dutil.Advertise(ctx, rd, dhtRendezvous)
		case <-ticker.C:
			dutil.Advertise(ctx, rd, dhtRendezvous)
			scan()
		}
	}
}

func connectBootstrapPeers(ctx context.Context, h host.Host) {
	var wg sync.WaitGroup
	for _, maddr := range dht.DefaultBootstrapPeers {
		info, err := peer.AddrInfoFromP2pAddr(maddr)
		if err != nil {
			continue
		}
		wg.Add(1)
		go func(pi peer.AddrInfo) {
			defer wg.Done()
			dialCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
			defer cancel()
			if err := h.Connect(dialCtx, pi); err != nil {
				fmt.Fprintf(os.Stderr, "[dht] bootstrap connect FAIL %s: %v\n", pi.ID, err)
			} else {
				fmt.Fprintf(os.Stderr, "[dht] bootstrap connect OK  %s\n", pi.ID)
			}
		}(*info)
	}
	wg.Wait()
	fmt.Fprintf(os.Stderr, "[dht] bootstrap done, peers connected: %d\n", len(h.Network().Peers()))
}

func bootstrapRelaySource(ctx context.Context, num int) <-chan peer.AddrInfo {
	ch := make(chan peer.AddrInfo, num)
	go func() {
		defer close(ch)

		// Use all currently connected peers as relay candidates — with 40+
		// DHT peers connected, several will support circuit relay v2 HOP.
		if h := node; h != nil {
			peers := h.Network().Peers()
			fmt.Fprintf(os.Stderr, "[relay] peer source called, offering %d connected peers\n", len(peers))
			for _, pid := range peers {
				addrs := h.Peerstore().Addrs(pid)
				if len(addrs) == 0 {
					continue
				}
				select {
				case ch <- peer.AddrInfo{ID: pid, Addrs: addrs}:
				case <-ctx.Done():
					return
				}
			}
			if len(peers) > 0 {
				return
			}
		}

		// Fallback when not yet connected: bootstrap nodes.
		fmt.Fprintf(os.Stderr, "[relay] peer source fallback: using bootstrap nodes\n")
		for _, maddr := range dht.DefaultBootstrapPeers {
			info, err := peer.AddrInfoFromP2pAddr(maddr)
			if err != nil || len(info.Addrs) == 0 {
				continue
			}
			select {
			case ch <- *info:
			case <-ctx.Done():
				return
			}
		}
	}()
	return ch
}

func doSendFile(h host.Host, kp *knownPeer, transferID, filePath, filename string, totalBytes int64) error {
	pid, err := peer.Decode(kp.PeerID)
	if err != nil {
		return fmt.Errorf("peer id: %w", err)
	}

	dialAddrs := parseDialAddrs(kp.Addresses, pid)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	if err := h.Connect(ctx, peer.AddrInfo{ID: pid, Addrs: dialAddrs}); err != nil {
		return fmt.Errorf("connect: %w", err)
	}

	stream, err := h.NewStream(ctx, pid, fileProtocol)
	if err != nil {
		return fmt.Errorf("stream: %w", err)
	}
	defer stream.Close()

	offer := controlMsg{
		Type:       "OFFER",
		TransferID: transferID,
		PeerID:     h.ID().String(),
		Nickname:   nodeNickname,
		Filename:   filename,
		TotalBytes: totalBytes,
	}
	if err := writeControl(stream, offer); err != nil {
		return fmt.Errorf("offer: %w", err)
	}

	var resp controlMsg
	if err := readControl(stream, &resp); err != nil {
		return fmt.Errorf("response: %w", err)
	}
	if resp.Accepted == nil || !*resp.Accepted {
		msg := resp.Message
		if msg == "" {
			msg = "rejected"
		}
		emitTransferUpdate(transferID, "OUTGOING", 0, totalBytes, 0, "FAILED", kp.PeerID, filename, msg, "")
		return nil
	}

	f, err := os.Open(filePath)
	if err != nil {
		return fmt.Errorf("open: %w", err)
	}
	defer f.Close()

	type incomingMsg struct {
		msg controlMsg
		err error
	}
	incomingCh := make(chan incomingMsg, 64)
	go func() {
		for {
			var m controlMsg
			err := readControl(stream, &m)
			incomingCh <- incomingMsg{m, err}
			if err != nil || m.Type == "COMPLETION" {
				return
			}
		}
	}()

	drainACKs := func(ackedBytes *int64) error {
		for {
			select {
			case res := <-incomingCh:
				if res.err != nil {
					return fmt.Errorf("send: reading ack: %w", res.err)
				}
				if res.msg.Type == "DATA_ACK" && res.msg.BytesReceived > *ackedBytes {
					*ackedBytes = res.msg.BytesReceived
				}
			default:
				return nil
			}
		}
	}

	hasher := blake3.New(32, nil)
	buf := make([]byte, 64*1024)
	var sent, ackedBytes int64
	start := time.Now()
	emitTransferUpdate(transferID, "OUTGOING", 0, totalBytes, 0, "IN_PROGRESS", kp.PeerID, filename, "", "")

	for {
		if err := drainACKs(&ackedBytes); err != nil {
			return err
		}
		for sent-ackedBytes >= maxUnacked {
			timer := time.NewTimer(ackTimeout)
			select {
			case res := <-incomingCh:
				timer.Stop()
				if res.err != nil {
					return fmt.Errorf("send: reading ack: %w", res.err)
				}
				if res.msg.Type == "DATA_ACK" && res.msg.BytesReceived > ackedBytes {
					ackedBytes = res.msg.BytesReceived
				}
			case <-timer.C:
				return fmt.Errorf("send: timed out waiting for DATA_ACK after %s", ackTimeout)
			}
		}

		n, readErr := f.Read(buf)
		if n > 0 {
			hasher.Write(buf[:n])
			if _, writeErr := stream.Write(buf[:n]); writeErr != nil {
				return fmt.Errorf("send: %w", writeErr)
			}
			sent += int64(n)
			emitTransferUpdate(transferID, "OUTGOING", sent, totalBytes, calcSpeed(sent, start), "IN_PROGRESS", kp.PeerID, filename, "", "")
		}
		if readErr == io.EOF {
			break
		}
		if readErr != nil {
			return fmt.Errorf("read file: %w", readErr)
		}
	}

	sentHash := hex.EncodeToString(hasher.Sum(nil))
	stream.CloseWrite()

	for {
		res := <-incomingCh
		if res.err != nil {
			return fmt.Errorf("completion: %w", res.err)
		}
		if res.msg.Type == "COMPLETION" {
			status := "COMPLETED"
			msg := ""
			finalHash := ""
			if res.msg.Completed == nil || !*res.msg.Completed {
				status = "FAILED"
				msg = res.msg.Message
			} else if res.msg.Blake3Hash != "" && res.msg.Blake3Hash != sentHash {
				status = "FAILED"
				msg = fmt.Sprintf("hash mismatch: sender=%s receiver=%s", sentHash, res.msg.Blake3Hash)
			} else {
				finalHash = sentHash
			}
			emitTransferUpdate(transferID, "OUTGOING", sent, totalBytes, 0, status, kp.PeerID, filename, msg, finalHash)
			return nil
		}
	}
}

func SendText(peerID, text, addrsStr string) error {
	h := node
	if h == nil {
		return fmt.Errorf("node not running")
	}

	kp, err := resolvePeer(h, peerID, addrsStr)
	if err != nil {
		return err
	}

	transferID := newUUID()
	totalBytes := int64(len([]byte(text)))

	emitTransferUpdateWithText(transferID, "OUTGOING", 0, totalBytes, 0, "QUEUED", peerID, "<text>", "", "", text)

	go func() {
		if err := doSendText(h, kp, transferID, text, totalBytes); err != nil {
			emitTransferUpdateWithText(transferID, "OUTGOING", 0, totalBytes, 0, "FAILED", peerID, "<text>", err.Error(), "", text)
		}
	}()
	return nil
}

func doSendText(h host.Host, kp *knownPeer, transferID, text string, totalBytes int64) error {
	pid, err := peer.Decode(kp.PeerID)
	if err != nil {
		return fmt.Errorf("peer id: %w", err)
	}

	dialAddrs := parseDialAddrs(kp.Addresses, pid)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	if err := h.Connect(ctx, peer.AddrInfo{ID: pid, Addrs: dialAddrs}); err != nil {
		return fmt.Errorf("connect: %w", err)
	}

	stream, err := h.NewStream(ctx, pid, fileProtocol)
	if err != nil {
		return fmt.Errorf("stream: %w", err)
	}
	defer stream.Close()

	offer := controlMsg{
		Type:        "OFFER",
		TransferID:  transferID,
		PeerID:      h.ID().String(),
		Nickname:    nodeNickname,
		Filename:    "<text>",
		TotalBytes:  totalBytes,
		TextContent: text,
	}
	if err := writeControl(stream, offer); err != nil {
		return fmt.Errorf("offer: %w", err)
	}

	var resp controlMsg
	if err := readControl(stream, &resp); err != nil {
		return fmt.Errorf("response: %w", err)
	}
	if resp.Accepted == nil || !*resp.Accepted {
		msg := resp.Message
		if msg == "" {
			msg = "rejected"
		}
		emitTransferUpdateWithText(transferID, "OUTGOING", 0, totalBytes, 0, "FAILED", kp.PeerID, "<text>", msg, "", text)
		return nil
	}

	emitTransferUpdateWithText(transferID, "OUTGOING", totalBytes, totalBytes, 0, "COMPLETED", kp.PeerID, "<text>", "", "", text)
	return nil
}

func handleIncomingStream(stream network.Stream) {
	defer stream.Close()

	remotePeerID := stream.Conn().RemotePeer().String()

	var offer controlMsg
	if err := readControl(stream, &offer); err != nil || offer.Type != "OFFER" {
		return
	}

	if offer.Nickname != "" {
		remoteAddr := stream.Conn().RemoteMultiaddr()
		upsertPeer(remotePeerID, offer.Nickname, []string{fmt.Sprintf("%s/p2p/%s", remoteAddr, remotePeerID)})
	}

	if offer.TextContent != "" {
		totalBytes := int64(len([]byte(offer.TextContent)))
		pt := &pendingTransfer{
			TransferID:  offer.TransferID,
			PeerID:      remotePeerID,
			Filename:    "<text>",
			TotalBytes:  totalBytes,
			TextContent: offer.TextContent,
			decision:    make(chan transferDecision, 1),
		}

		pendingMu.Lock()
		pendingTransfers[offer.TransferID] = pt
		pendingMu.Unlock()

		emitJSON(map[string]interface{}{
			"type":       "INCOMING_FILE_REQUEST",
			"transferId": offer.TransferID,
			"peerId":     remotePeerID,
			"filename":   "<text>",
			"totalBytes": totalBytes,
		})

		var decision transferDecision
		select {
		case decision = <-pt.decision:
		case <-time.After(5 * time.Minute):
			boolFalse := false
			writeControl(stream, controlMsg{Type: "RESPONSE", TransferID: offer.TransferID, Accepted: &boolFalse, Message: "timed out"})
			pendingMu.Lock()
			delete(pendingTransfers, offer.TransferID)
			pendingMu.Unlock()
			return
		}

		pendingMu.Lock()
		delete(pendingTransfers, offer.TransferID)
		pendingMu.Unlock()

		if !decision.accepted {
			boolFalse := false
			writeControl(stream, controlMsg{Type: "RESPONSE", TransferID: offer.TransferID, Accepted: &boolFalse, Message: "Rejected by user"})
			emitTransferUpdateWithText(offer.TransferID, "INCOMING", 0, totalBytes, 0, "FAILED", remotePeerID, "<text>", "Rejected by user", "", "")
			return
		}

		boolTrue := true
		writeControl(stream, controlMsg{Type: "RESPONSE", TransferID: offer.TransferID, Accepted: &boolTrue})
		emitTransferUpdateWithText(offer.TransferID, "INCOMING", totalBytes, totalBytes, 0, "COMPLETED", remotePeerID, "<text>", "", "", offer.TextContent)
		return
	}

	pt := &pendingTransfer{
		TransferID: offer.TransferID,
		PeerID:     remotePeerID,
		Filename:   offer.Filename,
		TotalBytes: offer.TotalBytes,
		decision:   make(chan transferDecision, 1),
	}

	pendingMu.Lock()
	pendingTransfers[offer.TransferID] = pt
	pendingMu.Unlock()

	emitJSON(map[string]interface{}{
		"type":       "INCOMING_FILE_REQUEST",
		"transferId": offer.TransferID,
		"peerId":     remotePeerID,
		"filename":   offer.Filename,
		"totalBytes": offer.TotalBytes,
	})

	var decision transferDecision
	select {
	case decision = <-pt.decision:
	case <-time.After(5 * time.Minute):
		boolFalse := false
		writeControl(stream, controlMsg{Type: "RESPONSE", TransferID: offer.TransferID, Accepted: &boolFalse, Message: "timed out"})
		pendingMu.Lock()
		delete(pendingTransfers, offer.TransferID)
		pendingMu.Unlock()
		return
	}

	pendingMu.Lock()
	delete(pendingTransfers, offer.TransferID)
	pendingMu.Unlock()

	if !decision.accepted {
		boolFalse := false
		writeControl(stream, controlMsg{Type: "RESPONSE", TransferID: offer.TransferID, Accepted: &boolFalse, Message: "Rejected by user"})
		emitTransferUpdate(offer.TransferID, "INCOMING", 0, offer.TotalBytes, 0, "FAILED", remotePeerID, offer.Filename, "Rejected by user", "")
		return
	}

	boolTrue := true
	writeControl(stream, controlMsg{Type: "RESPONSE", TransferID: offer.TransferID, Accepted: &boolTrue})
	receiveFile(stream, offer.TransferID, remotePeerID, offer.Filename, offer.TotalBytes, decision.savePath)
}

const (
	ackInterval = 1 * 1024 * 1024
	maxUnacked  = 4 * 1024 * 1024
	ackTimeout  = 30 * time.Second
)

func receiveFile(stream network.Stream, transferID, peerID, filename string, totalBytes int64, savePath string) {
	partPath := savePath + ".part"

	if err := os.MkdirAll(filepath.Dir(savePath), 0755); err != nil {
		boolFalse := false
		writeControl(stream, controlMsg{Type: "COMPLETION", TransferID: transferID, Completed: &boolFalse, Message: err.Error()})
		emitTransferUpdate(transferID, "INCOMING", 0, totalBytes, 0, "FAILED", peerID, filename, err.Error(), "")
		return
	}

	f, err := os.Create(partPath)
	if err != nil {
		boolFalse := false
		writeControl(stream, controlMsg{Type: "COMPLETION", TransferID: transferID, Completed: &boolFalse, Message: err.Error()})
		emitTransferUpdate(transferID, "INCOMING", 0, totalBytes, 0, "FAILED", peerID, filename, err.Error(), "")
		return
	}

	hasher := blake3.New(32, nil)
	buf := make([]byte, 64*1024)
	var received int64
	var nextAckAt int64 = ackInterval
	start := time.Now()
	emitTransferUpdate(transferID, "INCOMING", 0, totalBytes, 0, "IN_PROGRESS", peerID, filename, "", "")

	var writeErr error
	for received < totalBytes {
		toRead := int64(len(buf))
		if remaining := totalBytes - received; remaining < toRead {
			toRead = remaining
		}
		n, readErr := stream.Read(buf[:toRead])
		if n > 0 {
			hasher.Write(buf[:n])
			if _, we := f.Write(buf[:n]); we != nil {
				writeErr = we
				break
			}
			received += int64(n)
			if received >= nextAckAt {
				writeControl(stream, controlMsg{Type: "DATA_ACK", TransferID: transferID, BytesReceived: received})
				nextAckAt = received + ackInterval
			}
			emitTransferUpdate(transferID, "INCOMING", received, totalBytes, calcSpeed(received, start), "IN_PROGRESS", peerID, filename, "", "")
		}
		if readErr == io.EOF {
			break
		}
		if readErr != nil {
			writeErr = readErr
			break
		}
	}

	f.Sync()
	f.Close()

	if writeErr != nil {
		os.Remove(partPath)
		boolFalse := false
		writeControl(stream, controlMsg{Type: "COMPLETION", TransferID: transferID, Completed: &boolFalse, Message: writeErr.Error()})
		emitTransferUpdate(transferID, "INCOMING", received, totalBytes, 0, "FAILED", peerID, filename, writeErr.Error(), "")
		return
	}

	if err := os.Rename(partPath, savePath); err != nil {
		os.Remove(partPath)
		boolFalse := false
		writeControl(stream, controlMsg{Type: "COMPLETION", TransferID: transferID, Completed: &boolFalse, Message: err.Error()})
		emitTransferUpdate(transferID, "INCOMING", received, totalBytes, 0, "FAILED", peerID, filename, err.Error(), "")
		return
	}

	receivedHash := hex.EncodeToString(hasher.Sum(nil))
	boolTrue := true
	writeControl(stream, controlMsg{Type: "COMPLETION", TransferID: transferID, Completed: &boolTrue, Blake3Hash: receivedHash})
	emitTransferUpdate(transferID, "INCOMING", received, totalBytes, 0, "COMPLETED", peerID, filename, "", receivedHash)
}

func watchAddressChanges(ctx context.Context, h host.Host, deviceIP string, addrUpdated chan<- struct{}) {
	sub, err := h.EventBus().Subscribe(new(event.EvtLocalAddressesUpdated))
	if err != nil {
		return
	}
	defer sub.Close()
	for {
		select {
		case <-ctx.Done():
			return
		case evt, ok := <-sub.Out():
			if !ok {
				return
			}
			if update, ok2 := evt.(event.EvtLocalAddressesUpdated); ok2 {
				for _, a := range update.Current {
					fmt.Fprintf(os.Stderr, "[addr] new address: %s\n", a.Address)
				}
			}
			emitNodeStarted(h, deviceIP)
			select {
			case addrUpdated <- struct{}{}:
			default:
			}
		}
	}
}

func handleHelloStream(stream network.Stream) {
	defer stream.Close()
	remotePeerID := stream.Conn().RemotePeer().String()

	var msg controlMsg
	if err := readControl(stream, &msg); err != nil || msg.Type != "HELLO" {
		return
	}

	reply := controlMsg{Type: "HELLO", Nickname: nodeNickname}
	_ = writeControl(stream, reply)

	nick := msg.Nickname
	if nick == "" {
		nick = remotePeerID
	}
	remoteAddr := stream.Conn().RemoteMultiaddr()
	upsertPeer(remotePeerID, nick, []string{fmt.Sprintf("%s/p2p/%s", remoteAddr, remotePeerID)})
}

func sayHello(h host.Host, peerID string) {
	pid, err := peer.Decode(peerID)
	if err != nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	stream, err := h.NewStream(ctx, pid, helloProtocol)
	if err != nil {
		return
	}
	defer stream.Close()

	msg := controlMsg{Type: "HELLO", Nickname: nodeNickname}
	if err := writeControl(stream, msg); err != nil {
		return
	}

	var reply controlMsg
	if err := readControl(stream, &reply); err != nil || reply.Type != "HELLO" {
		return
	}

	nick := reply.Nickname
	if nick == "" {
		nick = peerID
	}

	peersMu.RLock()
	kp := knownPeers[peerID]
	peersMu.RUnlock()
	var addrs []string
	if kp != nil {
		addrs = kp.Addresses
	} else {
		remoteAddr := stream.Conn().RemoteMultiaddr()
		addrs = []string{fmt.Sprintf("%s/p2p/%s", remoteAddr, peerID)}
	}
	upsertPeer(peerID, nick, addrs)
}

type mdnsNotifee struct{ h host.Host }

func (n *mdnsNotifee) HandlePeerFound(pi peer.AddrInfo) {
	if pi.ID.String() == nodePeerID {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	n.h.Connect(ctx, pi)

	var addrs []string
	for _, a := range pi.Addrs {
		addrs = append(addrs, fmt.Sprintf("%s/p2p/%s", a, pi.ID))
	}
	upsertPeer(pi.ID.String(), pi.ID.String(), addrs)
	go sayHello(n.h, pi.ID.String())
}

func startMDNS(ctx context.Context, h host.Host) {
	svc := mdns.NewMdnsService(h, mdnsServiceTag, &mdnsNotifee{h: h})
	if err := svc.Start(); err != nil {
		return
	}
	<-ctx.Done()
	svc.Close()
}

func runDiscoveryLoop(ctx context.Context, h host.Host, servers []string) {
	registerWithServers(h, servers)

	heartbeat := time.NewTicker(15 * time.Second)
	poll := time.NewTicker(5 * time.Second)
	defer heartbeat.Stop()
	defer poll.Stop()

	for {
		select {
		case <-ctx.Done():
			unregisterFromServers(h, servers)
			return
		case <-heartbeat.C:
			heartbeatServers(h, servers)
		case <-poll.C:
			pollServers(h, servers)
		}
	}
}

func registerWithServers(h host.Host, servers []string) {
	addrs := currentListenAddresses(h, preferredLocalIPv4())
	payload, _ := json.Marshal(discoveryRegisterRequest{
		PeerID:    h.ID().String(),
		Nick:      nodeNickname,
		Addresses: addrs,
		Platform:  nodePlatform,
	})
	client := &http.Client{Timeout: 5 * time.Second}
	for _, s := range servers {
		req, err := http.NewRequest("POST", strings.TrimSuffix(s, "/")+"/api/peers", strings.NewReader(string(payload)))
		if err != nil {
			continue
		}
		req.Header.Set("Content-Type", "application/json")
		resp, err := client.Do(req)
		if err == nil {
			resp.Body.Close()
		}
	}
}

func heartbeatServers(h host.Host, servers []string) {
	client := &http.Client{Timeout: 5 * time.Second}
	for _, s := range servers {
		url := fmt.Sprintf("%s/api/peers/%s/heartbeat", strings.TrimSuffix(s, "/"), h.ID())
		req, err := http.NewRequest("POST", url, nil)
		if err != nil {
			continue
		}
		resp, err := client.Do(req)
		if err == nil {
			if resp.StatusCode == 404 {
				resp.Body.Close()
				registerWithServers(h, []string{s})
				continue
			}
			resp.Body.Close()
		}
	}
}

func unregisterFromServers(h host.Host, servers []string) {
	client := &http.Client{Timeout: 5 * time.Second}
	for _, s := range servers {
		url := fmt.Sprintf("%s/api/peers/%s", strings.TrimSuffix(s, "/"), h.ID())
		req, _ := http.NewRequest("DELETE", url, nil)
		resp, err := client.Do(req)
		if err == nil {
			resp.Body.Close()
		}
	}
}

func pollServers(h host.Host, servers []string) {
	selfID := h.ID().String()
	client := &http.Client{Timeout: 5 * time.Second}
	for _, s := range servers {
		resp, err := client.Get(strings.TrimSuffix(s, "/") + "/api/peers")
		if err != nil {
			continue
		}
		var payload discoveryPeersResponse
		decodeErr := json.NewDecoder(resp.Body).Decode(&payload)
		resp.Body.Close()
		if decodeErr != nil {
			continue
		}
		for _, p := range payload.Peers {
			if p.PeerID == selfID {
				continue
			}
			nick := p.Nick
			if nick == "" {
				nick = p.PeerID
			}
			upsertPeer(p.PeerID, nick, p.Addresses)
		}
		return
	}
}

func runPeerSweep(ctx context.Context) {
	ticker := time.NewTicker(sweepIntervalSecs * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			sweepPeers()
		}
	}
}

func sweepPeers() {
	threshold := time.Duration(peerStaleMillis) * time.Millisecond
	now := time.Now()

	peersMu.RLock()
	type stalePeer struct {
		id string
		kp knownPeer
	}
	var stale []stalePeer
	for id, kp := range knownPeers {
		if now.Sub(kp.LastSeen) > threshold {
			stale = append(stale, stalePeer{id: id, kp: *kp})
		}
	}
	peersMu.RUnlock()

	var offline []string
	for _, candidate := range stale {
		if verifyPeerReachability(&candidate.kp) {
			peersMu.Lock()
			if current := knownPeers[candidate.id]; current != nil {
				current.LastSeen = time.Now()
			}
			peersMu.Unlock()
			continue
		}

		peersMu.Lock()
		if current := knownPeers[candidate.id]; current != nil && now.Sub(current.LastSeen) > threshold {
			delete(knownPeers, candidate.id)
			offline = append(offline, candidate.id)
		}
		peersMu.Unlock()
	}

	for _, id := range offline {
		emitJSON(map[string]interface{}{"type": "PEER_OFFLINE", "peerId": id})
	}
}

func upsertPeer(peerID, nickname string, addresses []string) {
	peersMu.Lock()
	existing, isNew := knownPeers[peerID], knownPeers[peerID] == nil
	var oldNickname string
	var mergedAddrs []string
	var addressChanged bool
	if isNew {
		knownPeers[peerID] = &knownPeer{PeerID: peerID, Nickname: nickname, Addresses: addresses, LastSeen: time.Now()}
		mergedAddrs = addresses
	} else {
		oldNickname = existing.Nickname
		existing.LastSeen = time.Now()
		mergedAddrs = mergeAddresses(existing.Addresses, addresses)
		addressChanged = !sameStringSlice(existing.Addresses, mergedAddrs)
		existing.Addresses = mergedAddrs
		existing.Nickname = nickname
	}
	peersMu.Unlock()

	if isNew {
		emitJSON(map[string]interface{}{
			"type":      "PEER_DISCOVERED",
			"peerId":    peerID,
			"nickname":  nickname,
			"addresses": addresses,
		})
	} else {
		if nickname != oldNickname {
			emitJSON(map[string]interface{}{
				"type":        "PEER_NICKNAME_CHANGED",
				"peerId":      peerID,
				"newNickname": nickname,
			})
		}
		if addressChanged {
			emitJSON(map[string]interface{}{
				"type":         "PEER_ADDRESSES_CHANGED",
				"peerId":       peerID,
				"newAddresses": mergedAddrs,
			})
		}
		emitJSON(map[string]interface{}{
			"type":      "PEER_DISCOVERED",
			"peerId":    peerID,
			"nickname":  nickname,
			"addresses": mergedAddrs,
		})
	}
}

func writeControl(w io.Writer, msg controlMsg) error {
	b, err := json.Marshal(msg)
	if err != nil {
		return err
	}
	header := make([]byte, 4)
	binary.BigEndian.PutUint32(header, uint32(len(b)))
	if _, err := w.Write(header); err != nil {
		return err
	}
	_, err = w.Write(b)
	return err
}

func readControl(r io.Reader, msg *controlMsg) error {
	header := make([]byte, 4)
	if _, err := io.ReadFull(r, header); err != nil {
		return err
	}
	size := binary.BigEndian.Uint32(header)
	if size == 0 || size > maxControlBytes {
		return fmt.Errorf("invalid control frame size: %d", size)
	}
	buf := make([]byte, size)
	if _, err := io.ReadFull(r, buf); err != nil {
		return err
	}
	return json.Unmarshal(buf, msg)
}

func loadOrCreateKey() (crypto.PrivKey, error) {
	for _, keyPath := range identityCandidatePaths() {
		if data, err := os.ReadFile(keyPath); err == nil {
			if key, ok := decodeStoredPrivateKey(keyPath, data); ok {
				return key, nil
			}
		}
	}

	privKey, _, err := crypto.GenerateEd25519Key(rand.Reader)
	if err != nil {
		return nil, err
	}

	persistPrivateKey(privKey)
	return privKey, nil
}

func emitJSON(v map[string]interface{}) {
	eventListenerMu.RLock()
	listener := eventListener
	eventListenerMu.RUnlock()
	if listener == nil {
		return
	}
	b, err := json.Marshal(v)
	if err != nil {
		return
	}
	defer func() {
		// The mobile bridge aborts the process on uncaught callback panics.
		// Contain listener failures so late lifecycle events do not crash the app.
		_ = recover()
	}()
	listener.OnEvent(string(b))
}

func emitNodeStarted(h host.Host, deviceIP string) {
	emitJSON(map[string]interface{}{
		"type":            "NODE_STARTED",
		"peerId":          h.ID().String(),
		"listenAddresses": currentListenAddresses(h, deviceIP),
	})
}

func emitTransferUpdate(transferID, direction string, bytesTransferred, totalBytes, speedBps int64, status, peerID, filename, message, blake3Hash string) {
	emitTransferUpdateWithText(transferID, direction, bytesTransferred, totalBytes, speedBps, status, peerID, filename, message, blake3Hash, "")
}

func emitTransferUpdateWithText(transferID, direction string, bytesTransferred, totalBytes, speedBps int64, status, peerID, filename, message, blake3Hash, textContent string) {
	ev := map[string]interface{}{
		"type":             "TRANSFER_UPDATE",
		"transferId":       transferID,
		"direction":        direction,
		"bytesTransferred": bytesTransferred,
		"totalBytes":       totalBytes,
		"speedBps":         speedBps,
		"status":           status,
		"peerId":           peerID,
		"filename":         filename,
	}
	if message != "" {
		ev["message"] = message
	}
	if blake3Hash != "" {
		ev["blake3Hash"] = blake3Hash
	}
	if textContent != "" {
		ev["textContent"] = textContent
	}
	emitJSON(ev)
}

func calcSpeed(bytes int64, start time.Time) int64 {
	elapsed := time.Since(start).Milliseconds()
	if elapsed <= 0 {
		return 0
	}
	return bytes * 1000 / elapsed
}

func parseRelayAddrs(raw string) []peer.AddrInfo {
	var result []peer.AddrInfo
	for _, s := range strings.Split(raw, ";") {
		s = strings.TrimSpace(s)
		if s == "" {
			continue
		}
		info, err := peer.AddrInfoFromString(s)
		if err != nil {
			continue
		}
		result = append(result, *info)
	}
	return result
}

func parseDialAddrs(addrStrings []string, pid peer.ID) []multiaddr.Multiaddr {
	var result []multiaddr.Multiaddr
	for _, s := range addrStrings {
		info, err := peer.AddrInfoFromString(s)
		if err != nil || info.ID != pid {
			continue
		}
		result = append(result, info.Addrs...)
	}
	return result
}

func mergeAddresses(existing, incoming []string) []string {
	seen := make(map[string]bool, len(existing))
	result := make([]string, 0, len(existing)+len(incoming))
	for _, a := range existing {
		if !seen[a] {
			seen[a] = true
			result = append(result, a)
		}
	}
	for _, a := range incoming {
		if !seen[a] {
			seen[a] = true
			result = append(result, a)
		}
	}
	return result
}

func splitServers(raw string) []string {
	var result []string
	for _, s := range strings.Split(raw, ";") {
		s = normalizeDiscoveryServer(s)
		if s != "" {
			result = append(result, s)
		}
	}
	return result
}

func newUUID() string {
	b := make([]byte, 16)
	rand.Read(b)
	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

const lanDiscoveryPort = 4102
const lanDiscoveryGroup = "239.255.99.99"

type lanBroadcastMsg struct {
	PeerID    string   `json:"peerId"`
	Nickname  string   `json:"nickname"`
	Addresses []string `json:"addresses"`
}

func runLANBroadcast(ctx context.Context, h host.Host) {
	go lanMulticastReceive(ctx)
	go lanMulticastSend(ctx, h)
}

func lanMulticastReceive(ctx context.Context) {
	groupAddr := &net.UDPAddr{IP: net.ParseIP(lanDiscoveryGroup), Port: lanDiscoveryPort}
	conn, err := net.ListenMulticastUDP("udp4", nil, groupAddr)
	if err != nil {
		return
	}
	conn.SetReadBuffer(65536)
	go func() {
		<-ctx.Done()
		conn.Close()
	}()
	buf := make([]byte, 4096)
	for {
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		n, _, err := conn.ReadFromUDP(buf)
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			continue
		}
		var msg lanBroadcastMsg
		if json.Unmarshal(buf[:n], &msg) != nil || msg.PeerID == nodePeerID {
			continue
		}
		nick := msg.Nickname
		if nick == "" {
			nick = msg.PeerID
		}
		upsertPeer(msg.PeerID, nick, msg.Addresses)
	}
}

func lanMulticastSend(ctx context.Context, h host.Host) {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	addr := &net.UDPAddr{IP: net.ParseIP(lanDiscoveryGroup), Port: lanDiscoveryPort}
	send := func() {
		addrs := currentListenAddresses(h, preferredLocalIPv4())
		payload, _ := json.Marshal(lanBroadcastMsg{
			PeerID:    h.ID().String(),
			Nickname:  nodeNickname,
			Addresses: addrs,
		})
		conn, err := net.DialUDP("udp4", nil, addr)
		if err != nil {
			return
		}
		conn.Write(payload)
		conn.Close()
	}
	send()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			send()
		}
	}
}

func currentListenAddresses(h host.Host, deviceIP string) []string {
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
		appendAddr(fmt.Sprintf("%s/p2p/%s", addr, peerID))
	}

	advertisedIP := strings.TrimSpace(deviceIP)
	if advertisedIP == "" {
		advertisedIP = preferredLocalIPv4()
	}
	if advertisedIP != "" {
		if tcpPort := currentPort(h, "tcp"); tcpPort > 0 {
			appendAddr(fmt.Sprintf("/ip4/%s/tcp/%d/p2p/%s", advertisedIP, tcpPort, peerID))
		}
		if quicPort := currentPort(h, "quic-v1"); quicPort > 0 {
			appendAddr(fmt.Sprintf("/ip4/%s/udp/%d/quic-v1/p2p/%s", advertisedIP, quicPort, peerID))
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

func verifyPeerReachability(kp *knownPeer) bool {
	h := node
	if h == nil {
		return false
	}
	pid, err := peer.Decode(kp.PeerID)
	if err != nil {
		return false
	}
	addrs := parseDialAddrs(kp.Addresses, pid)
	if len(addrs) == 0 {
		addrs = h.Peerstore().Addrs(pid)
	}
	if len(addrs) == 0 {
		return false
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return h.Connect(ctx, peer.AddrInfo{ID: pid, Addrs: addrs}) == nil
}

func sameStringSlice(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func decodeStoredPrivateKey(path string, data []byte) (crypto.PrivKey, bool) {
	trimmed := strings.TrimSpace(string(data))
	if strings.HasSuffix(path, ".json") {
		var stored struct {
			PrivateKey string `json:"privateKey"`
		}
		if err := json.Unmarshal(data, &stored); err != nil || strings.TrimSpace(stored.PrivateKey) == "" {
			return nil, false
		}
		trimmed = strings.TrimSpace(stored.PrivateKey)
	}
	decoded, err := base64.StdEncoding.DecodeString(trimmed)
	if err != nil {
		return nil, false
	}
	key, err := crypto.UnmarshalPrivateKey(decoded)
	if err != nil {
		return nil, false
	}
	return key, true
}

func persistPrivateKey(privKey crypto.PrivKey) {
	if strings.TrimSpace(dataDir) == "" {
		return
	}
	if err := os.MkdirAll(dataDir, 0700); err != nil {
		return
	}
	raw, err := crypto.MarshalPrivateKey(privKey)
	if err != nil {
		return
	}
	encoded := base64.StdEncoding.EncodeToString(raw)
	_ = os.WriteFile(filepath.Join(dataDir, "sharething_identity.key"), []byte(encoded), 0600)
	legacyPayload, err := json.Marshal(struct {
		PrivateKey string `json:"privateKey"`
	}{PrivateKey: encoded})
	if err == nil {
		_ = os.WriteFile(filepath.Join(dataDir, "identity.json"), legacyPayload, 0600)
	}
}

func identityCandidatePaths() []string {
	if strings.TrimSpace(dataDir) == "" {
		return nil
	}
	return []string{
		filepath.Join(dataDir, "identity.json"),
		filepath.Join(dataDir, "sharething_identity.key"),
	}
}

func normalizeDiscoveryServer(server string) string {
	trimmed := strings.TrimSpace(server)
	trimmed = strings.TrimSuffix(trimmed, "/")
	switch {
	case strings.HasPrefix(trimmed, "wss://"):
		return "https://" + strings.TrimPrefix(trimmed, "wss://")
	case strings.HasPrefix(trimmed, "ws://"):
		return "http://" + strings.TrimPrefix(trimmed, "ws://")
	default:
		return trimmed
	}
}

func defaultPlatformLabel() string {
	switch runtime.GOOS {
	case "android":
		return "android"
	default:
		return "desktop"
	}
}

func defaultDataDir(platform string) string {
	home, err := os.UserHomeDir()
	if err != nil || strings.TrimSpace(home) == "" {
		return ""
	}
	switch platform {
	case "android":
		return ""
	case "desktop":
		switch runtime.GOOS {
		case "windows":
			base := os.Getenv("LOCALAPPDATA")
			if strings.TrimSpace(base) == "" {
				base = filepath.Join(home, "AppData", "Local")
			}
			return filepath.Join(base, "ShareThing")
		case "darwin":
			return filepath.Join(home, "Library", "Application Support", "ShareThing", "data")
		default:
			base := os.Getenv("XDG_DATA_HOME")
			if strings.TrimSpace(base) == "" {
				base = filepath.Join(home, ".local", "share")
			}
			return filepath.Join(base, "sharething")
		}
	default:
		return ""
	}
}

func preferredLocalIPv4() string {
	// Ask the OS routing table which local address it would use for outbound
	// traffic — this reliably picks the real LAN adapter over VirtualBox /
	// VMware / Hyper-V host-only interfaces on all platforms.
	if conn, err := net.Dial("udp4", "8.8.8.8:80"); err == nil {
		defer conn.Close()
		if addr, ok := conn.LocalAddr().(*net.UDPAddr); ok && !addr.IP.IsLoopback() {
			if ip := addr.IP.To4(); ip != nil {
				return ip.String()
			}
		}
	}

	// Fallback: enumerate interfaces when there is no default route.
	ifaces, err := net.Interfaces()
	if err != nil {
		return ""
	}

	virtualKeywords := []string{"virtualbox", "vmware", "hyper-v", "vethernet", "vbox", "virtual"}
	match := func(name string) bool {
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
			if !match(iface.Name) && !match(iface.HardwareAddr.String()) {
				return ip.String()
			}
			if fallback == "" {
				fallback = ip.String()
			}
		}
	}
	return fallback
}
