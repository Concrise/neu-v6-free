package main

import (
	"context"
	"encoding/hex"
	"fmt"
	"net"
	"net/netip"
	"strconv"
	"strings"
	"sync"
	"time"
)

// 只查询公网 IPv6 所属网络，不把 ASN 当作网站身份；按 /64 合并查询，避免发送完整主机地址。
type ipOwner struct {
	Provider string `json:"provider"`
	ASN      string `json:"asn"`
	Source   string `json:"source"`
}

type ownerEntry struct {
	value ipOwner
	until time.Time
	done  chan struct{}
}

var ownerCache = struct {
	sync.Mutex
	items   map[string]*ownerEntry
	workers chan struct{}
}{items: map[string]*ownerEntry{}, workers: make(chan struct{}, 4)}

func ownerQuery(ip netip.Addr) (string, error) {
	if !ip.Is6() || ip.Is4In6() || !ip.IsGlobalUnicast() || ip.IsPrivate() || inLan(ip) {
		return "", bad("只能识别公网 IPv6 地址")
	}
	a := ip.As16()
	s := hex.EncodeToString(a[:8])
	var b strings.Builder
	for i := len(s) - 1; i >= 0; i-- {
		b.WriteByte(s[i])
		b.WriteByte('.')
	}
	return b.String() + "origin6.asn.cymru.com", nil
}

func lookupOwner(ctx context.Context, ip netip.Addr, txt func(context.Context, string) ([]string, error)) (ipOwner, error) {
	query, err := ownerQuery(ip)
	if err != nil {
		return ipOwner{}, err
	}
	rows, err := txt(ctx, query)
	if err != nil {
		return ipOwner{}, err
	}
	for _, row := range rows {
		parts := strings.Split(row, "|")
		if len(parts) < 2 {
			continue
		}
		prefix, err := netip.ParsePrefix(strings.TrimSpace(parts[1]))
		if err != nil || !prefix.Contains(ip) {
			continue
		}
		asns := strings.Fields(parts[0])
		if len(asns) == 0 {
			continue
		}
		// 多源 ASN 不猜哪家承载了这一次连接，保持未知。
		if len(asns) != 1 {
			return ipOwner{}, bad("该地址有多个网络归属")
		}
		n, err := strconv.ParseUint(asns[0], 10, 32)
		if err != nil || n == 0 {
			continue
		}
		asn := fmt.Sprintf("AS%d", n)
		names, err := txt(ctx, asn+".asn.cymru.com")
		if err != nil {
			return ipOwner{}, err
		}
		for _, name := range names {
			fields := strings.Split(name, "|")
			if len(fields) >= 5 && strings.TrimSpace(fields[0]) == asns[0] {
				provider := strings.TrimSpace(strings.Join(fields[4:], " | "))
				if provider != "" && len(provider) < 512 {
					return ipOwner{provider, asn, "Team Cymru"}, nil
				}
			}
		}
	}
	return ipOwner{}, bad("暂未识别服务商")
}

func cachedOwner(ctx context.Context, ip netip.Addr) ipOwner {
	key := netip.PrefixFrom(ip, 64).Masked().String()
	ownerCache.Lock()
	if e := ownerCache.items[key]; e != nil && time.Now().Before(e.until) {
		ownerCache.Unlock()
		select {
		case <-e.done:
			return e.value
		case <-ctx.Done():
			return ipOwner{}
		}
	}
	if len(ownerCache.items) >= 512 {
		for k, e := range ownerCache.items {
			select {
			case <-e.done:
				delete(ownerCache.items, k)
			default:
			}
		}
	}
	e := &ownerEntry{until: time.Now().Add(10 * time.Minute), done: make(chan struct{})}
	ownerCache.items[key] = e
	ownerCache.Unlock()
	select {
	case ownerCache.workers <- struct{}{}:
		e.value, _ = lookupOwner(ctx, ip, net.DefaultResolver.LookupTXT)
		<-ownerCache.workers
	case <-ctx.Done():
	}
	ownerCache.Lock()
	if e.value.Provider != "" {
		e.until = time.Now().Add(24 * time.Hour)
	}
	close(e.done)
	ownerCache.Unlock()
	return e.value
}
