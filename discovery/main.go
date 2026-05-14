package main

import (
	"encoding/json"
	"flag"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"
)

const peerTTL = 30 * time.Second

type peer struct {
	PeerID    string   `json:"peerId"`
	Nick      string   `json:"nick"`
	Addresses []string `json:"addresses"`
	lastSeen  time.Time
}

var (
	mu    sync.RWMutex
	peers = map[string]*peer{}
)

func main() {
	port := flag.String("port", "7000", "HTTP listen port")
	flag.Parse()

	go expireLoop()

	mux := http.NewServeMux()
	mux.HandleFunc("/api/peers", handlePeers)
	mux.HandleFunc("/api/peers/", handlePeerByID)

	addr := ":" + *port
	log.Printf("discovery server listening on %s", addr)
	log.Fatal(http.ListenAndServe(addr, mux))
}

func handlePeers(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		mu.RLock()
		list := make([]*peer, 0, len(peers))
		for _, p := range peers {
			list = append(list, p)
		}
		mu.RUnlock()
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"peers": list})

	case http.MethodPost:
		var req struct {
			PeerID    string   `json:"peerId"`
			Nick      string   `json:"nick"`
			Addresses []string `json:"addresses"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.PeerID == "" {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		mu.Lock()
		peers[req.PeerID] = &peer{
			PeerID:    req.PeerID,
			Nick:      req.Nick,
			Addresses: req.Addresses,
			lastSeen:  time.Now(),
		}
		mu.Unlock()
		w.WriteHeader(http.StatusNoContent)

	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

// handles /api/peers/<peerID> and /api/peers/<peerID>/heartbeat
func handlePeerByID(w http.ResponseWriter, r *http.Request) {
	path := strings.TrimPrefix(r.URL.Path, "/api/peers/")
	parts := strings.SplitN(path, "/", 2)
	peerID := parts[0]
	sub := ""
	if len(parts) == 2 {
		sub = parts[1]
	}

	switch {
	case sub == "heartbeat" && r.Method == http.MethodPost:
		mu.Lock()
		p, ok := peers[peerID]
		if ok {
			p.lastSeen = time.Now()
		}
		mu.Unlock()
		if !ok {
			http.Error(w, "not found", http.StatusNotFound)
			return
		}
		w.WriteHeader(http.StatusNoContent)

	case sub == "" && r.Method == http.MethodDelete:
		mu.Lock()
		delete(peers, peerID)
		mu.Unlock()
		w.WriteHeader(http.StatusNoContent)

	default:
		http.Error(w, "not found", http.StatusNotFound)
	}
}

func expireLoop() {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	for range ticker.C {
		cutoff := time.Now().Add(-peerTTL)
		mu.Lock()
		for id, p := range peers {
			if p.lastSeen.Before(cutoff) {
				delete(peers, id)
			}
		}
		mu.Unlock()
	}
}
