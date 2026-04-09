package p2p

import (
	"context"
	"fmt"

	"github.com/libp2p/go-libp2p"
	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/core/peer" // ← add this
)

var node host.Host

func Start() (string, error) {
	h, err := libp2p.New()
	if err != nil {
		return "", err
	}
	node = h
	addr := fmt.Sprintf("%s/p2p/%s", h.Addrs()[0], h.ID())
	return addr, nil
}

func ConnectToPeer(peerAddr string) error {
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
	return fmt.Sprintf("%s/p2p/%s", node.Addrs()[0], node.ID())
}

func Stop() {
	if node != nil {
		node.Close()
	}
}
