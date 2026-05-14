package p2p

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	libp2p "github.com/libp2p/go-libp2p"
	"github.com/libp2p/go-libp2p/core/crypto"
	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/core/network"
	"github.com/libp2p/go-libp2p/core/peer"
	"github.com/libp2p/go-libp2p/p2p/discovery/mdns"
	"github.com/multiformats/go-multiaddr"
)

const (
	fileProtocol      = "/sharething/files/1.0.0"
	mdnsServiceTag    = "_sharething._tcp.local."
	defaultPort       = 4101
	maxControlBytes   = 1 * 1024 * 1024
	peerStaleMillis   = 25_000
	sweepIntervalSecs = 10
)

type EventListener interface {
	OnEvent(eventJson string)
}

var (
	nodeMu   sync.Mutex
	node     host.Host
	nodeKey  crypto.PrivKey

	dataDir      string
	nodePeerID   string
	nodeNickname string
	cancelFn     context.CancelFunc

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
	TransferID string
	PeerID     string
	Filename   string
	TotalBytes int64
	once       sync.Once
	decision   chan transferDecision
}

type transferDecision struct {
	accepted bool
	savePath string
}

func (pt *pendingTransfer) resolve(d transferDecision) {
	pt.once.Do(func() { pt.decision <- d })
}

type controlMsg struct {
	Type       string `json:"type"`
	TransferID string `json:"transferId,omitempty"`
	PeerID     string `json:"peerId,omitempty"`
	Nickname   string `json:"nickname,omitempty"`
	Filename   string `json:"filename,omitempty"`
	TotalBytes int64  `json:"totalBytes,omitempty"`
	Accepted   *bool  `json:"accepted,omitempty"`
	Completed  *bool  `json:"completed,omitempty"`
	Message    string `json:"message,omitempty"`
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
	eventListener = l
}

func SetDataDir(path string) {
	dataDir = path
}

// Start launches the libp2p node.
//
// relayAddrs is a semicolon-separated list of relay multiaddresses
// (e.g. "/ip4/1.2.3.4/tcp/4100/p2p/12D3…"). When provided, the node
// enables AutoRelay (connecting to those relays) and hole punching via
// DCUtR so it can reach peers behind NAT.
func Start(nick, discoveryServers, relayAddrs, deviceIP string) error {
	nodeMu.Lock()
	defer nodeMu.Unlock()

	if node != nil {
		return nil
	}

	nodeNickname = nick

	privKey, err := loadOrCreateKey()
	if err != nil {
		return fmt.Errorf("identity: %w", err)
	}

	relayInfos := parseRelayAddrs(relayAddrs)

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

	if deviceIP != "" {
		tcpMA, err1 := multiaddr.NewMultiaddr(fmt.Sprintf("/ip4/%s/tcp/%d", deviceIP, defaultPort))
		quicMA, err2 := multiaddr.NewMultiaddr(fmt.Sprintf("/ip4/%s/udp/%d/quic-v1", deviceIP, defaultPort))
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

	ctx, cancel := context.WithCancel(context.Background())
	cancelFn = cancel

	go startMDNS(ctx, h)
	go runPeerSweep(ctx)
	go runLANBroadcast(ctx, h)

	servers := splitServers(discoveryServers)
	if len(servers) > 0 {
		go runDiscoveryLoop(ctx, h, servers)
	}

	var addrs []string
	for _, a := range h.Addrs() {
		addrs = append(addrs, fmt.Sprintf("%s/p2p/%s", a, h.ID()))
	}
	emitJSON(map[string]interface{}{
		"type":            "NODE_STARTED",
		"peerId":          nodePeerID,
		"listenAddresses": addrs,
	})
	return nil
}

func Stop() {
	nodeMu.Lock()
	defer nodeMu.Unlock()

	if cancelFn != nil {
		cancelFn()
		cancelFn = nil
	}
	if node != nil {
		node.Close()
		node = nil
	}

	peersMu.Lock()
	knownPeers = map[string]*knownPeer{}
	peersMu.Unlock()

	emitJSON(map[string]interface{}{"type": "NODE_STOPPED"})
}

func SendFile(peerID, filePath, addrsStr string) error {
	h := node
	if h == nil {
		return fmt.Errorf("node not running")
	}

	peersMu.RLock()
	kp := knownPeers[peerID]
	peersMu.RUnlock()

	if kp == nil {
		pid, err := peer.Decode(peerID)
		if err != nil {
			return fmt.Errorf("unknown peer: %s", peerID)
		}

		addrs := h.Peerstore().Addrs(pid)
		if len(addrs) == 0 && addrsStr != "" {
			for _, s := range strings.Split(addrsStr, ";") {
				s = strings.TrimSpace(s)
				if s == "" {
					continue
				}
				ma, err := multiaddr.NewMultiaddr(s)
				if err == nil {
					addrs = append(addrs, ma)
				}
			}
		}

		if len(addrs) == 0 {
			return fmt.Errorf("unknown peer: %s", peerID)
		}

		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := h.Connect(ctx, peer.AddrInfo{ID: pid, Addrs: addrs}); err != nil {
			return fmt.Errorf("could not connect to peer: %w", err)
		}

		var addrStrs []string
		for _, a := range addrs {
			addrStrs = append(addrStrs, fmt.Sprintf("%s/p2p/%s", a, peerID))
		}
		upsertPeer(peerID, peerID, addrStrs)

		peersMu.RLock()
		kp = knownPeers[peerID]
		peersMu.RUnlock()
	}

	info, err := os.Stat(filePath)
	if err != nil || info.IsDir() {
		return fmt.Errorf("file not accessible: %s", filePath)
	}

	transferID := newUUID()
	totalBytes := info.Size()
	filename := filepath.Base(filePath)

	emitTransferUpdate(transferID, "OUTGOING", 0, totalBytes, 0, "QUEUED", peerID, filename, "")

	go func() {
		if err := doSendFile(h, kp, transferID, filePath, filename, totalBytes); err != nil {
			emitTransferUpdate(transferID, "OUTGOING", 0, totalBytes, 0, "FAILED", peerID, filename, err.Error())
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
		emitTransferUpdate(transferID, "OUTGOING", 0, totalBytes, 0, "FAILED", kp.PeerID, filename, msg)
		return nil
	}

	f, err := os.Open(filePath)
	if err != nil {
		return fmt.Errorf("open: %w", err)
	}
	defer f.Close()

	buf := make([]byte, 64*1024)
	var sent int64
	start := time.Now()
	emitTransferUpdate(transferID, "OUTGOING", 0, totalBytes, 0, "IN_PROGRESS", kp.PeerID, filename, "")

	for {
		n, readErr := f.Read(buf)
		if n > 0 {
			if _, writeErr := stream.Write(buf[:n]); writeErr != nil {
				return fmt.Errorf("send: %w", writeErr)
			}
			sent += int64(n)
			emitTransferUpdate(transferID, "OUTGOING", sent, totalBytes, calcSpeed(sent, start), "IN_PROGRESS", kp.PeerID, filename, "")
		}
		if readErr == io.EOF {
			break
		}
		if readErr != nil {
			return fmt.Errorf("read file: %w", readErr)
		}
	}

	stream.CloseWrite()

	var completion controlMsg
	if err := readControl(stream, &completion); err != nil {
		return fmt.Errorf("completion: %w", err)
	}

	status := "COMPLETED"
	msg := ""
	if completion.Completed == nil || !*completion.Completed {
		status = "FAILED"
		msg = completion.Message
	}
	emitTransferUpdate(transferID, "OUTGOING", sent, totalBytes, 0, status, kp.PeerID, filename, msg)
	return nil
}

func handleIncomingStream(stream network.Stream) {
	defer stream.Close()

	remotePeerID := stream.Conn().RemotePeer().String()

	var offer controlMsg
	if err := readControl(stream, &offer); err != nil || offer.Type != "OFFER" {
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
		emitTransferUpdate(offer.TransferID, "INCOMING", 0, offer.TotalBytes, 0, "FAILED", remotePeerID, offer.Filename, "Rejected by user")
		return
	}

	boolTrue := true
	writeControl(stream, controlMsg{Type: "RESPONSE", TransferID: offer.TransferID, Accepted: &boolTrue})
	receiveFile(stream, offer.TransferID, remotePeerID, offer.Filename, offer.TotalBytes, decision.savePath)
}

func receiveFile(stream network.Stream, transferID, peerID, filename string, totalBytes int64, savePath string) {
	partPath := savePath + ".part"

	if err := os.MkdirAll(filepath.Dir(savePath), 0755); err != nil {
		boolFalse := false
		writeControl(stream, controlMsg{Type: "COMPLETION", TransferID: transferID, Completed: &boolFalse, Message: err.Error()})
		emitTransferUpdate(transferID, "INCOMING", 0, totalBytes, 0, "FAILED", peerID, filename, err.Error())
		return
	}

	f, err := os.Create(partPath)
	if err != nil {
		boolFalse := false
		writeControl(stream, controlMsg{Type: "COMPLETION", TransferID: transferID, Completed: &boolFalse, Message: err.Error()})
		emitTransferUpdate(transferID, "INCOMING", 0, totalBytes, 0, "FAILED", peerID, filename, err.Error())
		return
	}

	buf := make([]byte, 64*1024)
	var received int64
	start := time.Now()
	emitTransferUpdate(transferID, "INCOMING", 0, totalBytes, 0, "IN_PROGRESS", peerID, filename, "")

	var writeErr error
	for received < totalBytes {
		toRead := int64(len(buf))
		if remaining := totalBytes - received; remaining < toRead {
			toRead = remaining
		}
		n, readErr := stream.Read(buf[:toRead])
		if n > 0 {
			if _, we := f.Write(buf[:n]); we != nil {
				writeErr = we
				break
			}
			received += int64(n)
			emitTransferUpdate(transferID, "INCOMING", received, totalBytes, calcSpeed(received, start), "IN_PROGRESS", peerID, filename, "")
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
		emitTransferUpdate(transferID, "INCOMING", received, totalBytes, 0, "FAILED", peerID, filename, writeErr.Error())
		return
	}

	if err := os.Rename(partPath, savePath); err != nil {
		os.Remove(partPath)
		boolFalse := false
		writeControl(stream, controlMsg{Type: "COMPLETION", TransferID: transferID, Completed: &boolFalse, Message: err.Error()})
		emitTransferUpdate(transferID, "INCOMING", received, totalBytes, 0, "FAILED", peerID, filename, err.Error())
		return
	}

	boolTrue := true
	writeControl(stream, controlMsg{Type: "COMPLETION", TransferID: transferID, Completed: &boolTrue})
	emitTransferUpdate(transferID, "INCOMING", received, totalBytes, 0, "COMPLETED", peerID, filename, "")
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
	var addrs []string
	for _, a := range h.Addrs() {
		addrs = append(addrs, fmt.Sprintf("%s/p2p/%s", a, h.ID()))
	}
	payload, _ := json.Marshal(discoveryRegisterRequest{
		PeerID:    h.ID().String(),
		Nick:      nodeNickname,
		Addresses: addrs,
		Platform:  "android",
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

	peersMu.Lock()
	var stale []string
	for id, kp := range knownPeers {
		if now.Sub(kp.LastSeen) > threshold {
			stale = append(stale, id)
		}
	}
	for _, id := range stale {
		delete(knownPeers, id)
	}
	peersMu.Unlock()

	for _, id := range stale {
		emitJSON(map[string]interface{}{"type": "PEER_OFFLINE", "peerId": id})
	}
}

func upsertPeer(peerID, nickname string, addresses []string) {
	peersMu.Lock()
	existing, isNew := knownPeers[peerID], knownPeers[peerID] == nil
	var oldNickname string
	var mergedAddrs []string
	if isNew {
		knownPeers[peerID] = &knownPeer{PeerID: peerID, Nickname: nickname, Addresses: addresses, LastSeen: time.Now()}
		mergedAddrs = addresses
	} else {
		oldNickname = existing.Nickname
		existing.LastSeen = time.Now()
		existing.Addresses = mergeAddresses(existing.Addresses, addresses)
		existing.Nickname = nickname
		mergedAddrs = existing.Addresses
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
	if dataDir != "" {
		keyPath := filepath.Join(dataDir, "sharething_identity.key")
		if data, err := os.ReadFile(keyPath); err == nil {
			if decoded, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(data))); err == nil {
				if key, err := crypto.UnmarshalPrivateKey(decoded); err == nil {
					return key, nil
				}
			}
		}
	}

	privKey, _, err := crypto.GenerateEd25519Key(rand.Reader)
	if err != nil {
		return nil, err
	}

	if dataDir != "" {
		os.MkdirAll(dataDir, 0700)
		if b, err := crypto.MarshalPrivateKey(privKey); err == nil {
			os.WriteFile(
				filepath.Join(dataDir, "sharething_identity.key"),
				[]byte(base64.StdEncoding.EncodeToString(b)),
				0600,
			)
		}
	}
	return privKey, nil
}

func emitJSON(v map[string]interface{}) {
	if eventListener == nil {
		return
	}
	b, err := json.Marshal(v)
	if err != nil {
		return
	}
	eventListener.OnEvent(string(b))
}

func emitTransferUpdate(transferID, direction string, bytesTransferred, totalBytes, speedBps int64, status, peerID, filename, message string) {
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
		s = strings.TrimSpace(s)
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
		var addrs []string
		for _, a := range h.Addrs() {
			addrs = append(addrs, fmt.Sprintf("%s/p2p/%s", a, h.ID()))
		}
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
