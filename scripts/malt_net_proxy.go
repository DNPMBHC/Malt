// SPDX-License-Identifier: GPL-3.0-or-later
// Owner: @DNPMBHC
package main

/*
#include <pthread/qos.h>
static int set_user_interactive_qos(void) {
    return pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
}
*/
import "C"

import (
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

var (
	gwMAC   = [6]byte{0x52, 0x54, 0x00, 0x15, 0x00, 0x01}
	gwIP    = [4]byte{10, 12, 0, 1}
	guestIP = [4]byte{10, 12, 0, 15}
	netMask = [4]byte{255, 255, 255, 0}
)

const (
	tcpMSS         = 1460
	tcpFlagFIN     = 0x01
	tcpFlagSYN     = 0x02
	tcpFlagRST     = 0x04
	tcpFlagPSH     = 0x08
	tcpFlagACK     = 0x10
	tcpStateSynRcv = 1
	tcpStateEstab  = 2
	tcpStateClosed = 3
)

type flowKey struct {
	srcPort uint16
	dstIP   [4]byte
	dstPort uint16
}

type udpFlow struct {
	conn     *net.UDPConn
	guestMAC [6]byte
	lastSeen int64
}

type tcpSeg struct {
	seq      uint32
	flags    byte
	payload  []byte
	sentAt   time.Time
	retries  int
}

type tcpFlow struct {
	key        flowKey
	guestMAC   [6]byte
	srcIP      [4]byte
	dstIP      [4]byte
	conn       net.Conn
	mu         sync.Mutex
	state      int
	sndUna     uint32
	sndNxt     uint32
	rcvNxt     uint32
	peerWin    uint32
	unacked    []*tcpSeg
	guestFin   bool
	hostFin    bool
	closed     bool
	notifyCh   chan struct{}
}

type proxyStats struct {
	QoSInteractive bool   `json:"qos_user_interactive"`
	RxFrames       uint64 `json:"rx_frames"`
	TxFrames       uint64 `json:"tx_frames"`
	UDPFwd         uint64 `json:"udp_fwd_packets"`
	UDPRet         uint64 `json:"udp_ret_packets"`
	ICMPEcho       uint64 `json:"icmp_echo_packets"`
	TCPSyn         uint64 `json:"tcp_syn_count"`
	TCPEstablished uint64 `json:"tcp_established_count"`
	TCPGuestToHost uint64 `json:"tcp_guest_to_host_bytes"`
	TCPHostToGuest uint64 `json:"tcp_host_to_guest_bytes"`
	TCPRetransmits uint64 `json:"tcp_retransmits"`
}

type proxyState struct {
	txCh       chan []byte
	mu         sync.Mutex
	udpFlows   map[flowKey]*udpFlow
	tcpFlows   map[flowKey]*tcpFlow
	ipID       uint32
	issCounter uint32
	stats      proxyStats
	closed     int32
}

func ipChecksum(b []byte) uint16 {
	var sum uint32
	for i := 0; i+1 < len(b); i += 2 {
		sum += uint32(binary.BigEndian.Uint16(b[i : i+2]))
	}
	if len(b)%2 == 1 {
		sum += uint32(b[len(b)-1]) << 8
	}
	for sum>>16 != 0 {
		sum = (sum & 0xffff) + (sum >> 16)
	}
	return ^uint16(sum)
}

func l4Checksum(srcIP, dstIP [4]byte, proto byte, seg []byte) uint16 {
	var sum uint32
	sum += uint32(binary.BigEndian.Uint16(srcIP[0:2]))
	sum += uint32(binary.BigEndian.Uint16(srcIP[2:4]))
	sum += uint32(binary.BigEndian.Uint16(dstIP[0:2]))
	sum += uint32(binary.BigEndian.Uint16(dstIP[2:4]))
	sum += uint32(proto)
	sum += uint32(len(seg))
	for i := 0; i+1 < len(seg); i += 2 {
		sum += uint32(binary.BigEndian.Uint16(seg[i : i+2]))
	}
	if len(seg)%2 == 1 {
		sum += uint32(seg[len(seg)-1]) << 8
	}
	for sum>>16 != 0 {
		sum = (sum & 0xffff) + (sum >> 16)
	}
	res := ^uint16(sum)
	if proto == 17 && res == 0 {
		return 0xffff
	}
	return res
}

func seqLess(a, b uint32) bool {
	return int32(a-b) < 0
}

func seqLessEq(a, b uint32) bool {
	return int32(a-b) <= 0
}

func (p *proxyState) enqueue(frame []byte) {
	if atomic.LoadInt32(&p.closed) != 0 {
		return
	}
	if len(frame) < 60 {
		padded := make([]byte, 60)
		copy(padded, frame)
		frame = padded
	}
	select {
	case p.txCh <- frame:
		atomic.AddUint64(&p.stats.TxFrames, 1)
	default:
	}
}

func (p *proxyState) buildUDPEtherFrame(dstMAC [6]byte, srcIP, dstIP [4]byte, srcPort, dstPort uint16, payload []byte) []byte {
	udpLen := 8 + len(payload)
	ipLen := 20 + udpLen
	frame := make([]byte, 14+ipLen)
	copy(frame[0:6], dstMAC[:])
	copy(frame[6:12], gwMAC[:])
	binary.BigEndian.PutUint16(frame[12:14], 0x0800)

	ip := frame[14:34]
	ip[0] = 0x45
	binary.BigEndian.PutUint16(ip[2:4], uint16(ipLen))
	id := uint16(atomic.AddUint32(&p.ipID, 1))
	binary.BigEndian.PutUint16(ip[4:6], id)
	binary.BigEndian.PutUint16(ip[6:8], 0x4000)
	ip[8] = 64
	ip[9] = 17
	copy(ip[12:16], srcIP[:])
	copy(ip[16:20], dstIP[:])
	binary.BigEndian.PutUint16(ip[10:12], ipChecksum(ip))

	udp := frame[34:]
	binary.BigEndian.PutUint16(udp[0:2], srcPort)
	binary.BigEndian.PutUint16(udp[2:4], dstPort)
	binary.BigEndian.PutUint16(udp[4:6], uint16(udpLen))
	copy(udp[8:], payload)
	binary.BigEndian.PutUint16(udp[6:8], l4Checksum(srcIP, dstIP, 17, udp))
	return frame
}

func (p *proxyState) buildTCPEtherFrame(
	dstMAC [6]byte,
	srcIP, dstIP [4]byte,
	srcPort, dstPort uint16,
	seq, ack uint32,
	flags byte,
	win uint16,
	options []byte,
	payload []byte,
) []byte {
	tcpHdrLen := 20 + len(options)
	tcpLen := tcpHdrLen + len(payload)
	ipLen := 20 + tcpLen
	frame := make([]byte, 14+ipLen)
	copy(frame[0:6], dstMAC[:])
	copy(frame[6:12], gwMAC[:])
	binary.BigEndian.PutUint16(frame[12:14], 0x0800)

	ip := frame[14:34]
	ip[0] = 0x45
	binary.BigEndian.PutUint16(ip[2:4], uint16(ipLen))
	id := uint16(atomic.AddUint32(&p.ipID, 1))
	binary.BigEndian.PutUint16(ip[4:6], id)
	binary.BigEndian.PutUint16(ip[6:8], 0x4000)
	ip[8] = 64
	ip[9] = 6
	copy(ip[12:16], srcIP[:])
	copy(ip[16:20], dstIP[:])
	binary.BigEndian.PutUint16(ip[10:12], ipChecksum(ip))

	tcp := frame[34:]
	binary.BigEndian.PutUint16(tcp[0:2], srcPort)
	binary.BigEndian.PutUint16(tcp[2:4], dstPort)
	binary.BigEndian.PutUint32(tcp[4:8], seq)
	binary.BigEndian.PutUint32(tcp[8:12], ack)
	tcp[12] = byte((tcpHdrLen / 4) << 4)
	tcp[13] = flags
	binary.BigEndian.PutUint16(tcp[14:16], win)
	if len(options) > 0 {
		copy(tcp[20:20+len(options)], options)
	}
	if len(payload) > 0 {
		copy(tcp[tcpHdrLen:], payload)
	}
	binary.BigEndian.PutUint16(tcp[16:18], l4Checksum(srcIP, dstIP, 6, tcp))
	return frame
}

func (p *proxyState) handleARP(frame []byte) {
	if len(frame) < 42 || binary.BigEndian.Uint16(frame[20:22]) != 1 {
		return
	}
	var targetIP [4]byte
	copy(targetIP[:], frame[38:42])
	if targetIP != gwIP {
		return
	}
	reply := make([]byte, 60)
	copy(reply[0:6], frame[6:12])
	copy(reply[6:12], gwMAC[:])
	binary.BigEndian.PutUint16(reply[12:14], 0x0806)
	binary.BigEndian.PutUint16(reply[14:16], 1)
	binary.BigEndian.PutUint16(reply[16:18], 0x0800)
	reply[18] = 6
	reply[19] = 4
	binary.BigEndian.PutUint16(reply[20:22], 2)
	copy(reply[22:28], gwMAC[:])
	copy(reply[28:32], gwIP[:])
	copy(reply[32:38], frame[22:28])
	copy(reply[38:42], frame[28:32])
	p.enqueue(reply)
}

func (p *proxyState) handleDHCP(guestMAC [6]byte, bootp []byte) {
	if len(bootp) < 240 || bootp[0] != 1 || binary.BigEndian.Uint32(bootp[236:240]) != 0x63825363 {
		return
	}
	msgType := byte(0)
	for i := 240; i < len(bootp); {
		opt := bootp[i]
		if opt == 255 {
			break
		}
		if opt == 0 {
			i++
			continue
		}
		if i+1 >= len(bootp) {
			break
		}
		olen := int(bootp[i+1])
		if i+2+olen > len(bootp) {
			break
		}
		if opt == 53 && olen == 1 {
			msgType = bootp[i+2]
		}
		i += 2 + olen
	}
	var replyType byte
	switch msgType {
	case 1:
		replyType = 2
	case 3:
		replyType = 5
	default:
		return
	}
	resp := make([]byte, 300)
	resp[0] = 2
	resp[1] = 1
	resp[2] = 6
	copy(resp[4:8], bootp[4:8])
	copy(resp[10:12], bootp[10:12])
	copy(resp[16:20], guestIP[:])
	copy(resp[20:24], gwIP[:])
	copy(resp[28:34], bootp[28:34])
	binary.BigEndian.PutUint32(resp[236:240], 0x63825363)
	idx := 240
	addOpt := func(code byte, data ...byte) {
		resp[idx] = code
		resp[idx+1] = byte(len(data))
		copy(resp[idx+2:], data)
		idx += 2 + len(data)
	}
	addOpt(53, replyType)
	addOpt(54, gwIP[0], gwIP[1], gwIP[2], gwIP[3])
	addOpt(51, 0x00, 0x01, 0x51, 0x80)
	addOpt(1, netMask[0], netMask[1], netMask[2], netMask[3])
	addOpt(3, gwIP[0], gwIP[1], gwIP[2], gwIP[3])
	addOpt(6, gwIP[0], gwIP[1], gwIP[2], gwIP[3])
	resp[idx] = 255
	idx++
	dstMAC := guestMAC
	dstIP := guestIP
	if binary.BigEndian.Uint16(bootp[10:12])&0x8000 != 0 {
		dstMAC = [6]byte{0xff, 0xff, 0xff, 0xff, 0xff, 0xff}
		dstIP = [4]byte{255, 255, 255, 255}
	}
	p.enqueue(p.buildUDPEtherFrame(dstMAC, gwIP, dstIP, 67, 68, resp[:idx]))
}

func (p *proxyState) handleICMP(frame []byte, ihl int) {
	icmp := frame[14+ihl:]
	if len(icmp) < 8 || icmp[0] != 8 {
		return
	}
	atomic.AddUint64(&p.stats.ICMPEcho, 1)
	out := make([]byte, len(frame))
	copy(out, frame)
	copy(out[0:6], frame[6:12])
	copy(out[6:12], gwMAC[:])
	ip := out[14 : 14+ihl]
	copy(ip[12:16], frame[14+16:14+20])
	copy(ip[16:20], frame[14+12:14+16])
	ip[8] = 64
	ip[10] = 0
	ip[11] = 0
	binary.BigEndian.PutUint16(ip[10:12], ipChecksum(ip))
	outICMP := out[14+ihl:]
	outICMP[0] = 0
	outICMP[2] = 0
	outICMP[3] = 0
	binary.BigEndian.PutUint16(outICMP[2:4], ipChecksum(outICMP))
	p.enqueue(out)
}

var upstreamDNSServer = detectUpstreamDNS()

func detectUpstreamDNS() string {
	candidates := make([]string, 0, 4)
	if raw, err := os.ReadFile("/etc/resolv.conf"); err == nil {
		for _, line := range strings.Split(string(raw), "\n") {
			fields := strings.Fields(strings.TrimSpace(line))
			if len(fields) >= 2 && fields[0] == "nameserver" {
				ip := net.ParseIP(fields[1])
				if ip != nil && ip.To4() != nil {
					addr := ip.To4().String() + ":53"
					candidates = append(candidates, addr)
				}
			}
		}
	}
	candidates = append(candidates, "223.5.5.5:53", "114.114.114.114:53", "8.8.8.8:53")
	for _, addr := range candidates {
		if probeUDPServer(addr) {
			return addr
		}
	}
	return candidates[0]
}

func probeUDPServer(addr string) bool {
	c, err := net.DialTimeout("udp4", addr, 400*time.Millisecond)
	if err != nil {
		return false
	}
	defer c.Close()
	// Minimal DNS standard query for "." NS
	query := []byte{0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x01}
	_ = c.SetDeadline(time.Now().Add(500 * time.Millisecond))
	if _, err := c.Write(query); err != nil {
		return false
	}
	buf := make([]byte, 512)
	n, err := c.Read(buf)
	return err == nil && n >= 12 && buf[0] == 0x12 && buf[1] == 0x34
}

func resolveHostTarget(dstIP [4]byte, dstPort uint16) string {
	if dstIP == gwIP {
		if dstPort == 53 {
			return upstreamDNSServer
		}
		return fmt.Sprintf("127.0.0.1:%d", dstPort)
	}
	return fmt.Sprintf("%d.%d.%d.%d:%d", dstIP[0], dstIP[1], dstIP[2], dstIP[3], dstPort)
}

func (p *proxyState) handleUDP(guestMAC [6]byte, srcIP, dstIP [4]byte, udp []byte) {
	if len(udp) < 8 {
		return
	}
	srcPort := binary.BigEndian.Uint16(udp[0:2])
	dstPort := binary.BigEndian.Uint16(udp[2:4])
	udpLen := int(binary.BigEndian.Uint16(udp[4:6]))
	if udpLen < 8 || udpLen > len(udp) {
		return
	}
	payload := udp[8:udpLen]
	if srcPort == 68 && dstPort == 67 {
		p.handleDHCP(guestMAC, payload)
		return
	}
	key := flowKey{srcPort: srcPort, dstIP: dstIP, dstPort: dstPort}
	p.mu.Lock()
	flow, ok := p.udpFlows[key]
	if !ok {
		raddr, err := net.ResolveUDPAddr("udp4", resolveHostTarget(dstIP, dstPort))
		if err != nil {
			p.mu.Unlock()
			return
		}
		conn, err := net.DialUDP("udp4", nil, raddr)
		if err != nil {
			p.mu.Unlock()
			return
		}
		_ = conn.SetReadBuffer(4 * 1024 * 1024)
		_ = conn.SetWriteBuffer(4 * 1024 * 1024)
		flow = &udpFlow{conn: conn, guestMAC: guestMAC, lastSeen: time.Now().UnixNano()}
		p.udpFlows[key] = flow
		go func(k flowKey, f *udpFlow, origDstIP, origSrcIP [4]byte) {
			runtime.LockOSThread()
			C.set_user_interactive_qos()
			buf := make([]byte, 4096)
			for {
				_ = f.conn.SetReadDeadline(time.Now().Add(60 * time.Second))
				n, err := f.conn.Read(buf)
				if err != nil {
					p.mu.Lock()
					if cur, exists := p.udpFlows[k]; exists && cur == f {
						delete(p.udpFlows, k)
					}
					p.mu.Unlock()
					_ = f.conn.Close()
					return
				}
				atomic.StoreInt64(&f.lastSeen, time.Now().UnixNano())
				atomic.AddUint64(&p.stats.UDPRet, 1)
				p.enqueue(p.buildUDPEtherFrame(f.guestMAC, origDstIP, origSrcIP, k.dstPort, k.srcPort, buf[:n]))
			}
		}(key, flow, dstIP, srcIP)
	}
	atomic.StoreInt64(&flow.lastSeen, time.Now().UnixNano())
	p.mu.Unlock()
	if _, err := flow.conn.Write(payload); err == nil {
		atomic.AddUint64(&p.stats.UDPFwd, 1)
	}
}

func (p *proxyState) closeTCPFlow(f *tcpFlow, sendRST bool) {
	f.mu.Lock()
	if f.closed {
		f.mu.Unlock()
		return
	}
	f.closed = true
	f.state = tcpStateClosed
	conn := f.conn
	seq := f.sndNxt
	ack := f.rcvNxt
	f.mu.Unlock()

	if sendRST {
		p.enqueue(p.buildTCPEtherFrame(f.guestMAC, f.dstIP, f.srcIP, f.key.dstPort, f.key.srcPort, seq, ack, tcpFlagRST|tcpFlagACK, 0, nil, nil))
	}
	if conn != nil {
		_ = conn.Close()
	}
	p.mu.Lock()
	if cur, ok := p.tcpFlows[f.key]; ok && cur == f {
		delete(p.tcpFlows, f.key)
	}
	p.mu.Unlock()
}

func (p *proxyState) tcpRetransmitLoop(f *tcpFlow) {
	ticker := time.NewTicker(40 * time.Millisecond)
	defer ticker.Stop()
	for range ticker.C {
		f.mu.Lock()
		if f.closed {
			f.mu.Unlock()
			return
		}
		now := time.Now()
		for _, seg := range f.unacked {
			if now.Sub(seg.sentAt) >= 120*time.Millisecond {
				if seg.retries >= 8 {
					f.mu.Unlock()
					p.closeTCPFlow(f, true)
					return
				}
				seg.retries++
				seg.sentAt = now
				atomic.AddUint64(&p.stats.TCPRetransmits, 1)
				var opts []byte
				if seg.flags&tcpFlagSYN != 0 {
					opts = []byte{2, 4, byte(tcpMSS >> 8), byte(tcpMSS & 0xff)}
				}
				p.enqueue(p.buildTCPEtherFrame(
					f.guestMAC, f.dstIP, f.srcIP, f.key.dstPort, f.key.srcPort,
					seg.seq, f.rcvNxt, seg.flags, 65535, opts, seg.payload,
				))
			}
		}
		f.mu.Unlock()
	}
}

func (p *proxyState) tcpHostReader(f *tcpFlow) {
	if f == nil || f.conn == nil {
		return
	}
	runtime.LockOSThread()
	C.set_user_interactive_qos()
	buf := make([]byte, tcpMSS*8)
	for {
		n, err := f.conn.Read(buf)
		if n > 0 {
			offset := 0
			for offset < n {
				// Respect guest receive window backpressure
				for {
					f.mu.Lock()
					if f.closed {
						f.mu.Unlock()
						return
					}
					inflight := f.sndNxt - f.sndUna
					win := f.peerWin
					if win < tcpMSS {
						win = tcpMSS
					}
					if inflight < win {
						chunkLen := n - offset
						if chunkLen > tcpMSS {
							chunkLen = tcpMSS
						}
						avail := int(win - inflight)
						if chunkLen > avail {
							chunkLen = avail
						}
						chunk := make([]byte, chunkLen)
						copy(chunk, buf[offset:offset+chunkLen])
						seq := f.sndNxt
						f.sndNxt += uint32(chunkLen)
						ack := f.rcvNxt
						flags := byte(tcpFlagACK)
						if offset+chunkLen >= n {
							flags |= tcpFlagPSH
						}
						f.unacked = append(f.unacked, &tcpSeg{
							seq:     seq,
							flags:   flags,
							payload: chunk,
							sentAt:  time.Now(),
						})
						f.mu.Unlock()
						atomic.AddUint64(&p.stats.TCPHostToGuest, uint64(chunkLen))
						p.enqueue(p.buildTCPEtherFrame(
							f.guestMAC, f.dstIP, f.srcIP, f.key.dstPort, f.key.srcPort,
							seq, ack, flags, 65535, nil, chunk,
						))
						offset += chunkLen
						break
					}
					f.mu.Unlock()
					select {
					case <-f.notifyCh:
					case <-time.After(15 * time.Millisecond):
					}
				}
			}
		}
		if err != nil {
			f.mu.Lock()
			if !f.closed && !f.hostFin {
				f.hostFin = true
				seq := f.sndNxt
				f.sndNxt++
				ack := f.rcvNxt
				f.unacked = append(f.unacked, &tcpSeg{
					seq:    seq,
					flags:  tcpFlagFIN | tcpFlagACK,
					sentAt: time.Now(),
				})
				f.mu.Unlock()
				p.enqueue(p.buildTCPEtherFrame(
					f.guestMAC, f.dstIP, f.srcIP, f.key.dstPort, f.key.srcPort,
					seq, ack, tcpFlagFIN|tcpFlagACK, 65535, nil, nil,
				))
				time.AfterFunc(3*time.Second, func() {
					p.closeTCPFlow(f, false)
				})
			} else {
				f.mu.Unlock()
			}
			return
		}
	}
}

func (p *proxyState) handleTCP(guestMAC [6]byte, srcIP, dstIP [4]byte, tcp []byte) {
	if len(tcp) < 20 {
		return
	}
	srcPort := binary.BigEndian.Uint16(tcp[0:2])
	dstPort := binary.BigEndian.Uint16(tcp[2:4])
	seq := binary.BigEndian.Uint32(tcp[4:8])
	ack := binary.BigEndian.Uint32(tcp[8:12])
	hdrLen := int((tcp[12] >> 4) * 4)
	if hdrLen < 20 || hdrLen > len(tcp) {
		return
	}
	flags := tcp[13]
	win := uint32(binary.BigEndian.Uint16(tcp[14:16]))
	payload := tcp[hdrLen:]
	key := flowKey{srcPort: srcPort, dstIP: dstIP, dstPort: dstPort}

	if flags&tcpFlagRST != 0 {
		p.mu.Lock()
		f := p.tcpFlows[key]
		p.mu.Unlock()
		if f != nil {
			p.closeTCPFlow(f, false)
		}
		return
	}

	if flags&tcpFlagSYN != 0 && flags&tcpFlagACK == 0 {
		atomic.AddUint64(&p.stats.TCPSyn, 1)
		p.mu.Lock()
		if existing, ok := p.tcpFlows[key]; ok {
			p.mu.Unlock()
			existing.mu.Lock()
			if existing.state == tcpStateSynRcv {
				if existing.conn != nil {
					opts := []byte{2, 4, byte(tcpMSS >> 8), byte(tcpMSS & 0xff)}
					p.enqueue(p.buildTCPEtherFrame(
						guestMAC, dstIP, srcIP, dstPort, srcPort,
						existing.sndUna, existing.rcvNxt, tcpFlagSYN|tcpFlagACK, 65535, opts, nil,
					))
				}
				existing.mu.Unlock()
				return
			}
			existing.mu.Unlock()
			p.closeTCPFlow(existing, false)
			p.mu.Lock()
		}
		iss := 0x15000000 + atomic.AddUint32(&p.issCounter, 65537)
		f := &tcpFlow{
			key:      key,
			guestMAC: guestMAC,
			srcIP:    srcIP,
			dstIP:    dstIP,
			state:    tcpStateSynRcv,
			sndUna:   iss,
			sndNxt:   iss + 1,
			rcvNxt:   seq + 1,
			peerWin:  win,
			notifyCh: make(chan struct{}, 1),
		}
		p.tcpFlows[key] = f
		p.mu.Unlock()

		go func() {
			target := resolveHostTarget(dstIP, dstPort)
			conn, err := net.DialTimeout("tcp4", target, 5*time.Second)
			if err != nil {
				p.closeTCPFlow(f, true)
				return
			}
			if tc, ok := conn.(*net.TCPConn); ok {
				_ = tc.SetNoDelay(true)
				_ = tc.SetReadBuffer(4 * 1024 * 1024)
				_ = tc.SetWriteBuffer(4 * 1024 * 1024)
			}
			f.mu.Lock()
			if f.closed {
				f.mu.Unlock()
				_ = conn.Close()
				return
			}
			f.conn = conn
			f.unacked = append(f.unacked, &tcpSeg{
				seq:    iss,
				flags:  tcpFlagSYN | tcpFlagACK,
				sentAt: time.Now(),
			})
			rcv := f.rcvNxt
			f.mu.Unlock()

			opts := []byte{2, 4, byte(tcpMSS >> 8), byte(tcpMSS & 0xff)}
			p.enqueue(p.buildTCPEtherFrame(
				guestMAC, dstIP, srcIP, dstPort, srcPort,
				iss, rcv, tcpFlagSYN|tcpFlagACK, 65535, opts, nil,
			))
			go p.tcpRetransmitLoop(f)
		}()
		return
	}

	p.mu.Lock()
	f := p.tcpFlows[key]
	p.mu.Unlock()
	if f == nil {
		p.enqueue(p.buildTCPEtherFrame(guestMAC, dstIP, srcIP, dstPort, srcPort, ack, seq+uint32(len(payload)), tcpFlagRST|tcpFlagACK, 0, nil, nil))
		return
	}

	f.mu.Lock()
	if f.closed {
		f.mu.Unlock()
		return
	}
	if win > 0 {
		f.peerWin = win
	}
	if flags&tcpFlagACK != 0 {
		if seqLess(f.sndUna, ack) && seqLessEq(ack, f.sndNxt) {
			f.sndUna = ack
			kept := f.unacked[:0]
			for _, seg := range f.unacked {
				segEnd := seg.seq + uint32(len(seg.payload))
				if seg.flags&(tcpFlagSYN|tcpFlagFIN) != 0 {
					segEnd++
				}
				if seqLess(ack, segEnd) {
					kept = append(kept, seg)
				}
			}
			f.unacked = kept
			select {
			case f.notifyCh <- struct{}{}:
			default:
			}
		}
		if f.state == tcpStateSynRcv && f.conn != nil && f.sndUna == f.sndNxt {
			f.state = tcpStateEstab
			atomic.AddUint64(&p.stats.TCPEstablished, 1)
			go p.tcpHostReader(f)
		}
	}

	var toWrite []byte
	sendAck := false
	if len(payload) > 0 {
		if seq == f.rcvNxt {
			toWrite = make([]byte, len(payload))
			copy(toWrite, payload)
			f.rcvNxt += uint32(len(payload))
			sendAck = true
		} else if seqLess(seq, f.rcvNxt) {
			overlap := int(f.rcvNxt - seq)
			if overlap < len(payload) {
				toWrite = make([]byte, len(payload)-overlap)
				copy(toWrite, payload[overlap:])
				f.rcvNxt += uint32(len(toWrite))
			}
			sendAck = true
		} else {
			sendAck = true
		}
	}

	gotFin := false
	if flags&tcpFlagFIN != 0 && seq+uint32(len(payload)) == f.rcvNxt {
		f.rcvNxt++
		f.guestFin = true
		gotFin = true
		sendAck = true
	}

	curSeq := f.sndNxt
	curAck := f.rcvNxt
	conn := f.conn
	bothDone := f.guestFin && f.hostFin && len(f.unacked) == 0
	f.mu.Unlock()

	if len(toWrite) > 0 && conn != nil {
		_ = conn.SetWriteDeadline(time.Now().Add(2 * time.Second))
		if _, err := conn.Write(toWrite); err != nil {
			p.closeTCPFlow(f, true)
			return
		}
		atomic.AddUint64(&p.stats.TCPGuestToHost, uint64(len(toWrite)))
	}
	if sendAck {
		p.enqueue(p.buildTCPEtherFrame(guestMAC, dstIP, srcIP, dstPort, srcPort, curSeq, curAck, tcpFlagACK, 65535, nil, nil))
	}
	if gotFin && conn != nil {
		if tc, ok := conn.(*net.TCPConn); ok {
			_ = tc.CloseWrite()
		}
	}
	if bothDone {
		p.closeTCPFlow(f, false)
	}
}

func (p *proxyState) handleFrame(frame []byte) {
	if len(frame) < 14 {
		return
	}
	atomic.AddUint64(&p.stats.RxFrames, 1)
	ethType := binary.BigEndian.Uint16(frame[12:14])
	switch ethType {
	case 0x0806:
		p.handleARP(frame)
	case 0x0800:
		if len(frame) < 34 {
			return
		}
		ip := frame[14:]
		if ip[0]>>4 != 4 {
			return
		}
		ihl := int(ip[0]&0x0f) * 4
		totLen := int(binary.BigEndian.Uint16(ip[2:4]))
		if ihl < 20 || totLen < ihl || 14+totLen > len(frame) {
			return
		}
		var srcIP, dstIP [4]byte
		copy(srcIP[:], ip[12:16])
		copy(dstIP[:], ip[16:20])
		var guestMAC [6]byte
		copy(guestMAC[:], frame[6:12])
		switch ip[9] {
		case 1:
			p.handleICMP(frame[:14+totLen], ihl)
		case 6:
			p.handleTCP(guestMAC, srcIP, dstIP, frame[14+ihl:14+totLen])
		case 17:
			p.handleUDP(guestMAC, srcIP, dstIP, frame[14+ihl:14+totLen])
		}
	}
}

func serveConn(conn net.Conn, qosOK bool, statsPath string) {
	defer conn.Close()
	if tc, ok := conn.(*net.TCPConn); ok {
		_ = tc.SetNoDelay(true)
		_ = tc.SetReadBuffer(4 * 1024 * 1024)
		_ = tc.SetWriteBuffer(4 * 1024 * 1024)
	}
	st := &proxyState{
		txCh:     make(chan []byte, 8192),
		udpFlows: make(map[flowKey]*udpFlow),
		tcpFlows: make(map[flowKey]*tcpFlow),
		stats:    proxyStats{QoSInteractive: qosOK},
	}
	writeStats := func() {
		if statsPath == "" {
			return
		}
		snap := proxyStats{
			QoSInteractive: st.stats.QoSInteractive,
			RxFrames:       atomic.LoadUint64(&st.stats.RxFrames),
			TxFrames:       atomic.LoadUint64(&st.stats.TxFrames),
			UDPFwd:         atomic.LoadUint64(&st.stats.UDPFwd),
			UDPRet:         atomic.LoadUint64(&st.stats.UDPRet),
			ICMPEcho:       atomic.LoadUint64(&st.stats.ICMPEcho),
			TCPSyn:         atomic.LoadUint64(&st.stats.TCPSyn),
			TCPEstablished: atomic.LoadUint64(&st.stats.TCPEstablished),
			TCPGuestToHost: atomic.LoadUint64(&st.stats.TCPGuestToHost),
			TCPHostToGuest: atomic.LoadUint64(&st.stats.TCPHostToGuest),
			TCPRetransmits: atomic.LoadUint64(&st.stats.TCPRetransmits),
		}
		if raw, err := json.Marshal(snap); err == nil {
			_ = os.WriteFile(statsPath, raw, 0644)
		}
	}
	defer func() {
		writeStats()
		atomic.StoreInt32(&st.closed, 1)
		close(st.txCh)
		st.mu.Lock()
		for _, f := range st.udpFlows {
			_ = f.conn.Close()
		}
		for _, f := range st.tcpFlows {
			if f.conn != nil {
				_ = f.conn.Close()
			}
		}
		st.udpFlows = nil
		st.tcpFlows = nil
		st.mu.Unlock()
	}()

	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		runtime.LockOSThread()
		C.set_user_interactive_qos()
		var hdr [4]byte
		for frame := range st.txCh {
			binary.BigEndian.PutUint32(hdr[:], uint32(len(frame)))
			bufs := net.Buffers{hdr[:], frame}
			if _, err := bufs.WriteTo(conn); err != nil {
				return
			}
		}
	}()

	stopStats := make(chan struct{})
	if statsPath != "" {
		go func() {
			t := time.NewTicker(3 * time.Second)
			defer t.Stop()
			for {
				select {
				case <-t.C:
					writeStats()
				case <-stopStats:
					return
				}
			}
		}()
	}
	defer close(stopStats)

	runtime.LockOSThread()
	C.set_user_interactive_qos()
	var hdr [4]byte
	for {
		if _, err := io.ReadFull(conn, hdr[:]); err != nil {
			break
		}
		n := binary.BigEndian.Uint32(hdr[:])
		if n == 0 || n > 65536 {
			break
		}
		buf := make([]byte, n)
		if _, err := io.ReadFull(conn, buf); err != nil {
			break
		}
		st.handleFrame(buf)
	}
	wg.Wait()
}

func main() {
	listenAddr := flag.String("listen", "127.0.0.1:0", "Listen address (unix:///path or host:port) for QEMU -netdev stream")
	socketPath := flag.String("socket", "", "Optional Unix domain socket path shorthand (overrides -listen)")
	statsFile := flag.String("stats-file", "", "Optional JSON stats output file on disconnect")
	selfCheck := flag.Bool("self-check", false, "Verify USER_INTERACTIVE QoS and print JSON diagnostics")
	flag.Parse()

	qosOK := (C.set_user_interactive_qos() == 0)
	if *selfCheck {
		payload := map[string]any{
			"passed":             qosOK,
			"qosUserInteractive": qosOK,
			"zeroPrivilege":      true,
			"transports":         []string{"unix", "tcp4"},
			"protocols":          []string{"tcp", "udp", "icmp", "arp", "dhcp", "dns"},
		}
		raw, _ := json.Marshal(payload)
		fmt.Println(string(raw))
		if !qosOK {
			os.Exit(1)
		}
		os.Exit(0)
	}

	rawListen := strings.TrimSpace(*listenAddr)
	if strings.TrimSpace(*socketPath) != "" {
		rawListen = "unix://" + strings.TrimSpace(*socketPath)
	}

	var (
		ln        net.Listener
		err       error
		unixClean string
		endpoint  string
	)
	if strings.HasPrefix(rawListen, "unix://") || strings.HasPrefix(rawListen, "/") {
		sock := strings.TrimPrefix(rawListen, "unix://")
		if err = os.MkdirAll(filepath.Dir(sock), 0700); err != nil {
			fmt.Fprintf(os.Stderr, "mkdir failed: %v\n", err)
			os.Exit(1)
		}
		if fi, statErr := os.Lstat(sock); statErr == nil && (fi.Mode()&os.ModeSocket != 0) {
			_ = os.Remove(sock)
		}
		ln, err = net.Listen("unix", sock)
		if err != nil {
			fmt.Fprintf(os.Stderr, "unix listen failed: %v\n", err)
			os.Exit(1)
		}
		if err = os.Chmod(sock, 0600); err != nil {
			_ = ln.Close()
			_ = os.Remove(sock)
			fmt.Fprintf(os.Stderr, "chmod 0600 failed: %v\n", err)
			os.Exit(1)
		}
		unixClean = sock
		endpoint = "unix://" + sock
	} else {
		ln, err = net.Listen("tcp4", rawListen)
		if err != nil {
			fmt.Fprintf(os.Stderr, "listen failed: %v\n", err)
			os.Exit(1)
		}
		endpoint = ln.Addr().String()
	}
	cleanup := func() {
		_ = ln.Close()
		if unixClean != "" {
			_ = os.Remove(unixClean)
		}
	}
	defer cleanup()
	fmt.Printf("READY %s QOS_INTERACTIVE=%v\n", endpoint, qosOK)
	_ = os.Stdout.Sync()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigCh
		cleanup()
		os.Exit(0)
	}()

	for {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		if uc, ok := conn.(*net.UnixConn); ok {
			_ = uc.SetReadBuffer(4 * 1024 * 1024)
			_ = uc.SetWriteBuffer(4 * 1024 * 1024)
		}
		go serveConn(conn, qosOK, *statsFile)
	}
}
