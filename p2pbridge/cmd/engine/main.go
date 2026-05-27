package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"runtime"
	"strings"
	"sync"

	p2p "sharething/p2pbridge"
)

type eventWriter struct {
	mu sync.Mutex
}

func (w *eventWriter) OnEvent(eventJSON string) {
	w.mu.Lock()
	defer w.mu.Unlock()
	fmt.Fprintln(os.Stdout, eventJSON)
}

type command struct {
	Type             string   `json:"type"`
	Nickname         string   `json:"nickname"`
	DiscoveryServers []string `json:"discoveryServers"`
	RelayAddrs       []string `json:"relayAddrs"`
	TargetPeerID     string   `json:"targetPeerId"`
	FilePath         string   `json:"filePath"`
	KnownAddresses   []string `json:"knownAddresses"`
	TransferID       string   `json:"transferId"`
	SavePath         string   `json:"savePath"`
	Text             string   `json:"text"`
}

func main() {
	writer := &eventWriter{}
	p2p.SetEventListener(writer)
	p2p.SetPlatform("desktop")

	ready, _ := json.Marshal(map[string]any{"type": "READY"})
	fmt.Fprintln(os.Stdout, string(ready))

	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)

	for scanner.Scan() {
		shouldExit := handleCommand(scanner.Bytes(), writer)
		if shouldExit {
			return
		}
	}

	if err := scanner.Err(); err != nil {
		emitError(writer, err.Error())
	}
}

func handleCommand(line []byte, writer *eventWriter) bool {
	var cmd command
	if err := json.Unmarshal(line, &cmd); err != nil {
		emitError(writer, err.Error())
		return false
	}

	switch cmd.Type {
	case "START_NODE":
		err := p2p.StartWithConfig(p2p.StartConfig{
			Nickname:            cmd.Nickname,
			DiscoveryServersRaw: strings.Join(cmd.DiscoveryServers, ";"),
			RelayAddrsRaw:       strings.Join(cmd.RelayAddrs, ";"),
			Platform:            "desktop",
		})
		if err != nil {
			emitError(writer, err.Error())
		}
	case "STOP_NODE":
		p2p.Stop()
		return true
	case "SEND_FILE":
		if err := p2p.SendFile(cmd.TargetPeerID, cmd.FilePath, strings.Join(cmd.KnownAddresses, ";")); err != nil {
			emitError(writer, err.Error())
		}
	case "ACCEPT_FILE":
		if err := p2p.AcceptFile(cmd.TransferID, cmd.SavePath); err != nil {
			emitError(writer, err.Error())
		}
	case "REJECT_FILE":
		if err := p2p.RejectFile(cmd.TransferID); err != nil {
			emitError(writer, err.Error())
		}
	case "SEND_TEXT":
		if err := p2p.SendText(cmd.TargetPeerID, cmd.Text, strings.Join(cmd.KnownAddresses, ";")); err != nil {
			emitError(writer, err.Error())
		}
	default:
		emitError(writer, fmt.Sprintf("unknown command: %s", cmd.Type))
	}

	return false
}

func emitError(writer *eventWriter, message string) {
	payload, _ := json.Marshal(map[string]any{
		"type":    "ERROR",
		"message": message,
		"os":      runtime.GOOS,
	})
	writer.OnEvent(string(payload))
}
