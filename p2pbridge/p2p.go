package p2p

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"strings"

	"github.com/libp2p/go-libp2p"
	crypto "github.com/libp2p/go-libp2p/core/crypto"
	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/core/peer"
	"github.com/multiformats/go-multiaddr"
)

const defaultPort = 4101

var node host.Host
var nodeKey crypto.PrivKey

func Start() (string, error) {
	return StartWithPrivateKey("")
}

func StartWithPrivateKey(serializedKey string) (string, error) {
	privKey, err := loadOrCreatePrivateKey(serializedKey)
	if err != nil {
		return "", err
	}

	h, err := createHost(privKey)
	if err != nil {
		return "", err
	}

	node = h
	nodeKey = privKey
	addr := formatPeerMultiaddr(h.Addrs(), h.ID())
	return addr, nil
}

func ConnectToPeer(peerAddr string) error {
	if node == nil {
		return fmt.Errorf("node not started")
	}

	info, err := peer.AddrInfoFromString(peerAddr)
	if err != nil {
		return err
	}
	return node.Connect(context.Background(), *info)
}

func SendMessage(peerID string, message string) error {
	pid, err := peer.Decode(peerID)
	if err != nil {
		return err
	}
	stream, err := node.NewStream(context.Background(), pid, "/myapp/1.0.0")
	if err != nil {
		return err
	}
	defer stream.Close()
	_, err = stream.Write([]byte(message))
	return err
}

func GetId() string {
	if node == nil {
		return ""
	}
	return node.ID().String()
}

func GetMultiaddr() string {
	if node == nil {
		return ""
	}
	if len(node.Addrs()) == 0 {
		return ""
	}
	return formatPeerMultiaddr(node.Addrs(), node.ID())
}

func Stop() {
	if node != nil {
		node.Close()
	}
	node = nil
}

func ExportPrivateKey() string {
	if nodeKey == nil {
		return ""
	}

	bytes, err := crypto.MarshalPrivateKey(nodeKey)
	if err != nil {
		return ""
	}

	return base64.StdEncoding.EncodeToString(bytes)
}

func formatPeerMultiaddr(addrs []multiaddr.Multiaddr, id peer.ID) string {
	if len(addrs) == 0 {
		return ""
	}

	selected := addrs[0]
	for _, addr := range addrs {
		if strings.HasPrefix(addr.String(), "/ip4/") {
			selected = addr
			break
		}
	}

	return fmt.Sprintf("%s/p2p/%s", selected, id)
}

func createHost(privKey crypto.PrivKey) (host.Host, error) {
	defaultAddresses := []string{
		fmt.Sprintf("/ip4/0.0.0.0/tcp/%d", defaultPort),
		fmt.Sprintf("/ip4/0.0.0.0/udp/%d/quic-v1", defaultPort),
	}

	h, err := libp2p.New(
		libp2p.Identity(privKey),
		libp2p.ListenAddrStrings(defaultAddresses...),
	)
	if err == nil {
		return h, nil
	}

	return libp2p.New(libp2p.Identity(privKey))
}

func loadOrCreatePrivateKey(serializedKey string) (crypto.PrivKey, error) {
	if serializedKey != "" {
		decoded, err := base64.StdEncoding.DecodeString(serializedKey)
		if err != nil {
			return nil, err
		}

		return crypto.UnmarshalPrivateKey(decoded)
	}

	privKey, _, err := crypto.GenerateEd25519Key(rand.Reader)
	if err != nil {
		return nil, err
	}

	return privKey, nil
}
