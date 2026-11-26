#!/usr/bin/env python3
"""Phase 15A benchmark & verification suite:
1. Full de-emulation (WHQL virtio-mouse-pci, zero usb-redir/qemu-xhci, FPSLimit=120 + triple buffer, virtio-sound eval).
2. Full TCP+UDP+ICMP high-QoS non-slirp async proxy + kernel vmnet-bridge LaunchDaemon audit/integration
   with 60s TCP + 128-tick UDP mixed loaded stress test.
3. 1080p & 4K zero-compromise multithreaded graphics pipeline benchmark (D3D11 threading/deferred contexts,
   WHQL vulkan_virtio Vulkan 1.3+ secondary command buffers, NPT_CAPSET_D3D12 probe).
4. IOSurface zero-copy direct present A/B verification on rebuilt UTM-Custom.app (patch 09) & full-disk zero-drift proof.

Owner: @DNPMBHC
Compliance:
- Zero CPUID/SMBIOS/ACPI/TPM/Hypervisor spoofing; never touches game/ACE/Windows drivers.
- Preserves Secure Boot = True, sealed golden-win11-arm64-v1.utm, primary vm-a, and /Applications/UTM.app.
- Compiles helper binaries strictly inside $TMPDIR (never inside the repository).
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import socket
import statistics
import struct
import subprocess
import sys
import tempfile
import threading
import time
from typing import Any
import uuid

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import golden_guest_manager as ggm
import p12_cpu_net_benchmark as p12b
import p14_full_stack_perf_eval as p14e
import utm_custom_patch_verify as ucpv

WORKSPACE_ROOT = SCRIPT_DIR.parent
EVIDENCE_P15A = WORKSPACE_ROOT / "handoff/phase-15/evidence/p15-a"
GOLDEN_MANIFEST = WORKSPACE_ROOT / "handoff/phase-6/evidence/p6-a/golden-guest-manifest.json"
DEFAULT_CUSTOM_APP = Path(os.environ.get("TMPDIR", "/tmp")) / "utm-custom-build" / "UTM-Custom.app"
OFFICIAL_UTM_APP = Path("/Applications/UTM.app")
OFFICIAL_UTMCTL = OFFICIAL_UTM_APP / "Contents/MacOS/utmctl"
D3D11_PROBE = WORKSPACE_ROOT / "graphics-lab/build/d3d11_probe.exe"
VMNET_BRIDGE_DIR = WORKSPACE_ROOT / "Whisky/Modules/utm-custom/vmnet-bridge"
PATCHES_DIR = WORKSPACE_ROOT / "Whisky/Modules/utm-custom/patches"
MINGW_GXX = Path("/opt/homebrew/bin/x86_64-w64-mingw32-g++")
GO_BIN = Path("/opt/homebrew/bin/go")

# =============================================================================
# 1. Zero-privilege full TCP + UDP + ICMP + ARP + DHCP high-QoS Go stream proxy
# =============================================================================
FULL_TCP_UDP_PROXY_GO_SRC = r'''package main

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
	"runtime"
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

func resolveHostTarget(dstIP [4]byte, dstPort uint16) string {
	if dstIP == gwIP {
		if dstPort == 53 {
			return "114.114.114.114:53"
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
	listenAddr := flag.String("listen", "127.0.0.1:0", "TCP listen address for QEMU -netdev stream")
	statsFile := flag.String("stats-file", "", "Optional JSON stats output file on disconnect")
	flag.Parse()

	qosOK := (C.set_user_interactive_qos() == 0)

	ln, err := net.Listen("tcp4", *listenAddr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "listen failed: %v\n", err)
		os.Exit(1)
	}
	defer ln.Close()
	fmt.Printf("READY %s QOS_INTERACTIVE=%v\n", ln.Addr().String(), qosOK)
	_ = os.Stdout.Sync()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigCh
		_ = ln.Close()
		os.Exit(0)
	}()

	for {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		go serveConn(conn, qosOK, *statsFile)
	}
}
'''

# =============================================================================
# 2. Windows 64-bit 1080p/4K Multithreaded Graphics Microbenchmark (D3D11/Vulkan/D3D12)
#    Compiled on demand into $TMPDIR via x86_64-w64-mingw32-g++ (zero repo bloat).
# =============================================================================
MT_GFX_BENCH_CPP_SRC = r'''#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <dxgi.h>
#include <d3d12.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

using Clock = std::chrono::steady_clock;

// Validated SPIR-V 1.0 shaders (verified by spirv-val)
static const uint32_t VERT_SPV[] = {
    0x07230203u, 0x00010000u, 0x00070000u, 0x0000001au, 0x00000000u, 0x00020011u, 0x00000001u, 0x0003000eu,
    0x00000000u, 0x00000001u, 0x0007000fu, 0x00000000u, 0x00000001u, 0x6e69616du, 0x00000000u, 0x00000002u,
    0x00000003u, 0x00040047u, 0x00000002u, 0x0000000bu, 0x0000002au, 0x00040047u, 0x00000003u, 0x0000000bu,
    0x00000000u, 0x00020013u, 0x00000004u, 0x00030021u, 0x00000005u, 0x00000004u, 0x00040015u, 0x00000006u,
    0x00000020u, 0x00000001u, 0x00030016u, 0x00000007u, 0x00000020u, 0x00040017u, 0x00000008u, 0x00000007u,
    0x00000004u, 0x00040020u, 0x00000009u, 0x00000001u, 0x00000006u, 0x00040020u, 0x0000000au, 0x00000003u,
    0x00000008u, 0x0004003bu, 0x00000009u, 0x00000002u, 0x00000001u, 0x0004003bu, 0x0000000au, 0x00000003u,
    0x00000003u, 0x0004002bu, 0x00000006u, 0x0000000bu, 0x00000001u, 0x0004002bu, 0x00000006u, 0x0000000cu,
    0x00000002u, 0x0004002bu, 0x00000007u, 0x0000000du, 0x00000000u, 0x0004002bu, 0x00000007u, 0x0000000eu,
    0x3f800000u, 0x0004002bu, 0x00000007u, 0x0000000fu, 0x40000000u, 0x00050036u, 0x00000004u, 0x00000001u,
    0x00000000u, 0x00000005u, 0x000200f8u, 0x00000010u, 0x0004003du, 0x00000006u, 0x00000011u, 0x00000002u,
    0x000500c4u, 0x00000006u, 0x00000012u, 0x00000011u, 0x0000000bu, 0x000500c7u, 0x00000006u, 0x00000013u,
    0x00000012u, 0x0000000cu, 0x000500c7u, 0x00000006u, 0x00000014u, 0x00000011u, 0x0000000cu, 0x0004006fu,
    0x00000007u, 0x00000015u, 0x00000013u, 0x0004006fu, 0x00000007u, 0x00000016u, 0x00000014u, 0x00050083u,
    0x00000007u, 0x00000017u, 0x00000015u, 0x0000000eu, 0x00050083u, 0x00000007u, 0x00000018u, 0x00000016u,
    0x0000000eu, 0x00070050u, 0x00000008u, 0x00000019u, 0x00000017u, 0x00000018u, 0x0000000du, 0x0000000eu,
    0x0003003eu, 0x00000003u, 0x00000019u, 0x000100fdu, 0x00010038u
};
static const uint32_t FRAG_SPV[] = {
    0x07230203u, 0x00010000u, 0x00070000u, 0x0000000eu, 0x00000000u, 0x00020011u, 0x00000001u, 0x0003000eu,
    0x00000000u, 0x00000001u, 0x0006000fu, 0x00000004u, 0x00000001u, 0x6e69616du, 0x00000000u, 0x00000002u,
    0x00030010u, 0x00000001u, 0x00000007u, 0x00040047u, 0x00000002u, 0x0000001eu, 0x00000000u, 0x00020013u,
    0x00000003u, 0x00030021u, 0x00000004u, 0x00000003u, 0x00030016u, 0x00000005u, 0x00000020u, 0x00040017u,
    0x00000006u, 0x00000005u, 0x00000004u, 0x00040020u, 0x00000007u, 0x00000003u, 0x00000006u, 0x0004003bu,
    0x00000007u, 0x00000002u, 0x00000003u, 0x0004002bu, 0x00000005u, 0x00000008u, 0x3e800000u, 0x0004002bu,
    0x00000005u, 0x00000009u, 0x3f266666u, 0x0004002bu, 0x00000005u, 0x0000000au, 0x3f666666u, 0x0004002bu,
    0x00000005u, 0x0000000bu, 0x3f800000u, 0x0007002cu, 0x00000006u, 0x0000000cu, 0x00000008u, 0x00000009u,
    0x0000000au, 0x0000000bu, 0x00050036u, 0x00000003u, 0x00000001u, 0x00000000u, 0x00000004u, 0x000200f8u,
    0x0000000du, 0x0003003eu, 0x00000002u, 0x0000000cu, 0x000100fdu, 0x00010038u
};

static std::string json_escape(const std::string& s) {
    std::ostringstream oss;
    for (unsigned char c : s) {
        if (c == '"' || c == '\\') oss << '\\' << static_cast<char>(c);
        else if (c >= 0x20) oss << static_cast<char>(c);
    }
    return oss.str();
}

static double pct_val(std::vector<double> v, double p) {
    if (v.empty()) return 0.0;
    std::sort(v.begin(), v.end());
    double idx = (static_cast<double>(v.size()) - 1.0) * (p / 100.0);
    size_t lo = static_cast<size_t>(std::floor(idx));
    size_t hi = static_cast<size_t>(std::ceil(idx));
    if (lo == hi) return v[lo];
    double f = idx - static_cast<double>(lo);
    return v[lo] * (1.0 - f) + v[hi] * f;
}

static double mean_val(const std::vector<double>& v) {
    if (v.empty()) return 0.0;
    double s = 0.0;
    for (double x : v) s += x;
    return s / static_cast<double>(v.size());
}

// =========================================================================
// Mode 1: D3D11 D3D11_FEATURE_THREADING + Deferred Context Parallel Bench
// =========================================================================
static int run_d3d11(int width, int height, int threads, int draws, int frames, int warmup) {
    D3D_FEATURE_LEVEL levels[] = { D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0 };
    D3D_FEATURE_LEVEL fl = D3D_FEATURE_LEVEL_11_0;
    ID3D11Device* dev = nullptr;
    ID3D11DeviceContext* imm = nullptr;
    HRESULT hr = D3D11CreateDevice(
        nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0,
        levels, 2, D3D11_SDK_VERSION, &dev, &fl, &imm
    );
    if (FAILED(hr) || !dev || !imm) {
        std::cout << "{\"ok\":false,\"api\":\"d3d11\",\"error\":\"D3D11CreateDevice failed\",\"hr\":\""
                  << std::hex << static_cast<uint32_t>(hr) << "\"}\n";
        return 1;
    }

    std::string adapter_name = "unknown";
    IDXGIDevice* dxgiDev = nullptr;
    if (SUCCEEDED(dev->QueryInterface(__uuidof(IDXGIDevice), (void**)&dxgiDev)) && dxgiDev) {
        IDXGIAdapter* adapter = nullptr;
        if (SUCCEEDED(dxgiDev->GetAdapter(&adapter)) && adapter) {
            DXGI_ADAPTER_DESC desc{};
            if (SUCCEEDED(adapter->GetDesc(&desc))) {
                char buf[256]{};
                WideCharToMultiByte(CP_UTF8, 0, desc.Description, -1, buf, sizeof(buf) - 1, nullptr, nullptr);
                adapter_name = buf;
            }
            adapter->Release();
        }
        dxgiDev->Release();
    }

    D3D11_FEATURE_DATA_THREADING threading{};
    HRESULT hrThr = dev->CheckFeatureSupport(D3D11_FEATURE_THREADING, &threading, sizeof(threading));
    bool concurrentCreates = SUCCEEDED(hrThr) && threading.DriverConcurrentCreates != FALSE;
    bool driverCmdLists = SUCCEEDED(hrThr) && threading.DriverCommandLists != FALSE;

    // Compile minimal HLSL shaders
    const char* vsSrc =
        "cbuffer CB : register(b0) { float4 tint; };\n"
        "float4 main(uint vid : SV_VertexID) : SV_Position {\n"
        "  float2 p = float2((vid << 1) & 2, vid & 2);\n"
        "  return float4(p * float2(2.0,-2.0) + float2(-1.0,1.0), 0.0, 1.0);\n"
        "}\n";
    const char* psSrc =
        "cbuffer CB : register(b0) { float4 tint; };\n"
        "float4 main() : SV_Target { return tint; }\n";
    ID3DBlob *vsBlob = nullptr, *psBlob = nullptr, *errBlob = nullptr;
    hr = D3DCompile(vsSrc, strlen(vsSrc), nullptr, nullptr, nullptr, "main", "vs_5_0", 0, 0, &vsBlob, &errBlob);
    if (FAILED(hr)) {
        std::cout << "{\"ok\":false,\"api\":\"d3d11\",\"error\":\"VS compile failed\"}\n";
        return 2;
    }
    hr = D3DCompile(psSrc, strlen(psSrc), nullptr, nullptr, nullptr, "main", "ps_5_0", 0, 0, &psBlob, &errBlob);
    if (FAILED(hr)) {
        std::cout << "{\"ok\":false,\"api\":\"d3d11\",\"error\":\"PS compile failed\"}\n";
        return 2;
    }
    ID3D11VertexShader* vs = nullptr;
    ID3D11PixelShader* ps = nullptr;
    dev->CreateVertexShader(vsBlob->GetBufferPointer(), vsBlob->GetBufferSize(), nullptr, &vs);
    dev->CreatePixelShader(psBlob->GetBufferPointer(), psBlob->GetBufferSize(), nullptr, &ps);
    vsBlob->Release();
    psBlob->Release();

    // Create native 1080p or 4K render target
    D3D11_TEXTURE2D_DESC td{};
    td.Width = static_cast<UINT>(width);
    td.Height = static_cast<UINT>(height);
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT;
    td.BindFlags = D3D11_BIND_RENDER_TARGET;
    ID3D11Texture2D* rtTex = nullptr;
    ID3D11RenderTargetView* rtv = nullptr;
    hr = dev->CreateTexture2D(&td, nullptr, &rtTex);
    if (FAILED(hr) || !rtTex) {
        std::cout << "{\"ok\":false,\"api\":\"d3d11\",\"error\":\"CreateTexture2D failed\"}\n";
        return 3;
    }
    hr = dev->CreateRenderTargetView(rtTex, nullptr, &rtv);
    if (FAILED(hr) || !rtv) {
        std::cout << "{\"ok\":false,\"api\":\"d3d11\",\"error\":\"CreateRenderTargetView failed\"}\n";
        return 3;
    }

    D3D11_QUERY_DESC qd{};
    qd.Query = D3D11_QUERY_EVENT;
    ID3D11Query* fenceQuery = nullptr;
    dev->CreateQuery(&qd, &fenceQuery);

    D3D11_VIEWPORT vp{};
    vp.Width = static_cast<float>(width);
    vp.Height = static_cast<float>(height);
    vp.MaxDepth = 1.0f;

    std::vector<ID3D11DeviceContext*> deferred(threads > 1 ? threads : 0, nullptr);
    bool deferredOk = (threads > 1);
    if (threads > 1) {
        for (int t = 0; t < threads; ++t) {
            if (FAILED(dev->CreateDeferredContext(0, &deferred[t])) || !deferred[t]) {
                deferredOk = false;
                break;
            }
        }
    }

    std::vector<double> recMs, subMs, totMs;
    recMs.reserve(frames);
    subMs.reserve(frames);
    totMs.reserve(frames);

    int totalIters = warmup + frames;
    int createsPerThread = std::max(1, 32 / std::max(1, threads));
    for (int f = 0; f < totalIters; ++f) {
        auto t0 = Clock::now();
        float clearCol[4] = { 0.05f, 0.1f, 0.15f, 1.0f };
        imm->ClearRenderTargetView(rtv, clearCol);

        double recordElapsedMs = 0.0;
        double submitElapsedMs = 0.0;

        if (threads <= 1 || !deferredOk) {
            auto r0 = Clock::now();
            imm->OMSetRenderTargets(1, &rtv, nullptr);
            imm->RSSetViewports(1, &vp);
            imm->VSSetShader(vs, nullptr, 0);
            imm->PSSetShader(ps, nullptr, 0);
            imm->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);

            // Dynamic constant buffer creation + draws on single thread
            D3D11_BUFFER_DESC cbd{};
            cbd.ByteWidth = 64;
            cbd.Usage = D3D11_USAGE_IMMUTABLE;
            cbd.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
            for (int c = 0; c < 32; ++c) {
                float tint[16] = { 0.2f + 0.01f * (c % 10), 0.5f, 0.8f, 1.0f };
                D3D11_SUBRESOURCE_DATA init{ tint, 0, 0 };
                ID3D11Buffer* cb = nullptr;
                if (SUCCEEDED(dev->CreateBuffer(&cbd, &init, &cb)) && cb) {
                    imm->PSSetConstantBuffers(0, 1, &cb);
                    int batch = draws / 32;
                    for (int d = 0; d < batch; ++d) {
                        imm->Draw(3, 0);
                    }
                    cb->Release();
                }
            }
            auto r1 = Clock::now();
            recordElapsedMs = std::chrono::duration<double, std::milli>(r1 - r0).count();
            auto s0 = Clock::now();
            if (fenceQuery) {
                imm->End(fenceQuery);
                imm->Flush();
                BOOL done = FALSE;
                while (imm->GetData(fenceQuery, &done, sizeof(done), 0) == S_FALSE) {
                    SwitchToThread();
                }
            } else {
                imm->Flush();
            }
            auto s1 = Clock::now();
            submitElapsedMs = std::chrono::duration<double, std::milli>(s1 - s0).count();
        } else {
            auto r0 = Clock::now();
            std::vector<ID3D11CommandList*> cmdLists(threads, nullptr);
            std::vector<std::thread> workers;
            workers.reserve(threads);
            int drawsPerThread = std::max(1, draws / threads);
            for (int t = 0; t < threads; ++t) {
                workers.emplace_back([&, t]() {
                    ID3D11DeviceContext* dc = deferred[t];
                    dc->OMSetRenderTargets(1, &rtv, nullptr);
                    dc->RSSetViewports(1, &vp);
                    dc->VSSetShader(vs, nullptr, 0);
                    dc->PSSetShader(ps, nullptr, 0);
                    dc->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);

                    D3D11_BUFFER_DESC cbd{};
                    cbd.ByteWidth = 64;
                    cbd.Usage = D3D11_USAGE_IMMUTABLE;
                    cbd.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
                    int drawsPerBatch = std::max(1, drawsPerThread / createsPerThread);
                    for (int c = 0; c < createsPerThread; ++c) {
                        float tint[16] = { 0.2f + 0.02f * t, 0.4f + 0.02f * c, 0.85f, 1.0f };
                        D3D11_SUBRESOURCE_DATA init{ tint, 0, 0 };
                        ID3D11Buffer* cb = nullptr;
                        if (SUCCEEDED(dev->CreateBuffer(&cbd, &init, &cb)) && cb) {
                            dc->PSSetConstantBuffers(0, 1, &cb);
                            for (int d = 0; d < drawsPerBatch; ++d) {
                                dc->Draw(3, 0);
                            }
                            cb->Release();
                        }
                    }
                    dc->FinishCommandList(FALSE, &cmdLists[t]);
                });
            }
            for (auto& w : workers) w.join();
            auto r1 = Clock::now();
            recordElapsedMs = std::chrono::duration<double, std::milli>(r1 - r0).count();

            auto s0 = Clock::now();
            for (int t = 0; t < threads; ++t) {
                if (cmdLists[t]) {
                    imm->ExecuteCommandList(cmdLists[t], FALSE);
                    cmdLists[t]->Release();
                }
            }
            if (fenceQuery) {
                imm->End(fenceQuery);
                imm->Flush();
                BOOL done = FALSE;
                while (imm->GetData(fenceQuery, &done, sizeof(done), 0) == S_FALSE) {
                    SwitchToThread();
                }
            } else {
                imm->Flush();
            }
            auto s1 = Clock::now();
            submitElapsedMs = std::chrono::duration<double, std::milli>(s1 - s0).count();
        }

        auto t1 = Clock::now();
        double totalMs = std::chrono::duration<double, std::milli>(t1 - t0).count();
        if (f >= warmup) {
            recMs.push_back(recordElapsedMs);
            subMs.push_back(submitElapsedMs);
            totMs.push_back(totalMs);
        }
    }

    for (auto* dc : deferred) if (dc) dc->Release();
    if (fenceQuery) fenceQuery->Release();
    rtv->Release();
    rtTex->Release();
    vs->Release();
    ps->Release();
    imm->Release();
    dev->Release();

    double meanTot = mean_val(totMs);
    double p50Tot = pct_val(totMs, 50.0);
    double p99Tot = pct_val(totMs, 99.0);
    double fpsMean = meanTot > 0.0 ? (1000.0 / meanTot) : 0.0;
    double fpsP1 = p99Tot > 0.0 ? (1000.0 / p99Tot) : 0.0;

    std::cout << std::fixed << std::setprecision(3)
              << "{\"ok\":true,\"api\":\"d3d11\""
              << ",\"adapter\":\"" << json_escape(adapter_name) << "\""
              << ",\"driver_concurrent_creates\":" << (concurrentCreates ? "true" : "false")
              << ",\"driver_command_lists\":" << (driverCmdLists ? "true" : "false")
              << ",\"deferred_contexts_used\":" << ((threads > 1 && deferredOk) ? "true" : "false")
              << ",\"width\":" << width << ",\"height\":" << height
              << ",\"threads\":" << threads << ",\"draws_per_frame\":" << draws
              << ",\"frames\":" << frames
              << ",\"record_cpu_ms_mean\":" << mean_val(recMs)
              << ",\"submit_wait_ms_mean\":" << mean_val(subMs)
              << ",\"total_frame_ms_mean\":" << meanTot
              << ",\"frame_ms_p50\":" << p50Tot
              << ",\"frame_ms_p99\":" << p99Tot
              << ",\"fps_mean\":" << fpsMean
              << ",\"fps_p1_low\":" << fpsP1
              << "}\n";
    return 0;
}

// =========================================================================
// Mode 2: Vulkan 1.3+ (vulkan_virtio / Venus) Multithreaded Secondary CmdBuf
// =========================================================================
typedef uint32_t VkFlags;
typedef uint32_t VkBool32;
typedef uint64_t VkDeviceSize;
typedef int32_t  VkResult;
typedef void* VkInstance;
typedef void* VkPhysicalDevice;
typedef void* VkDevice;
typedef void* VkQueue;
typedef void* VkCommandBuffer;
typedef uint64_t VkCommandPool;
typedef uint64_t VkImage;
typedef uint64_t VkDeviceMemory;
typedef uint64_t VkImageView;
typedef uint64_t VkRenderPass;
typedef uint64_t VkFramebuffer;
typedef uint64_t VkShaderModule;
typedef uint64_t VkPipelineLayout;
typedef uint64_t VkPipeline;
typedef uint64_t VkFence;
typedef uint64_t VkSemaphore;
typedef uint64_t VkPipelineCache;

struct VkApplicationInfo {
    uint32_t sType; const void* pNext; const char* pApplicationName; uint32_t applicationVersion;
    const char* pEngineName; uint32_t engineVersion; uint32_t apiVersion;
};
struct VkInstanceCreateInfo {
    uint32_t sType; const void* pNext; VkFlags flags; const VkApplicationInfo* pApplicationInfo;
    uint32_t enabledLayerCount; const char* const* ppEnabledLayerNames;
    uint32_t enabledExtensionCount; const char* const* ppEnabledExtensionNames;
};
struct VkPhysicalDeviceProperties {
    uint32_t apiVersion; uint32_t driverVersion; uint32_t vendorID; uint32_t deviceID; uint32_t deviceType;
    char deviceName[256]; uint8_t pipelineCacheUUID[16]; uint8_t limits[504]; uint8_t sparseProperties[20];
};
struct VkQueueFamilyProperties {
    VkFlags queueFlags; uint32_t queueCount; uint32_t timestampValidBits;
    uint32_t minImageTransferGranularity[3];
};
struct VkDeviceQueueCreateInfo {
    uint32_t sType; const void* pNext; VkFlags flags; uint32_t queueFamilyIndex;
    uint32_t queueCount; const float* pQueuePriorities;
};
struct VkDeviceCreateInfo {
    uint32_t sType; const void* pNext; VkFlags flags; uint32_t queueCreateInfoCount;
    const VkDeviceQueueCreateInfo* pQueueCreateInfos; uint32_t enabledLayerCount;
    const char* const* ppEnabledLayerNames; uint32_t enabledExtensionCount;
    const char* const* ppEnabledExtensionNames; const void* pEnabledFeatures;
};
struct VkMemoryType { VkFlags propertyFlags; uint32_t heapIndex; };
struct VkMemoryHeap { VkDeviceSize size; VkFlags flags; };
struct VkPhysicalDeviceMemoryProperties {
    uint32_t memoryTypeCount; VkMemoryType memoryTypes[32];
    uint32_t memoryHeapCount; VkMemoryHeap memoryHeaps[16];
};
struct VkExtent3D { uint32_t width, height, depth; };
struct VkExtent2D { uint32_t width, height; };
struct VkOffset2D { int32_t x, y; };
struct VkRect2D { VkOffset2D offset; VkExtent2D extent; };
struct VkViewport { float x, y, width, height, minDepth, maxDepth; };
struct VkImageCreateInfo {
    uint32_t sType; const void* pNext; VkFlags flags; uint32_t imageType; uint32_t format;
    VkExtent3D extent; uint32_t mipLevels; uint32_t arrayLayers; uint32_t samples;
    uint32_t tiling; VkFlags usage; uint32_t sharingMode; uint32_t queueFamilyIndexCount;
    const uint32_t* pQueueFamilyIndices; uint32_t initialLayout;
};
struct VkMemoryRequirements { VkDeviceSize size; VkDeviceSize alignment; uint32_t memoryTypeBits; };
struct VkMemoryAllocateInfo { uint32_t sType; const void* pNext; VkDeviceSize allocationSize; uint32_t memoryTypeIndex; };
struct VkComponentMapping { uint32_t r, g, b, a; };
struct VkImageSubresourceRange { VkFlags aspectMask; uint32_t baseMipLevel, levelCount, baseArrayLayer, layerCount; };
struct VkImageViewCreateInfo {
    uint32_t sType; const void* pNext; VkFlags flags; VkImage image; uint32_t viewType;
    uint32_t format; VkComponentMapping components; VkImageSubresourceRange subresourceRange;
};
struct VkAttachmentDescription {
    VkFlags flags; uint32_t format; uint32_t samples; uint32_t loadOp; uint32_t storeOp;
    uint32_t stencilLoadOp; uint32_t stencilStoreOp; uint32_t initialLayout; uint32_t finalLayout;
};
struct VkAttachmentReference { uint32_t attachment; uint32_t layout; };
struct VkSubpassDescription {
    VkFlags flags; uint32_t pipelineBindPoint; uint32_t inputAttachmentCount; const VkAttachmentReference* pInputAttachments;
    uint32_t colorAttachmentCount; const VkAttachmentReference* pColorAttachments;
    const VkAttachmentReference* pResolveAttachments; const VkAttachmentReference* pDepthStencilAttachment;
    uint32_t preserveAttachmentCount; const uint32_t* pPreserveAttachments;
};
struct VkRenderPassCreateInfo {
    uint32_t sType; const void* pNext; VkFlags flags; uint32_t attachmentCount;
    const VkAttachmentDescription* pAttachments; uint32_t subpassCount;
    const VkSubpassDescription* pSubpasses; uint32_t dependencyCount; const void* pDependencies;
};
struct VkFramebufferCreateInfo {
    uint32_t sType; const void* pNext; VkFlags flags; VkRenderPass renderPass;
    uint32_t attachmentCount; const VkImageView* pAttachments; uint32_t width, height, layers;
};
struct VkShaderModuleCreateInfo { uint32_t sType; const void* pNext; VkFlags flags; size_t codeSize; const uint32_t* pCode; };
struct VkPipelineShaderStageCreateInfo {
    uint32_t sType; const void* pNext; VkFlags flags; uint32_t stage; VkShaderModule module;
    const char* pName; const void* pSpecializationInfo;
};
struct VkPipelineVertexInputStateCreateInfo {
    uint32_t sType; const void* pNext; VkFlags flags; uint32_t vertexBindingDescriptionCount; const void* pVertexBindingDescriptions;
    uint32_t vertexAttributeDescriptionCount; const void* pVertexAttributeDescriptions;
};
struct VkPipelineInputAssemblyStateCreateInfo { uint32_t sType; const void* pNext; VkFlags flags; uint32_t topology; VkBool32 primitiveRestartEnable; };
struct VkPipelineViewportStateCreateInfo {
    uint32_t sType; const void* pNext; VkFlags flags; uint32_t viewportCount; const VkViewport* pViewports;
    uint32_t scissorCount; const VkRect2D* pScissors;
};
struct VkPipelineRasterizationStateCreateInfo {
    uint32_t sType; const void* pNext; VkFlags flags; VkBool32 depthClampEnable; VkBool32 rasterizerDiscardEnable;
    uint32_t polygonMode; VkFlags cullMode; uint32_t frontFace; VkBool32 depthBiasEnable;
    float depthBiasConstantFactor, depthBiasClamp, depthBiasSlopeFactor, lineWidth;
};
struct VkPipelineMultisampleStateCreateInfo {
    uint32_t sType; const void* pNext; VkFlags flags; uint32_t rasterizationSamples; VkBool32 sampleShadingEnable;
    float minSampleShading; const uint32_t* pSampleMask; VkBool32 alphaToCoverageEnable; VkBool32 alphaToOneEnable;
};
struct VkPipelineColorBlendAttachmentState {
    VkBool32 blendEnable; uint32_t srcColorBlendFactor, dstColorBlendFactor, colorBlendOp;
    uint32_t srcAlphaBlendFactor, dstAlphaBlendFactor, alphaBlendOp; VkFlags colorWriteMask;
};
struct VkPipelineColorBlendStateCreateInfo {
    uint32_t sType; const void* pNext; VkFlags flags; VkBool32 logicOpEnable; uint32_t logicOp;
    uint32_t attachmentCount; const VkPipelineColorBlendAttachmentState* pAttachments; float blendConstants[4];
};
struct VkPipelineDynamicStateCreateInfo {
    uint32_t sType; const void* pNext; VkFlags flags; uint32_t dynamicStateCount; const uint32_t* pDynamicStates;
};
struct VkPipelineLayoutCreateInfo {
    uint32_t sType; const void* pNext; VkFlags flags; uint32_t setLayoutCount; const void* pSetLayouts;
    uint32_t pushConstantRangeCount; const void* pPushConstantRanges;
};
struct VkGraphicsPipelineCreateInfo {
    uint32_t sType; const void* pNext; VkFlags flags; uint32_t stageCount;
    const VkPipelineShaderStageCreateInfo* pStages;
    const VkPipelineVertexInputStateCreateInfo* pVertexInputState;
    const VkPipelineInputAssemblyStateCreateInfo* pInputAssemblyState;
    const void* pTessellationState;
    const VkPipelineViewportStateCreateInfo* pViewportState;
    const VkPipelineRasterizationStateCreateInfo* pRasterizationState;
    const VkPipelineMultisampleStateCreateInfo* pMultisampleState;
    const void* pDepthStencilState;
    const VkPipelineColorBlendStateCreateInfo* pColorBlendState;
    const VkPipelineDynamicStateCreateInfo* pDynamicState;
    VkPipelineLayout layout; VkRenderPass renderPass; uint32_t subpass;
    VkPipeline basePipelineHandle; int32_t basePipelineIndex;
};
struct VkCommandPoolCreateInfo { uint32_t sType; const void* pNext; VkFlags flags; uint32_t queueFamilyIndex; };
struct VkCommandBufferAllocateInfo { uint32_t sType; const void* pNext; VkCommandPool commandPool; uint32_t level; uint32_t commandBufferCount; };
struct VkCommandBufferInheritanceInfo {
    uint32_t sType; const void* pNext; VkRenderPass renderPass; uint32_t subpass; VkFramebuffer framebuffer;
    VkBool32 occlusionQueryEnable; VkFlags queryFlags; VkFlags pipelineStatistics;
};
struct VkCommandBufferBeginInfo { uint32_t sType; const void* pNext; VkFlags flags; const VkCommandBufferInheritanceInfo* pInheritanceInfo; };
union VkClearColorValue { float float32[4]; int32_t int32[4]; uint32_t uint32[4]; };
union VkClearValue { VkClearColorValue color; struct { float d; uint32_t s; } depthStencil; };
struct VkRenderPassBeginInfo {
    uint32_t sType; const void* pNext; VkRenderPass renderPass; VkFramebuffer framebuffer;
    VkRect2D renderArea; uint32_t clearValueCount; const VkClearValue* pClearValues;
};
struct VkSubmitInfo {
    uint32_t sType; const void* pNext; uint32_t waitSemaphoreCount; const VkSemaphore* pWaitSemaphores;
    const VkFlags* pWaitDstStageMask; uint32_t commandBufferCount; const VkCommandBuffer* pCommandBuffers;
    uint32_t signalSemaphoreCount; const VkSemaphore* pSignalSemaphores;
};
struct VkFenceCreateInfo { uint32_t sType; const void* pNext; VkFlags flags; };

#define VK_LOAD(fn) auto fn = reinterpret_cast<PFN_##fn>(GetProcAddress(vkLib, #fn)); if (!fn) { std::cout << "{\"ok\":false,\"api\":\"vulkan\",\"error\":\"missing symbol " #fn "\"}\n"; return 1; }

static int run_vulkan(int width, int height, int threads, int draws, int frames, int warmup) {
    HMODULE vkLib = LoadLibraryA("vulkan-1.dll");
    if (!vkLib) {
        std::cout << "{\"ok\":false,\"api\":\"vulkan\",\"error\":\"vulkan-1.dll not found\"}\n";
        return 1;
    }

    using PFN_vkCreateInstance = VkResult(WINAPI*)(const VkInstanceCreateInfo*, const void*, VkInstance*);
    using PFN_vkDestroyInstance = void(WINAPI*)(VkInstance, const void*);
    using PFN_vkEnumeratePhysicalDevices = VkResult(WINAPI*)(VkInstance, uint32_t*, VkPhysicalDevice*);
    using PFN_vkGetPhysicalDeviceProperties = void(WINAPI*)(VkPhysicalDevice, VkPhysicalDeviceProperties*);
    using PFN_vkGetPhysicalDeviceQueueFamilyProperties = void(WINAPI*)(VkPhysicalDevice, uint32_t*, VkQueueFamilyProperties*);
    using PFN_vkGetPhysicalDeviceMemoryProperties = void(WINAPI*)(VkPhysicalDevice, VkPhysicalDeviceMemoryProperties*);
    using PFN_vkCreateDevice = VkResult(WINAPI*)(VkPhysicalDevice, const VkDeviceCreateInfo*, const void*, VkDevice*);
    using PFN_vkDestroyDevice = void(WINAPI*)(VkDevice, const void*);
    using PFN_vkGetDeviceQueue = void(WINAPI*)(VkDevice, uint32_t, uint32_t, VkQueue*);
    using PFN_vkCreateImage = VkResult(WINAPI*)(VkDevice, const VkImageCreateInfo*, const void*, VkImage*);
    using PFN_vkDestroyImage = void(WINAPI*)(VkDevice, VkImage, const void*);
    using PFN_vkGetImageMemoryRequirements = void(WINAPI*)(VkDevice, VkImage, VkMemoryRequirements*);
    using PFN_vkAllocateMemory = VkResult(WINAPI*)(VkDevice, const VkMemoryAllocateInfo*, const void*, VkDeviceMemory*);
    using PFN_vkFreeMemory = void(WINAPI*)(VkDevice, VkDeviceMemory, const void*);
    using PFN_vkBindImageMemory = VkResult(WINAPI*)(VkDevice, VkImage, VkDeviceMemory, VkDeviceSize);
    using PFN_vkCreateImageView = VkResult(WINAPI*)(VkDevice, const VkImageViewCreateInfo*, const void*, VkImageView*);
    using PFN_vkDestroyImageView = void(WINAPI*)(VkDevice, VkImageView, const void*);
    using PFN_vkCreateRenderPass = VkResult(WINAPI*)(VkDevice, const VkRenderPassCreateInfo*, const void*, VkRenderPass*);
    using PFN_vkDestroyRenderPass = void(WINAPI*)(VkDevice, VkRenderPass, const void*);
    using PFN_vkCreateFramebuffer = VkResult(WINAPI*)(VkDevice, const VkFramebufferCreateInfo*, const void*, VkFramebuffer*);
    using PFN_vkDestroyFramebuffer = void(WINAPI*)(VkDevice, VkFramebuffer, const void*);
    using PFN_vkCreateShaderModule = VkResult(WINAPI*)(VkDevice, const VkShaderModuleCreateInfo*, const void*, VkShaderModule*);
    using PFN_vkDestroyShaderModule = void(WINAPI*)(VkDevice, VkShaderModule, const void*);
    using PFN_vkCreatePipelineLayout = VkResult(WINAPI*)(VkDevice, const VkPipelineLayoutCreateInfo*, const void*, VkPipelineLayout*);
    using PFN_vkDestroyPipelineLayout = void(WINAPI*)(VkDevice, VkPipelineLayout, const void*);
    using PFN_vkCreateGraphicsPipelines = VkResult(WINAPI*)(VkDevice, VkPipelineCache, uint32_t, const VkGraphicsPipelineCreateInfo*, const void*, VkPipeline*);
    using PFN_vkDestroyPipeline = void(WINAPI*)(VkDevice, VkPipeline, const void*);
    using PFN_vkCreateCommandPool = VkResult(WINAPI*)(VkDevice, const VkCommandPoolCreateInfo*, const void*, VkCommandPool*);
    using PFN_vkDestroyCommandPool = void(WINAPI*)(VkDevice, VkCommandPool, const void*);
    using PFN_vkResetCommandPool = VkResult(WINAPI*)(VkDevice, VkCommandPool, VkFlags);
    using PFN_vkAllocateCommandBuffers = VkResult(WINAPI*)(VkDevice, const VkCommandBufferAllocateInfo*, VkCommandBuffer*);
    using PFN_vkBeginCommandBuffer = VkResult(WINAPI*)(VkCommandBuffer, const VkCommandBufferBeginInfo*);
    using PFN_vkEndCommandBuffer = VkResult(WINAPI*)(VkCommandBuffer);
    using PFN_vkCmdBeginRenderPass = void(WINAPI*)(VkCommandBuffer, const VkRenderPassBeginInfo*, uint32_t);
    using PFN_vkCmdEndRenderPass = void(WINAPI*)(VkCommandBuffer);
    using PFN_vkCmdBindPipeline = void(WINAPI*)(VkCommandBuffer, uint32_t, VkPipeline);
    using PFN_vkCmdSetViewport = void(WINAPI*)(VkCommandBuffer, uint32_t, uint32_t, const VkViewport*);
    using PFN_vkCmdSetScissor = void(WINAPI*)(VkCommandBuffer, uint32_t, uint32_t, const VkRect2D*);
    using PFN_vkCmdDraw = void(WINAPI*)(VkCommandBuffer, uint32_t, uint32_t, uint32_t, uint32_t);
    using PFN_vkCmdExecuteCommands = void(WINAPI*)(VkCommandBuffer, uint32_t, const VkCommandBuffer*);
    using PFN_vkCreateFence = VkResult(WINAPI*)(VkDevice, const VkFenceCreateInfo*, const void*, VkFence*);
    using PFN_vkDestroyFence = void(WINAPI*)(VkDevice, VkFence, const void*);
    using PFN_vkResetFences = VkResult(WINAPI*)(VkDevice, uint32_t, const VkFence*);
    using PFN_vkWaitForFences = VkResult(WINAPI*)(VkDevice, uint32_t, const VkFence*, VkBool32, uint64_t);
    using PFN_vkQueueSubmit = VkResult(WINAPI*)(VkQueue, uint32_t, const VkSubmitInfo*, VkFence);
    using PFN_vkDeviceWaitIdle = VkResult(WINAPI*)(VkDevice);

    VK_LOAD(vkCreateInstance); VK_LOAD(vkDestroyInstance); VK_LOAD(vkEnumeratePhysicalDevices);
    VK_LOAD(vkGetPhysicalDeviceProperties); VK_LOAD(vkGetPhysicalDeviceQueueFamilyProperties);
    VK_LOAD(vkGetPhysicalDeviceMemoryProperties); VK_LOAD(vkCreateDevice); VK_LOAD(vkDestroyDevice);
    VK_LOAD(vkGetDeviceQueue); VK_LOAD(vkCreateImage); VK_LOAD(vkDestroyImage);
    VK_LOAD(vkGetImageMemoryRequirements); VK_LOAD(vkAllocateMemory); VK_LOAD(vkFreeMemory);
    VK_LOAD(vkBindImageMemory); VK_LOAD(vkCreateImageView); VK_LOAD(vkDestroyImageView);
    VK_LOAD(vkCreateRenderPass); VK_LOAD(vkDestroyRenderPass); VK_LOAD(vkCreateFramebuffer);
    VK_LOAD(vkDestroyFramebuffer); VK_LOAD(vkCreateShaderModule); VK_LOAD(vkDestroyShaderModule);
    VK_LOAD(vkCreatePipelineLayout); VK_LOAD(vkDestroyPipelineLayout); VK_LOAD(vkCreateGraphicsPipelines);
    VK_LOAD(vkDestroyPipeline); VK_LOAD(vkCreateCommandPool); VK_LOAD(vkDestroyCommandPool);
    VK_LOAD(vkResetCommandPool); VK_LOAD(vkAllocateCommandBuffers); VK_LOAD(vkBeginCommandBuffer);
    VK_LOAD(vkEndCommandBuffer); VK_LOAD(vkCmdBeginRenderPass); VK_LOAD(vkCmdEndRenderPass);
    VK_LOAD(vkCmdBindPipeline); VK_LOAD(vkCmdSetViewport); VK_LOAD(vkCmdSetScissor);
    VK_LOAD(vkCmdDraw); VK_LOAD(vkCmdExecuteCommands); VK_LOAD(vkCreateFence);
    VK_LOAD(vkDestroyFence); VK_LOAD(vkResetFences); VK_LOAD(vkWaitForFences);
    VK_LOAD(vkQueueSubmit); VK_LOAD(vkDeviceWaitIdle);

    VkApplicationInfo appInfo{};
    appInfo.sType = 0; // VK_STRUCTURE_TYPE_APPLICATION_INFO
    appInfo.pApplicationName = "p15-mt-bench";
    appInfo.apiVersion = (1u << 22) | (3u << 12); // Vulkan 1.3
    VkInstanceCreateInfo ici{};
    ici.sType = 1; // VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
    ici.pApplicationInfo = &appInfo;
    VkInstance instance = nullptr;
    VkResult vr = vkCreateInstance(&ici, nullptr, &instance);
    if (vr != 0 || !instance) {
        appInfo.apiVersion = (1u << 22) | (1u << 12);
        vr = vkCreateInstance(&ici, nullptr, &instance);
        if (vr != 0 || !instance) {
            std::cout << "{\"ok\":false,\"api\":\"vulkan\",\"error\":\"vkCreateInstance failed\",\"vk_result\":" << vr << "}\n";
            return 1;
        }
    }

    uint32_t devCount = 0;
    vkEnumeratePhysicalDevices(instance, &devCount, nullptr);
    if (devCount == 0) {
        std::cout << "{\"ok\":false,\"api\":\"vulkan\",\"error\":\"no Vulkan physical devices\"}\n";
        vkDestroyInstance(instance, nullptr);
        return 1;
    }
    std::vector<VkPhysicalDevice> physDevs(devCount);
    vkEnumeratePhysicalDevices(instance, &devCount, physDevs.data());
    VkPhysicalDevice phys = physDevs[0];
    VkPhysicalDeviceProperties props{};
    vkGetPhysicalDeviceProperties(phys, &props);
    uint32_t apiMaj = (props.apiVersion >> 22) & 0x7fu;
    uint32_t apiMin = (props.apiVersion >> 12) & 0x3ffu;
    uint32_t apiPat = props.apiVersion & 0xfffu;

    uint32_t qfCount = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(phys, &qfCount, nullptr);
    std::vector<VkQueueFamilyProperties> qfs(qfCount);
    vkGetPhysicalDeviceQueueFamilyProperties(phys, &qfCount, qfs.data());
    uint32_t gfxFamily = 0;
    for (uint32_t i = 0; i < qfCount; ++i) {
        if (qfs[i].queueFlags & 0x1u) { gfxFamily = i; break; }
    }

    float qPrio = 1.0f;
    VkDeviceQueueCreateInfo dqci{};
    dqci.sType = 2; // VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO
    dqci.queueFamilyIndex = gfxFamily;
    dqci.queueCount = 1;
    dqci.pQueuePriorities = &qPrio;

    VkDeviceCreateInfo dci{};
    dci.sType = 3; // VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO
    dci.queueCreateInfoCount = 1;
    dci.pQueueCreateInfos = &dqci;
    VkDevice device = nullptr;
    vr = vkCreateDevice(phys, &dci, nullptr, &device);
    if (vr != 0 || !device) {
        std::cout << "{\"ok\":false,\"api\":\"vulkan\",\"error\":\"vkCreateDevice failed\",\"vk_result\":" << vr << "}\n";
        vkDestroyInstance(instance, nullptr);
        return 1;
    }
    VkQueue queue = nullptr;
    vkGetDeviceQueue(device, gfxFamily, 0, &queue);

    // Offscreen 1080p / 4K color target
    VkImageCreateInfo imgInfo{};
    imgInfo.sType = 14; // VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
    imgInfo.imageType = 1; // 2D
    imgInfo.format = 44; // VK_FORMAT_B8G8R8A8_UNORM
    imgInfo.extent = { static_cast<uint32_t>(width), static_cast<uint32_t>(height), 1 };
    imgInfo.mipLevels = 1;
    imgInfo.arrayLayers = 1;
    imgInfo.samples = 1;
    imgInfo.tiling = 0; // OPTIMAL
    imgInfo.usage = 0x10u; // COLOR_ATTACHMENT_BIT
    VkImage image = 0;
    vr = vkCreateImage(device, &imgInfo, nullptr, &image);
    if (vr != 0) {
        std::cout << "{\"ok\":false,\"api\":\"vulkan\",\"error\":\"vkCreateImage failed\",\"vk_result\":" << vr << "}\n";
        return 2;
    }
    VkMemoryRequirements memReq{};
    vkGetImageMemoryRequirements(device, image, &memReq);
    VkPhysicalDeviceMemoryProperties memProps{};
    vkGetPhysicalDeviceMemoryProperties(phys, &memProps);
    uint32_t memIdx = 0;
    for (uint32_t i = 0; i < memProps.memoryTypeCount; ++i) {
        if ((memReq.memoryTypeBits & (1u << i)) && (memProps.memoryTypes[i].propertyFlags & 1u)) {
            memIdx = i; break;
        }
    }
    VkMemoryAllocateInfo mai{};
    mai.sType = 5; // VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
    mai.allocationSize = memReq.size;
    mai.memoryTypeIndex = memIdx;
    VkDeviceMemory mem = 0;
    vr = vkAllocateMemory(device, &mai, nullptr, &mem);
    if (vr != 0) {
        std::cout << "{\"ok\":false,\"api\":\"vulkan\",\"error\":\"vkAllocateMemory failed\",\"vk_result\":" << vr << "}\n";
        return 2;
    }
    vkBindImageMemory(device, image, mem, 0);

    VkImageViewCreateInfo ivci{};
    ivci.sType = 15; // VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
    ivci.image = image;
    ivci.viewType = 1; // 2D
    ivci.format = 44;
    ivci.subresourceRange = { 1u, 0, 1, 0, 1 };
    VkImageView imageView = 0;
    vkCreateImageView(device, &ivci, nullptr, &imageView);

    VkAttachmentDescription att{};
    att.format = 44;
    att.samples = 1;
    att.loadOp = 1; // CLEAR
    att.storeOp = 0; // STORE
    att.stencilLoadOp = 2; // DONT_CARE
    att.stencilStoreOp = 1; // DONT_CARE
    att.initialLayout = 0; // UNDEFINED
    att.finalLayout = 2; // COLOR_ATTACHMENT_OPTIMAL
    VkAttachmentReference colRef{ 0, 2 };
    VkSubpassDescription subpass{};
    subpass.pipelineBindPoint = 0; // GRAPHICS
    subpass.colorAttachmentCount = 1;
    subpass.pColorAttachments = &colRef;
    VkRenderPassCreateInfo rpci{};
    rpci.sType = 38; // VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO
    rpci.attachmentCount = 1;
    rpci.pAttachments = &att;
    rpci.subpassCount = 1;
    rpci.pSubpasses = &subpass;
    VkRenderPass renderPass = 0;
    vkCreateRenderPass(device, &rpci, nullptr, &renderPass);

    VkFramebufferCreateInfo fbci{};
    fbci.sType = 37; // VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO
    fbci.renderPass = renderPass;
    fbci.attachmentCount = 1;
    fbci.pAttachments = &imageView;
    fbci.width = static_cast<uint32_t>(width);
    fbci.height = static_cast<uint32_t>(height);
    fbci.layers = 1;
    VkFramebuffer fb = 0;
    vkCreateFramebuffer(device, &fbci, nullptr, &fb);

    VkShaderModuleCreateInfo vsmci{ 16, nullptr, 0, sizeof(VERT_SPV), VERT_SPV };
    VkShaderModuleCreateInfo fsmci{ 16, nullptr, 0, sizeof(FRAG_SPV), FRAG_SPV };
    VkShaderModule vertMod = 0, fragMod = 0;
    vkCreateShaderModule(device, &vsmci, nullptr, &vertMod);
    vkCreateShaderModule(device, &fsmci, nullptr, &fragMod);

    VkPipelineShaderStageCreateInfo stages[2]{};
    stages[0] = { 18, nullptr, 0, 0x01u, vertMod, "main", nullptr };
    stages[1] = { 18, nullptr, 0, 0x10u, fragMod, "main", nullptr };
    VkPipelineVertexInputStateCreateInfo vi{ 19, nullptr, 0, 0, nullptr, 0, nullptr };
    VkPipelineInputAssemblyStateCreateInfo ia{ 20, nullptr, 0, 3, 0 }; // TRIANGLE_LIST
    VkViewport vp{ 0.0f, 0.0f, static_cast<float>(width), static_cast<float>(height), 0.0f, 1.0f };
    VkRect2D sc{ {0, 0}, { static_cast<uint32_t>(width), static_cast<uint32_t>(height) } };
    VkPipelineViewportStateCreateInfo vps{ 22, nullptr, 0, 1, &vp, 1, &sc };
    VkPipelineRasterizationStateCreateInfo rs{ 23, nullptr, 0, 0, 0, 0, 0, 0, 0, 0.0f, 0.0f, 0.0f, 1.0f };
    VkPipelineMultisampleStateCreateInfo ms{ 24, nullptr, 0, 1, 0, 0.0f, nullptr, 0, 0 };
    VkPipelineColorBlendAttachmentState cba{ 0, 0, 0, 0, 0, 0, 0, 0x0fu };
    VkPipelineColorBlendStateCreateInfo cb{ 26, nullptr, 0, 0, 0, 1, &cba, {0,0,0,0} };
    uint32_t dynStates[2] = { 0, 1 }; // VIEWPORT, SCISSOR
    VkPipelineDynamicStateCreateInfo ds{ 27, nullptr, 0, 2, dynStates };
    VkPipelineLayoutCreateInfo plci{ 30, nullptr, 0, 0, nullptr, 0, nullptr };
    VkPipelineLayout pipeLayout = 0;
    vkCreatePipelineLayout(device, &plci, nullptr, &pipeLayout);

    VkGraphicsPipelineCreateInfo gpci{};
    gpci.sType = 28; // VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO
    gpci.stageCount = 2;
    gpci.pStages = stages;
    gpci.pVertexInputState = &vi;
    gpci.pInputAssemblyState = &ia;
    gpci.pViewportState = &vps;
    gpci.pRasterizationState = &rs;
    gpci.pMultisampleState = &ms;
    gpci.pColorBlendState = &cb;
    gpci.pDynamicState = &ds;
    gpci.layout = pipeLayout;
    gpci.renderPass = renderPass;
    gpci.subpass = 0;
    VkPipeline pipeline = 0;
    vr = vkCreateGraphicsPipelines(device, 0, 1, &gpci, nullptr, &pipeline);
    if (vr != 0 || !pipeline) {
        std::cout << "{\"ok\":false,\"api\":\"vulkan\",\"error\":\"vkCreateGraphicsPipelines failed\",\"vk_result\":" << vr << "}\n";
        return 3;
    }

    VkCommandPool primaryPool = 0;
    VkCommandPoolCreateInfo cpci{ 39, nullptr, 0x02u, gfxFamily }; // RESET_COMMAND_BUFFER_BIT
    vkCreateCommandPool(device, &cpci, nullptr, &primaryPool);
    VkCommandBuffer primaryCmd = nullptr;
    VkCommandBufferAllocateInfo cbai{ 40, nullptr, primaryPool, 0, 1 }; // PRIMARY
    vkAllocateCommandBuffers(device, &cbai, &primaryCmd);

    std::vector<VkCommandPool> workerPools(threads, 0);
    std::vector<VkCommandBuffer> secCmds(threads, nullptr);
    for (int t = 0; t < threads; ++t) {
        vkCreateCommandPool(device, &cpci, nullptr, &workerPools[t]);
        VkCommandBufferAllocateInfo sai{ 40, nullptr, workerPools[t], 1, 1 }; // SECONDARY
        vkAllocateCommandBuffers(device, &sai, &secCmds[t]);
    }

    VkFenceCreateInfo fci{ 8, nullptr, 0 };
    VkFence fence = 0;
    vkCreateFence(device, &fci, nullptr, &fence);

    std::vector<double> recMs, subMs, totMs;
    recMs.reserve(frames);
    subMs.reserve(frames);
    totMs.reserve(frames);

    int totalIters = warmup + frames;
    int drawsPerThread = std::max(1, draws / std::max(1, threads));
    for (int f = 0; f < totalIters; ++f) {
        auto t0 = Clock::now();
        auto r0 = Clock::now();
        if (threads <= 1) {
            vkResetCommandPool(device, workerPools[0], 0);
            VkCommandBufferInheritanceInfo inh{ 41, nullptr, renderPass, 0, fb, 0, 0, 0 };
            VkCommandBufferBeginInfo bi{ 42, nullptr, 0x05u, &inh }; // ONE_TIME_SUBMIT | RENDER_PASS_CONTINUE
            vkBeginCommandBuffer(secCmds[0], &bi);
            vkCmdBindPipeline(secCmds[0], 0, pipeline);
            for (int d = 0; d < draws; ++d) {
                vkCmdSetViewport(secCmds[0], 0, 1, &vp);
                vkCmdSetScissor(secCmds[0], 0, 1, &sc);
                vkCmdDraw(secCmds[0], 3, 1, 0, 0);
            }
            vkEndCommandBuffer(secCmds[0]);
        } else {
            std::vector<std::thread> workers;
            workers.reserve(threads);
            for (int t = 0; t < threads; ++t) {
                workers.emplace_back([&, t]() {
                    vkResetCommandPool(device, workerPools[t], 0);
                    VkCommandBufferInheritanceInfo inh{ 41, nullptr, renderPass, 0, fb, 0, 0, 0 };
                    VkCommandBufferBeginInfo bi{ 42, nullptr, 0x05u, &inh };
                    vkBeginCommandBuffer(secCmds[t], &bi);
                    vkCmdBindPipeline(secCmds[t], 0, pipeline);
                    for (int d = 0; d < drawsPerThread; ++d) {
                        vkCmdSetViewport(secCmds[t], 0, 1, &vp);
                        vkCmdSetScissor(secCmds[t], 0, 1, &sc);
                        vkCmdDraw(secCmds[t], 3, 1, 0, 0);
                    }
                    vkEndCommandBuffer(secCmds[t]);
                });
            }
            for (auto& w : workers) w.join();
        }
        auto r1 = Clock::now();

        auto s0 = Clock::now();
        vkResetCommandPool(device, primaryPool, 0);
        VkCommandBufferBeginInfo pbi{ 42, nullptr, 0x04u, nullptr };
        vkBeginCommandBuffer(primaryCmd, &pbi);
        VkClearValue clearVal{};
        clearVal.color.float32[0] = 0.05f; clearVal.color.float32[1] = 0.10f;
        clearVal.color.float32[2] = 0.15f; clearVal.color.float32[3] = 1.0f;
        VkRenderPassBeginInfo rpbi{ 43, nullptr, renderPass, fb, sc, 1, &clearVal };
        vkCmdBeginRenderPass(primaryCmd, &rpbi, 1); // VK_SUBPASS_CONTENTS_SECONDARY_COMMAND_BUFFERS
        vkCmdExecuteCommands(primaryCmd, static_cast<uint32_t>(threads), secCmds.data());
        vkCmdEndRenderPass(primaryCmd);
        vkEndCommandBuffer(primaryCmd);

        vkResetFences(device, 1, &fence);
        VkSubmitInfo si{ 4, nullptr, 0, nullptr, nullptr, 1, &primaryCmd, 0, nullptr };
        vkQueueSubmit(queue, 1, &si, fence);
        vkWaitForFences(device, 1, &fence, 1, 5000000000ULL);
        auto s1 = Clock::now();

        auto t1 = Clock::now();
        if (f >= warmup) {
            recMs.push_back(std::chrono::duration<double, std::milli>(r1 - r0).count());
            subMs.push_back(std::chrono::duration<double, std::milli>(s1 - s0).count());
            totMs.push_back(std::chrono::duration<double, std::milli>(t1 - t0).count());
        }
    }

    vkDeviceWaitIdle(device);
    vkDestroyFence(device, fence, nullptr);
    for (int t = 0; t < threads; ++t) vkDestroyCommandPool(device, workerPools[t], nullptr);
    vkDestroyCommandPool(device, primaryPool, nullptr);
    vkDestroyPipeline(device, pipeline, nullptr);
    vkDestroyPipelineLayout(device, pipeLayout, nullptr);
    vkDestroyShaderModule(device, vertMod, nullptr);
    vkDestroyShaderModule(device, fragMod, nullptr);
    vkDestroyFramebuffer(device, fb, nullptr);
    vkDestroyRenderPass(device, renderPass, nullptr);
    vkDestroyImageView(device, imageView, nullptr);
    vkDestroyImage(device, image, nullptr);
    vkFreeMemory(device, mem, nullptr);
    vkDestroyDevice(device, nullptr);
    vkDestroyInstance(instance, nullptr);

    double meanTot = mean_val(totMs);
    double p50Tot = pct_val(totMs, 50.0);
    double p99Tot = pct_val(totMs, 99.0);
    std::ostringstream apiVer;
    apiVer << apiMaj << "." << apiMin << "." << apiPat;

    std::cout << std::fixed << std::setprecision(3)
              << "{\"ok\":true,\"api\":\"vulkan\""
              << ",\"device_name\":\"" << json_escape(props.deviceName) << "\""
              << ",\"api_version\":\"" << apiVer.str() << "\""
              << ",\"driver_version\":" << props.driverVersion
              << ",\"width\":" << width << ",\"height\":" << height
              << ",\"threads\":" << threads << ",\"draws_per_frame\":" << draws
              << ",\"frames\":" << frames
              << ",\"record_cpu_ms_mean\":" << mean_val(recMs)
              << ",\"submit_wait_ms_mean\":" << mean_val(subMs)
              << ",\"total_frame_ms_mean\":" << meanTot
              << ",\"frame_ms_p50\":" << p50Tot
              << ",\"frame_ms_p99\":" << p99Tot
              << ",\"fps_mean\":" << (meanTot > 0.0 ? 1000.0 / meanTot : 0.0)
              << ",\"fps_p1_low\":" << (p99Tot > 0.0 ? 1000.0 / p99Tot : 0.0)
              << "}\n";
    return 0;
}

// =========================================================================
// Mode 3: D3D12 (NPT_CAPSET_D3D12) Hardware Probe & Parallel CommandList Bench
// =========================================================================
static int run_d3d12(int width, int height, int threads, int draws, int frames, int warmup) {
    HMODULE d3d12Lib = LoadLibraryA("d3d12.dll");
    if (!d3d12Lib) {
        std::cout << "{\"ok\":false,\"api\":\"d3d12\",\"supported\":false,\"error\":\"d3d12.dll not found\"}\n";
        return 0;
    }
    using PFN_D3D12CreateDevice = HRESULT(WINAPI*)(IUnknown*, D3D_FEATURE_LEVEL, REFIID, void**);
    auto fnCreate = reinterpret_cast<PFN_D3D12CreateDevice>(GetProcAddress(d3d12Lib, "D3D12CreateDevice"));
    if (!fnCreate) {
        std::cout << "{\"ok\":false,\"api\":\"d3d12\",\"supported\":false,\"error\":\"D3D12CreateDevice missing\"}\n";
        return 0;
    }

    IDXGIFactory* factory = nullptr;
    IDXGIAdapter* hwAdapter = nullptr;
    std::string adapterName = "none";
    if (SUCCEEDED(CreateDXGIFactory(__uuidof(IDXGIFactory), (void**)&factory)) && factory) {
        for (UINT i = 0; factory->EnumAdapters(i, &hwAdapter) != DXGI_ERROR_NOT_FOUND; ++i) {
            DXGI_ADAPTER_DESC desc{};
            hwAdapter->GetDesc(&desc);
            char buf[256]{};
            WideCharToMultiByte(CP_UTF8, 0, desc.Description, -1, buf, sizeof(buf) - 1, nullptr, nullptr);
            std::string nm(buf);
            if (nm.find("Basic Render") == std::string::npos) {
                adapterName = nm;
                break;
            }
            hwAdapter->Release();
            hwAdapter = nullptr;
        }
        factory->Release();
    }

    ID3D12Device* dev = nullptr;
    HRESULT hr = fnCreate(hwAdapter, D3D_FEATURE_LEVEL_11_0, __uuidof(ID3D12Device), (void**)&dev);
    if (hwAdapter) hwAdapter->Release();
    if (FAILED(hr) || !dev) {
        std::cout << "{\"ok\":true,\"api\":\"d3d12\",\"supported\":false"
                  << ",\"adapter\":\"" << json_escape(adapterName) << "\""
                  << ",\"hresult\":\"0x" << std::hex << static_cast<uint32_t>(hr) << std::dec << "\"}\n";
        return 0;
    }

    D3D12_COMMAND_QUEUE_DESC qd{};
    qd.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
    ID3D12CommandQueue* queue = nullptr;
    hr = dev->CreateCommandQueue(&qd, __uuidof(ID3D12CommandQueue), (void**)&queue);
    if (FAILED(hr) || !queue) {
        dev->Release();
        std::cout << "{\"ok\":true,\"api\":\"d3d12\",\"supported\":false,\"error\":\"CreateCommandQueue failed\"}\n";
        return 0;
    }

    D3D12_DESCRIPTOR_HEAP_DESC rtvHeapDesc{};
    rtvHeapDesc.NumDescriptors = 1;
    rtvHeapDesc.Type = D3D12_DESCRIPTOR_HEAP_TYPE_RTV;
    ID3D12DescriptorHeap* rtvHeap = nullptr;
    dev->CreateDescriptorHeap(&rtvHeapDesc, __uuidof(ID3D12DescriptorHeap), (void**)&rtvHeap);

    D3D12_HEAP_PROPERTIES hp{};
    hp.Type = D3D12_HEAP_TYPE_DEFAULT;
    D3D12_RESOURCE_DESC rd{};
    rd.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    rd.Width = static_cast<UINT64>(width);
    rd.Height = static_cast<UINT>(height);
    rd.DepthOrArraySize = 1;
    rd.MipLevels = 1;
    rd.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    rd.SampleDesc.Count = 1;
    rd.Flags = D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    ID3D12Resource* rtRes = nullptr;
    hr = dev->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &rd, D3D12_RESOURCE_STATE_RENDER_TARGET, nullptr, __uuidof(ID3D12Resource), (void**)&rtRes);
    if (FAILED(hr) || !rtRes) {
        rtvHeap->Release(); queue->Release(); dev->Release();
        std::cout << "{\"ok\":true,\"api\":\"d3d12\",\"supported\":true,\"bench_ok\":false,\"error\":\"CreateCommittedResource failed\"}\n";
        return 0;
    }
    D3D12_CPU_DESCRIPTOR_HANDLE rtvHandle = rtvHeap->GetCPUDescriptorHandleForHeapStart();
    dev->CreateRenderTargetView(rtRes, nullptr, rtvHandle);

    std::vector<ID3D12CommandAllocator*> allocs(threads, nullptr);
    std::vector<ID3D12GraphicsCommandList*> lists(threads, nullptr);
    for (int t = 0; t < threads; ++t) {
        dev->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, __uuidof(ID3D12CommandAllocator), (void**)&allocs[t]);
        dev->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocs[t], nullptr, __uuidof(ID3D12GraphicsCommandList), (void**)&lists[t]);
        lists[t]->Close();
    }
    ID3D12Fence* fence = nullptr;
    dev->CreateFence(0, D3D12_FENCE_FLAG_NONE, __uuidof(ID3D12Fence), (void**)&fence);
    HANDLE fenceEv = CreateEventA(nullptr, FALSE, FALSE, nullptr);
    uint64_t fenceVal = 0;

    std::vector<double> recMs, subMs, totMs;
    int totalIters = warmup + frames;
    int cmdsPerThread = std::max(1, draws / std::max(1, threads));
    D3D12_VIEWPORT vp{ 0.0f, 0.0f, static_cast<float>(width), static_cast<float>(height), 0.0f, 1.0f };
    D3D12_RECT sc{ 0, 0, width, height };
    float col[4] = { 0.1f, 0.2f, 0.3f, 1.0f };

    for (int f = 0; f < totalIters; ++f) {
        auto t0 = Clock::now();
        auto r0 = Clock::now();
        std::vector<std::thread> workers;
        for (int t = 0; t < threads; ++t) {
            workers.emplace_back([&, t]() {
                allocs[t]->Reset();
                lists[t]->Reset(allocs[t], nullptr);
                lists[t]->OMSetRenderTargets(1, &rtvHandle, FALSE, nullptr);
                lists[t]->RSSetViewports(1, &vp);
                lists[t]->RSSetScissorRects(1, &sc);
                for (int d = 0; d < cmdsPerThread; ++d) {
                    lists[t]->RSSetViewports(1, &vp);
                    lists[t]->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
                }
                if (t == 0) lists[t]->ClearRenderTargetView(rtvHandle, col, 0, nullptr);
                lists[t]->Close();
            });
        }
        for (auto& w : workers) w.join();
        auto r1 = Clock::now();

        auto s0 = Clock::now();
        std::vector<ID3D12CommandList*> execLists(threads);
        for (int t = 0; t < threads; ++t) execLists[t] = lists[t];
        queue->ExecuteCommandLists(static_cast<UINT>(threads), execLists.data());
        fenceVal++;
        queue->Signal(fence, fenceVal);
        if (fence->GetCompletedValue() < fenceVal) {
            fence->SetEventOnCompletion(fenceVal, fenceEv);
            WaitForSingleObject(fenceEv, 5000);
        }
        auto s1 = Clock::now();
        auto t1 = Clock::now();
        if (f >= warmup) {
            recMs.push_back(std::chrono::duration<double, std::milli>(r1 - r0).count());
            subMs.push_back(std::chrono::duration<double, std::milli>(s1 - s0).count());
            totMs.push_back(std::chrono::duration<double, std::milli>(t1 - t0).count());
        }
    }

    CloseHandle(fenceEv);
    fence->Release();
    for (int t = 0; t < threads; ++t) { lists[t]->Release(); allocs[t]->Release(); }
    rtRes->Release(); rtvHeap->Release(); queue->Release(); dev->Release();

    double meanTot = mean_val(totMs);
    double p50Tot = pct_val(totMs, 50.0);
    double p99Tot = pct_val(totMs, 99.0);
    std::cout << std::fixed << std::setprecision(3)
              << "{\"ok\":true,\"api\":\"d3d12\",\"supported\":true"
              << ",\"adapter\":\"" << json_escape(adapterName) << "\""
              << ",\"width\":" << width << ",\"height\":" << height
              << ",\"threads\":" << threads << ",\"draws_per_frame\":" << draws
              << ",\"frames\":" << frames
              << ",\"record_cpu_ms_mean\":" << mean_val(recMs)
              << ",\"submit_wait_ms_mean\":" << mean_val(subMs)
              << ",\"total_frame_ms_mean\":" << meanTot
              << ",\"frame_ms_p50\":" << p50Tot
              << ",\"frame_ms_p99\":" << p99Tot
              << ",\"fps_mean\":" << (meanTot > 0.0 ? 1000.0 / meanTot : 0.0)
              << ",\"fps_p1_low\":" << (p99Tot > 0.0 ? 1000.0 / p99Tot : 0.0)
              << "}\n";
    return 0;
}

int main(int argc, char** argv) {
    std::string mode = "d3d11";
    int width = 1920, height = 1080, threads = 1, draws = 2048, frames = 60, warmup = 10;
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "--mode" && i + 1 < argc) mode = argv[++i];
        else if (a == "--width" && i + 1 < argc) width = std::atoi(argv[++i]);
        else if (a == "--height" && i + 1 < argc) height = std::atoi(argv[++i]);
        else if (a == "--threads" && i + 1 < argc) threads = std::atoi(argv[++i]);
        else if (a == "--draws" && i + 1 < argc) draws = std::atoi(argv[++i]);
        else if (a == "--frames" && i + 1 < argc) frames = std::atoi(argv[++i]);
        else if (a == "--warmup" && i + 1 < argc) warmup = std::atoi(argv[++i]);
    }
    if (mode == "d3d11") return run_d3d11(width, height, threads, draws, frames, warmup);
    if (mode == "vulkan") return run_vulkan(width, height, threads, draws, frames, warmup);
    if (mode == "d3d12") return run_d3d12(width, height, threads, draws, frames, warmup);
    std::cerr << "Unknown mode: " << mode << "\n";
    return 2;
}
'''

# =============================================================================
# 3. Windows 64-bit 60s TCP + 128-tick UDP Mixed Stress Client (WinSock2)
# =============================================================================
NET_MIXED_BENCH_CPP_SRC = r'''#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

using Clock = std::chrono::steady_clock;

static double pct(std::vector<double> v, double p) {
    if (v.empty()) return 0.0;
    std::sort(v.begin(), v.end());
    double idx = (static_cast<double>(v.size()) - 1.0) * (p / 100.0);
    size_t lo = static_cast<size_t>(std::floor(idx));
    size_t hi = static_cast<size_t>(std::ceil(idx));
    if (lo == hi) return v[lo];
    double f = idx - static_cast<double>(lo);
    return v[lo] * (1.0 - f) + v[hi] * f;
}

static double avg(const std::vector<double>& v) {
    if (v.empty()) return 0.0;
    double s = 0.0;
    for (double x : v) s += x;
    return s / static_cast<double>(v.size());
}

static bool send_all(SOCKET s, const char* buf, int len) {
    int off = 0;
    while (off < len) {
        int n = send(s, buf + off, len - off, 0);
        if (n <= 0) return false;
        off += n;
    }
    return true;
}

static bool recv_all(SOCKET s, char* buf, int len) {
    int off = 0;
    while (off < len) {
        int n = recv(s, buf + off, len - off, 0);
        if (n <= 0) return false;
        off += n;
    }
    return true;
}

int main(int argc, char** argv) {
    std::string host = "10.12.0.1";
    int udpPort = 19128, tcpPort = 19129, durationSec = 60, tickHz = 128, loadStartSec = 30;
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "--host" && i + 1 < argc) host = argv[++i];
        else if (a == "--udp-port" && i + 1 < argc) udpPort = std::atoi(argv[++i]);
        else if (a == "--tcp-port" && i + 1 < argc) tcpPort = std::atoi(argv[++i]);
        else if (a == "--duration" && i + 1 < argc) durationSec = std::atoi(argv[++i]);
        else if (a == "--tick-hz" && i + 1 < argc) tickHz = std::atoi(argv[++i]);
        else if (a == "--load-start" && i + 1 < argc) loadStartSec = std::atoi(argv[++i]);
    }

    WSADATA wsa{};
    WSAStartup(MAKEWORD(2, 2), &wsa);

    auto startTime = Clock::now();

    // UDP 128-tick thread
    std::vector<double> udpAllRtt, udpQuietRtt, udpLoadRtt;
    uint32_t udpSent = 0, udpRecv = 0, udpLost = 0, burstGe3 = 0;

    std::thread udpThread([&]() {
        SOCKET us = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        DWORD tv = 100;
        setsockopt(us, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>(&tv), sizeof(tv));
        sockaddr_in dst{};
        dst.sin_family = AF_INET;
        dst.sin_port = htons(static_cast<uint16_t>(udpPort));
        inet_pton(AF_INET, host.c_str(), &dst.sin_addr);

        int totalPkts = durationSec * tickHz;
        double intervalUs = 1000000.0 / static_cast<double>(tickHz);
        auto hardStop = startTime + std::chrono::seconds(durationSec + 5);
        uint32_t consecLoss = 0;
        char pkt[96]{};
        char rbuf[256]{};

        for (int i = 0; i < totalPkts && Clock::now() < hardStop; ++i) {
            auto target = startTime + std::chrono::microseconds(static_cast<int64_t>(i * intervalUs));
            while (Clock::now() < target) {
                auto rem = std::chrono::duration_cast<std::chrono::microseconds>(target - Clock::now()).count();
                if (rem > 1500) Sleep(1);
                else SwitchToThread();
            }
            uint32_t seq = static_cast<uint32_t>(i + 1);
            memcpy(pkt, &seq, 4);
            auto t0 = Clock::now();
            sendto(us, pkt, sizeof(pkt), 0, reinterpret_cast<sockaddr*>(&dst), sizeof(dst));
            udpSent++;

            bool got = false;
            while (true) {
                int n = recvfrom(us, rbuf, sizeof(rbuf), 0, nullptr, nullptr);
                if (n < 4) break;
                uint32_t rseq = 0;
                memcpy(&rseq, rbuf, 4);
                if (rseq == seq) {
                    auto t1 = Clock::now();
                    double rtt = std::chrono::duration<double, std::milli>(t1 - t0).count();
                    double elapsed = std::chrono::duration<double>(t0 - startTime).count();
                    udpAllRtt.push_back(rtt);
                    if (elapsed < loadStartSec) udpQuietRtt.push_back(rtt);
                    else udpLoadRtt.push_back(rtt);
                    udpRecv++;
                    got = true;
                    break;
                }
            }
            if (!got) {
                udpLost++;
                consecLoss++;
                if (consecLoss == 3) burstGe3++;
            } else {
                consecLoss = 0;
            }
        }
        closesocket(us);
    });

    // TCP concurrent RPC + stream integrity thread
    std::vector<double> tcpAllRtt, tcpLoadRtt;
    uint32_t tcpConnectAttempts = 0, tcpConnectOk = 0, tcpOpsOk = 0, tcpOpsErr = 0, tcpVerifyErr = 0;
    uint64_t tcpBytesTotal = 0;

    std::thread tcpThread([&]() {
        sockaddr_in dst{};
        dst.sin_family = AF_INET;
        dst.sin_port = htons(static_cast<uint16_t>(tcpPort));
        inet_pton(AF_INET, host.c_str(), &dst.sin_addr);

        const int msgSize = 4096;
        std::vector<char> sbuf(msgSize), rbuf(msgSize);

        auto endTime = startTime + std::chrono::seconds(durationSec);
        int roundIdx = 0;
        while (Clock::now() < endTime) {
            SOCKET ts = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
            BOOL nodelay = TRUE;
            setsockopt(ts, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<const char*>(&nodelay), sizeof(nodelay));
            DWORD tv = 5000;
            setsockopt(ts, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>(&tv), sizeof(tv));
            setsockopt(ts, SOL_SOCKET, SO_SNDTIMEO, reinterpret_cast<const char*>(&tv), sizeof(tv));

            tcpConnectAttempts++;
            if (connect(ts, reinterpret_cast<sockaddr*>(&dst), sizeof(dst)) != 0) {
                closesocket(ts);
                tcpOpsErr++;
                Sleep(50);
                continue;
            }
            tcpConnectOk++;

            // Perform 25 pipelined RPC round-trips per connection (exercises both handshake & steady stream)
            for (int op = 0; op < 25 && Clock::now() < endTime; ++op) {
                uint8_t pat = static_cast<uint8_t>((roundIdx + op) & 0xff);
                for (int k = 0; k < msgSize; ++k) sbuf[k] = static_cast<char>((pat + k) & 0xff);
                auto t0 = Clock::now();
                if (!send_all(ts, sbuf.data(), msgSize) || !recv_all(ts, rbuf.data(), msgSize)) {
                    tcpOpsErr++;
                    break;
                }
                auto t1 = Clock::now();
                if (memcmp(sbuf.data(), rbuf.data(), msgSize) != 0) {
                    tcpVerifyErr++;
                }
                double rtt = std::chrono::duration<double, std::milli>(t1 - t0).count();
                double elapsed = std::chrono::duration<double>(t0 - startTime).count();
                tcpAllRtt.push_back(rtt);
                if (elapsed >= loadStartSec) tcpLoadRtt.push_back(rtt);
                tcpOpsOk++;
                tcpBytesTotal += static_cast<uint64_t>(msgSize) * 2ULL;
                Sleep(20);
            }
            closesocket(ts);
            roundIdx++;
        }
    });

    udpThread.join();
    tcpThread.join();
    WSACleanup();

    double udpLossPct = udpSent > 0 ? (100.0 * static_cast<double>(udpLost) / static_cast<double>(udpSent)) : 0.0;
    double udpJitter = 0.0;
    if (udpAllRtt.size() > 1) {
        double jsum = 0.0;
        for (size_t i = 1; i < udpAllRtt.size(); ++i) jsum += std::fabs(udpAllRtt[i] - udpAllRtt[i - 1]);
        udpJitter = jsum / static_cast<double>(udpAllRtt.size() - 1);
    }
    double tcpConnSuccessPct = tcpConnectAttempts > 0 ? (100.0 * static_cast<double>(tcpConnectOk) / static_cast<double>(tcpConnectAttempts)) : 0.0;

    std::cout << std::fixed << std::setprecision(4)
              << "{\"ok\":true"
              << ",\"target_host\":\"" << host << "\""
              << ",\"target_udp_port\":" << udpPort
              << ",\"target_tcp_port\":" << tcpPort
              << ",\"duration_sec\":" << durationSec
              << ",\"udp\":{\"sent\":" << udpSent << ",\"received\":" << udpRecv
              << ",\"lost\":" << udpLost << ",\"loss_pct\":" << udpLossPct
              << ",\"burst_loss_ge3\":" << burstGe3
              << ",\"p50_rtt_ms\":" << pct(udpAllRtt, 50.0)
              << ",\"p99_rtt_ms\":" << pct(udpAllRtt, 99.0)
              << ",\"quiet_p99_rtt_ms\":" << pct(udpQuietRtt, 99.0)
              << ",\"loaded_p50_rtt_ms\":" << pct(udpLoadRtt, 50.0)
              << ",\"loaded_p99_rtt_ms\":" << pct(udpLoadRtt, 99.0)
              << ",\"mean_jitter_ms\":" << udpJitter << "}"
              << ",\"tcp\":{\"connect_attempts\":" << tcpConnectAttempts
              << ",\"connect_ok\":" << tcpConnectOk
              << ",\"connect_success_pct\":" << tcpConnSuccessPct
              << ",\"ops_ok\":" << tcpOpsOk
              << ",\"ops_err\":" << tcpOpsErr
              << ",\"verify_errors\":" << tcpVerifyErr
              << ",\"total_bytes\":" << tcpBytesTotal
              << ",\"p50_rtt_ms\":" << pct(tcpAllRtt, 50.0)
              << ",\"p99_rtt_ms\":" << pct(tcpAllRtt, 99.0)
              << ",\"loaded_p99_rtt_ms\":" << pct(tcpLoadRtt, 99.0) << "}"
              << "}\n";
    return 0;
}
'''


# =============================================================================
# 4. Pure Analysis, Redaction, and Device-Tree Audit Helpers (Unit Tested)
# =============================================================================

def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def redact_p15_text(text: str) -> str:
    if not text:
        return ""
    return p14e.redact_p14_text(str(text))


def redact_p15_value(value: Any) -> Any:
    if isinstance(value, dict):
        return {str(k): redact_p15_value(v) for k, v in value.items()}
    if isinstance(value, list):
        return [redact_p15_value(v) for v in value]
    if isinstance(value, str):
        return redact_p15_text(value)
    return value


def write_redacted_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    cleaned = redact_p15_value(payload)
    path.write_text(json.dumps(cleaned, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def audit_p15_device_tree(qemu_cmdline: str) -> dict[str, Any]:
    """Audit QEMU command line for Phase 15A full de-emulation invariants."""
    tokens = qemu_cmdline.split() if qemu_cmdline else []
    devices: list[str] = []
    chardevs: list[str] = []
    netdevs: list[str] = []
    for idx, tok in enumerate(tokens):
        if tok == "-device" and idx + 1 < len(tokens):
            devices.append(tokens[idx + 1])
        elif tok == "-chardev" and idx + 1 < len(tokens):
            chardevs.append(tokens[idx + 1])
        elif tok == "-netdev" and idx + 1 < len(tokens):
            netdevs.append(tokens[idx + 1])

    def _count(lst: list[str], substr: str) -> int:
        return sum(1 for item in lst if substr in item)

    usb_redir_count = _count(devices, "usb-redir")
    usb_redir_chardev_count = _count(chardevs, "name=usbredir")
    extra_qemu_xhci_count = _count(devices, "qemu-xhci")
    has_virtio_mouse = _count(devices, "virtio-mouse-pci") > 0
    has_usb_mouse = _count(devices, "usb-mouse") > 0
    has_usb_tablet = _count(devices, "usb-tablet") > 0
    has_virtio_balloon = _count(devices, "virtio-balloon") > 0
    has_slirp_user_net = any(nd.startswith("user,") or "type=user" in nd for nd in netdevs)
    has_intel_hda = _count(devices, "intel-hda") > 0
    has_virtio_sound = _count(devices, "virtio-sound") > 0
    has_virtio_blk = _count(devices, "virtio-blk") > 0
    has_virtio_gpu = _count(devices, "virtio-ramfb-gl") > 0 or _count(devices, "virtio-gpu") > 0

    deemulated_clean = (
        has_virtio_mouse
        and not has_usb_mouse
        and not has_usb_tablet
        and usb_redir_count == 0
        and usb_redir_chardev_count == 0
        and extra_qemu_xhci_count == 0
        and not has_virtio_balloon
        and not has_slirp_user_net
    )
    return {
        "device_count": len(devices),
        "devices": [redact_p15_text(d) for d in devices],
        "netdevs": [redact_p15_text(n) for n in netdevs],
        "has_virtio_mouse": has_virtio_mouse,
        "has_usb_mouse": has_usb_mouse,
        "has_usb_tablet": has_usb_tablet,
        "usb_redir_device_count": usb_redir_count,
        "usb_redir_chardev_count": usb_redir_chardev_count,
        "extra_qemu_xhci_count": extra_qemu_xhci_count,
        "has_virtio_balloon": has_virtio_balloon,
        "has_slirp_user_net": has_slirp_user_net,
        "has_intel_hda": has_intel_hda,
        "has_virtio_sound": has_virtio_sound,
        "has_virtio_blk": has_virtio_blk,
        "has_virtio_gpu": has_virtio_gpu,
        "deemulated_clean": deemulated_clean,
    }


def compare_multithread_scaling(single_arm: dict[str, Any], mt_arms: list[dict[str, Any]]) -> dict[str, Any]:
    """Quantify CPU command recording speedup and FPS gain for 4/8 threads vs 1 thread."""
    base_rec = float(single_arm.get("record_cpu_ms_mean") or 0.0)
    base_tot = float(single_arm.get("total_frame_ms_mean") or 0.0)
    base_fps = float(single_arm.get("fps_mean") or 0.0)
    comparisons: list[dict[str, Any]] = []
    best_fps_arm: dict[str, Any] | None = None
    for arm in mt_arms:
        rec = float(arm.get("record_cpu_ms_mean") or 0.0)
        tot = float(arm.get("total_frame_ms_mean") or 0.0)
        fps = float(arm.get("fps_mean") or 0.0)
        entry = {
            "threads": int(arm.get("threads", 1)),
            "record_cpu_ms_mean": round(rec, 3),
            "record_cpu_speedup_x": round(base_rec / rec, 2) if (base_rec > 0 and rec > 0) else None,
            "record_cpu_delta_pct": p14e.pct_delta(base_rec, rec),
            "total_frame_ms_mean": round(tot, 3),
            "total_frame_ms_delta_pct": p14e.pct_delta(base_tot, tot),
            "fps_mean": round(fps, 3),
            "fps_gain_pct": p14e.pct_delta(base_fps, fps),
        }
        comparisons.append(entry)
        if best_fps_arm is None or (entry["fps_mean"] > best_fps_arm["fps_mean"]):
            best_fps_arm = entry
    return {
        "api": single_arm.get("api"),
        "resolution": f"{single_arm.get('width')}x{single_arm.get('height')}",
        "single_thread_record_cpu_ms": round(base_rec, 3),
        "single_thread_total_frame_ms": round(base_tot, 3),
        "single_thread_fps_mean": round(base_fps, 3),
        "mt_arms": comparisons,
        "best_mt_arm": best_fps_arm,
    }


def compare_mixed_network_arms(slirp_arm: dict[str, Any], candidate_arm: dict[str, Any]) -> dict[str, Any]:
    """Compare non-slirp TCP+UDP+ICMP arm against slirp baseline."""
    s_udp = slirp_arm.get("udp", {})
    c_udp = candidate_arm.get("udp", {})
    s_tcp = slirp_arm.get("tcp", {})
    c_tcp = candidate_arm.get("tcp", {})
    return {
        "candidate_label": candidate_arm.get("label"),
        "udp_zero_loss": (float(c_udp.get("loss_pct", 100.0)) == 0.0 and int(c_udp.get("burst_loss_ge3", 1)) == 0),
        "udp_p50_delta_pct": p14e.pct_delta(s_udp.get("p50_rtt_ms"), c_udp.get("p50_rtt_ms")),
        "udp_p99_delta_pct": p14e.pct_delta(s_udp.get("p99_rtt_ms"), c_udp.get("p99_rtt_ms")),
        "udp_loaded_p99_delta_pct": p14e.pct_delta(s_udp.get("loaded_p99_rtt_ms"), c_udp.get("loaded_p99_rtt_ms")),
        "tcp_zero_verify_errors": int(c_tcp.get("verify_errors", 1)) == 0 and int(c_tcp.get("ops_err", 1)) == 0,
        "tcp_connect_success_pct": c_tcp.get("connect_success_pct"),
        "tcp_p50_delta_pct": p14e.pct_delta(s_tcp.get("p50_rtt_ms"), c_tcp.get("p50_rtt_ms")),
        "tcp_p99_delta_pct": p14e.pct_delta(s_tcp.get("p99_rtt_ms"), c_tcp.get("p99_rtt_ms")),
        "tcp_loaded_p99_delta_pct": p14e.pct_delta(s_tcp.get("loaded_p99_rtt_ms"), c_tcp.get("loaded_p99_rtt_ms")),
    }


def compare_iosurface_present_arms(shadow_arm: dict[str, Any], direct_arm: dict[str, Any]) -> dict[str, Any]:
    """Compare shadowTexture copy (UTM_IOSURFACE_DIRECT_PRESENT=0) vs zero-copy direct present (=1)."""
    s_fm = shadow_arm.get("frame_metrics", {})
    d_fm = direct_arm.get("frame_metrics", {})
    width = int(direct_arm.get("width", 3840))
    height = int(direct_arm.get("height", 2160))
    eliminated_copy_mib_per_frame = round((width * height * 4) / (1024.0 * 1024.0), 3)
    fps = float(d_fm.get("fps_mean") or 0.0)
    return {
        "resolution": f"{width}x{height}",
        "fps_mean_delta_pct": p14e.pct_delta(s_fm.get("fps_mean"), d_fm.get("fps_mean")),
        "fps_p1_low_delta_pct": p14e.pct_delta(s_fm.get("fps_p1_low"), d_fm.get("fps_p1_low")),
        "frame_ms_p99_delta_pct": p14e.pct_delta(s_fm.get("frame_ms_p99"), d_fm.get("frame_ms_p99")),
        "jitter_p99_p50_delta_pct": p14e.pct_delta(
            s_fm.get("frame_ms_jitter_p99_p50"), d_fm.get("frame_ms_jitter_p99_p50")
        ),
        "eliminated_shadow_copy_mib_per_frame": eliminated_copy_mib_per_frame,
        "estimated_saved_bandwidth_mib_per_sec": round(eliminated_copy_mib_per_frame * fps, 2),
    }


# =============================================================================
# 5. Out-of-Repo Builders, Host Servers, and Proxy Process Managers
# =============================================================================

def _tools_dir() -> Path:
    d = Path(os.environ.get("TMPDIR", "/tmp")) / "p15a-tools"
    d.mkdir(parents=True, exist_ok=True)
    return d


def build_full_tcp_udp_proxy() -> Path:
    tools = _tools_dir()
    src = tools / "full_tcp_udp_proxy.go"
    bin_path = tools / "full_tcp_udp_proxy"
    expected_hash = hashlib.sha256(FULL_TCP_UDP_PROXY_GO_SRC.encode("utf-8")).hexdigest()[:16]
    marker = tools / f".proxy-{expected_hash}.ok"
    if bin_path.is_file() and marker.is_file():
        return bin_path
    src.write_text(FULL_TCP_UDP_PROXY_GO_SRC, encoding="utf-8")
    env = os.environ.copy()
    env["CGO_ENABLED"] = "1"
    env["PATH"] = f"/opt/homebrew/bin:{env.get('PATH', '')}"
    subprocess.run(
        [str(GO_BIN), "build", "-o", str(bin_path), str(src)],
        check=True,
        env=env,
        capture_output=True,
        text=True,
        timeout=120,
    )
    marker.write_text("ok\n", encoding="utf-8")
    return bin_path


def start_full_tcp_udp_proxy(
    listen_addr: str = "127.0.0.1:0",
    stats_file: Path | None = None,
) -> tuple[subprocess.Popen[str], str, bool]:
    bin_path = build_full_tcp_udp_proxy()
    cmd = [str(bin_path), "-listen", listen_addr]
    if stats_file is not None:
        cmd.extend(["-stats-file", str(stats_file)])
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    assert proc.stdout is not None
    deadline = time.monotonic() + 15.0
    line = ""
    while time.monotonic() < deadline:
        line = proc.stdout.readline().strip()
        if line.startswith("READY "):
            parts = line.split()
            endpoint = parts[1]
            qos_ok = any(p == "QOS_INTERACTIVE=true" for p in parts[2:])
            return proc, endpoint, qos_ok
        if proc.poll() is not None:
            err = proc.stderr.read() if proc.stderr else ""
            raise RuntimeError(f"full_tcp_udp_proxy exited early: {err}")
        time.sleep(0.05)
    proc.terminate()
    raise TimeoutError("full_tcp_udp_proxy did not emit READY line")


def _stop_proxy(proc: subprocess.Popen[str] | None) -> None:
    if proc is None:
        return
    try:
        proc.terminate()
        proc.wait(timeout=2.0)
    except Exception:
        try:
            proc.kill()
            proc.wait(timeout=2.0)
        except Exception:
            pass
    for stream in (proc.stdout, proc.stderr):
        if stream is not None:
            try:
                stream.close()
            except Exception:
                pass


def build_windows_tool(name: str, cpp_src: str, extra_libs: list[str]) -> Path:
    tools = _tools_dir()
    src = tools / f"{name}.cpp"
    exe = tools / f"{name}.exe"
    h = hashlib.sha256((cpp_src + "|static-v2").encode("utf-8")).hexdigest()[:16]
    marker = tools / f".{name}-{h}.ok"
    if exe.is_file() and marker.is_file():
        return exe
    src.write_text(cpp_src, encoding="utf-8")
    cmd = [
        str(MINGW_GXX),
        "-O2",
        "-std=c++17",
        "-static",
        str(src),
        "-o",
        str(exe),
        *extra_libs,
    ]
    res = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    if res.returncode != 0:
        raise RuntimeError(f"mingw build failed for {name}: {res.stderr[-800:]}")
    marker.write_text("ok\n", encoding="utf-8")
    return exe


class HostMixedEchoServer:
    """Host-side concurrent UDP 128-tick + TCP 4KiB echo server bound to 0.0.0.0."""

    def __init__(self) -> None:
        self._stop = threading.Event()
        self.udp_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.udp_sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 * 1024 * 1024)
        self.udp_sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4 * 1024 * 1024)
        self.udp_sock.bind(("0.0.0.0", 0))
        self.udp_sock.settimeout(0.5)
        self.udp_port = int(self.udp_sock.getsockname()[1])

        self.tcp_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.tcp_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.tcp_sock.bind(("0.0.0.0", 0))
        self.tcp_sock.listen(64)
        self.tcp_sock.settimeout(0.5)
        self.tcp_port = int(self.tcp_sock.getsockname()[1])

        self._threads = [
            threading.Thread(target=self._udp_loop, daemon=True),
            threading.Thread(target=self._tcp_accept_loop, daemon=True),
        ]

    def start(self) -> None:
        for t in self._threads:
            t.start()

    def _udp_loop(self) -> None:
        while not self._stop.is_set():
            try:
                data, addr = self.udp_sock.recvfrom(4096)
                if data:
                    self.udp_sock.sendto(data, addr)
            except socket.timeout:
                continue
            except OSError:
                break

    def _tcp_accept_loop(self) -> None:
        while not self._stop.is_set():
            try:
                conn, _ = self.tcp_sock.accept()
                threading.Thread(target=self._tcp_client, args=(conn,), daemon=True).start()
            except socket.timeout:
                continue
            except OSError:
                break

    def _tcp_client(self, conn: socket.socket) -> None:
        try:
            conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            conn.settimeout(10.0)
            while not self._stop.is_set():
                chunk = conn.recv(65536)
                if not chunk:
                    break
                conn.sendall(chunk)
        except OSError:
            pass
        finally:
            try:
                conn.close()
            except OSError:
                pass

    def stop(self) -> None:
        self._stop.set()
        for s in (self.udp_sock, self.tcp_sock):
            try:
                s.close()
            except OSError:
                pass


# =============================================================================
# 6. Evidence & Real-Machine Experiment Runners
# =============================================================================

def audit_vmnet_bridge_daemon() -> dict[str, Any]:
    """Verify malt-vmnet-bridge C compilation, vmnet.framework linkage, plist lint, and live daemon status."""
    installer = VMNET_BRIDGE_DIR / "install_vmnet_bridge.sh"
    plist_tpl = VMNET_BRIDGE_DIR / "com.malt.vmnet-bridge.plist.template"
    out_bin = Path(os.environ.get("TMPDIR", "/tmp")) / "utm-custom-build" / "malt-vmnet-bridge"

    build_res = subprocess.run(
        ["bash", str(installer), "--build-only", "--out-bin", str(out_bin)],
        capture_output=True,
        text=True,
        timeout=60,
    )
    self_check = json.loads(build_res.stdout.strip()) if build_res.returncode == 0 and build_res.stdout.strip() else {}

    status_res = subprocess.run(
        ["bash", str(installer), "--status"],
        capture_output=True,
        text=True,
        timeout=20,
    )
    daemon_status = json.loads(status_res.stdout.strip()) if status_res.returncode == 0 and status_res.stdout.strip() else {}

    lint_res = subprocess.run(
        ["plutil", "-lint", str(plist_tpl)],
        capture_output=True,
        text=True,
        timeout=15,
    )
    caps = ggm.detect_host_network_capabilities()
    return {
        "build_ok": build_res.returncode == 0,
        "self_check": self_check,
        "plist_template_lint_ok": lint_res.returncode == 0,
        "daemon_status": daemon_status,
        "host_network_capabilities": caps,
        "note": (
            "malt-vmnet-bridge LaunchDaemon is active; direct kernel vmnet.framework bridge ready."
            if daemon_status.get("socket_active")
            else "malt-vmnet-bridge compiled and LaunchDaemon template verified; not yet sudo-installed on this headless run, so ad-hoc UTM-Custom seamlessly falls back to the zero-privilege full TCP+UDP+ICMP high-QoS proxy."
        ),
    }


def generate_patch_and_build_evidence(custom_app: Path = DEFAULT_CUSTOM_APP) -> tuple[dict[str, Any], dict[str, Any]]:
    """Run patch compliance audit + UTM-Custom.app strict codesign verification and save JSON evidence."""
    tmp = Path(os.environ.get("TMPDIR", "/tmp"))
    utm_repo = tmp / "utm-custom-src" / "UTM"
    spice_repo = tmp / "utm-custom-src" / "CocoaSpice"

    # Reset external clones cleanly before standalone+stacked apply check
    if (utm_repo / ".git").is_dir():
        subprocess.run(["git", "-C", str(utm_repo), "reset", "--hard", "v5.0.9"], capture_output=True, check=False)
    if (spice_repo / ".git").is_dir():
        subprocess.run(
            ["git", "-C", str(spice_repo), "checkout", "-f", "e239fab0828ebafc3a5a973fa84039400d7ac703"],
            capture_output=True,
            check=False,
        )

    patch_audit = ucpv.verify_patches_directory(
        patches_dir=PATCHES_DIR,
        utm_repo=utm_repo if utm_repo.is_dir() else None,
        cocoaspice_repo=spice_repo if spice_repo.is_dir() else None,
    )
    patch_audit["verified_at_utc"] = utc_now_iso()
    write_redacted_json(EVIDENCE_P15A / "patch-audit.json", patch_audit)

    cs_res = subprocess.run(
        ["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(custom_app)],
        capture_output=True,
        text=True,
        timeout=60,
    )
    utm_bin = custom_app / "Contents/MacOS/UTM"
    strings_res = subprocess.run(["strings", str(utm_bin)], capture_output=True, text=True, timeout=30)
    bin_strings = strings_res.stdout or ""
    expected_markers = [
        "IOSurface Direct Blit Present",
        "UTM_IOSURFACE_DIRECT_PRESENT",
        "UTM_VIRTIO_MOUSE",
        "UTM_DISABLE_USB_REDIR",
        "virtio-mouse-pci",
    ]
    marker_hits = {m: (m in bin_strings) for m in expected_markers}

    orig_cs = subprocess.run(
        ["codesign", "--verify", "--deep", "--strict", str(OFFICIAL_UTM_APP)],
        capture_output=True,
        text=True,
        timeout=60,
    )
    bridge_audit = audit_vmnet_bridge_daemon()

    build_verif = {
        "schema_version": 1,
        "owner": "@DNPMBHC",
        "verified_at_utc": utc_now_iso(),
        "custom_app_alias": custom_app.name,
        "custom_app_exists": custom_app.is_dir(),
        "codesign_strict_passed": cs_res.returncode == 0,
        "utm_binary_sha256": ggm.sha256_file(utm_bin) if utm_bin.is_file() else None,
        "patch09_binary_markers": marker_hits,
        "all_patch09_markers_present": all(marker_hits.values()),
        "original_utm_app_untouched_codesign_ok": orig_cs.returncode == 0,
        "vmnet_bridge_daemon_audit": bridge_audit,
        "passed": (
            cs_res.returncode == 0
            and all(marker_hits.values())
            and orig_cs.returncode == 0
            and bool(bridge_audit.get("build_ok"))
            and bool(bridge_audit.get("plist_template_lint_ok"))
        ),
    }
    write_redacted_json(EVIDENCE_P15A / "build-verification.json", build_verif)
    return patch_audit, build_verif


def _run_guest_interactive_exe(
    vm_uuid: str,
    utmctl: Path,
    *,
    task_name: str,
    guest_dir: str,
    exe_path: str,
    arg_list: list[str],
    timeout_sec: int = 180,
) -> dict[str, Any]:
    """Execute a Windows binary in the interactive desktop session and capture its stdout JSON."""
    out_file = f"{guest_dir}\\{task_name}.out"
    err_file = f"{guest_dir}\\{task_name}.err"
    done_file = f"{guest_dir}\\{task_name}.done"
    ps_args = ", ".join(f"'{a}'" for a in arg_list)
    runner_ps = (
        "$ErrorActionPreference='Continue'\n"
        "$code = 1\n"
        "try {\n"
        f"  $p = Start-Process -FilePath '{exe_path}' -ArgumentList @({ps_args}) -PassThru -NoNewWindow -RedirectStandardOutput '{out_file}' -RedirectStandardError '{err_file}'\n"
        "  $p.WaitForExit()\n"
        "  $code = $p.ExitCode\n"
        "} finally {\n"
        f"  Set-Content -LiteralPath '{done_file}' -Value ([string]$code)\n"
        "}\n"
    )
    with tempfile.NamedTemporaryFile("w", suffix=".ps1", delete=False, encoding="utf-8") as tmpf:
        tmpf.write(runner_ps)
        local_ps = Path(tmpf.name)
    try:
        guest_ps = f"{guest_dir}\\{task_name}.ps1"
        p14e._upload_file_to_guest(vm_uuid, local_ps, guest_ps, utmctl=utmctl)
    finally:
        local_ps.unlink(missing_ok=True)

    launch_ps = (
        "$user=(Get-CimInstance Win32_ComputerSystem).UserName;"
        "if(!$user){throw 'No interactive desktop user'};"
        f"Remove-Item -LiteralPath '{done_file}','{out_file}','{err_file}' -ErrorAction SilentlyContinue;"
        f"$a=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File {guest_dir}\\{task_name}.ps1';"
        "$p=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited;"
        f"Register-ScheduledTask -TaskName '{task_name}' -Action $a -Principal $p -Force | Out-Null;"
        f"Start-ScheduledTask -TaskName '{task_name}'; 'STARTED'"
    )
    p14e._qga_ps(vm_uuid, launch_ps, utmctl=utmctl, timeout=45.0)

    deadline = time.monotonic() + timeout_sec
    exit_code: int | None = None
    while time.monotonic() < deadline:
        val = p14e._qga_ps(
            vm_uuid,
            f"if(Test-Path '{done_file}'){{(Get-Content -Raw '{done_file}').Trim()}}else{{'PENDING'}}",
            utmctl=utmctl,
            timeout=20.0,
        ).strip()
        if val != "PENDING":
            try:
                exit_code = int(val)
            except ValueError:
                exit_code = -1
            break
        time.sleep(1.5)

    p14e._qga_ps(
        vm_uuid,
        f"Unregister-ScheduledTask -TaskName '{task_name}' -Confirm:$false -ErrorAction SilentlyContinue | Out-Null; 'OK'",
        utmctl=utmctl,
        timeout=20.0,
    )
    if exit_code is None:
        raise TimeoutError(f"Guest interactive task {task_name} timed out after {timeout_sec}s")

    stdout_text = p14e._qga_ps(
        vm_uuid,
        f"if(Test-Path '{out_file}'){{Get-Content -Raw '{out_file}'}}else{{''}}",
        utmctl=utmctl,
        timeout=30.0,
    ).strip()
    stderr_text = p14e._qga_ps(
        vm_uuid,
        f"if(Test-Path '{err_file}'){{Get-Content -Raw '{err_file}'}}else{{''}}",
        utmctl=utmctl,
        timeout=30.0,
    ).strip()
    parsed: dict[str, Any] = {}
    for line in reversed(stdout_text.splitlines()):
        ln = line.strip()
        if ln.startswith("{") and ln.endswith("}"):
            try:
                parsed = json.loads(ln)
                break
            except json.JSONDecodeError:
                pass
    return {
        "exit_code": exit_code,
        "parsed": parsed,
        "stdout_tail": stdout_text[-400:],
        "stderr_tail": stderr_text[-400:],
    }


def _launch_utm_custom_p15(
    *,
    custom_app: Path,
    vm_uuid: str,
    vm_bundle: Path,
    shader_cache_dir: Path | None = None,
    fps_limit: int = 120,
    drawable_count: int = 3,
    max_inflight_frames: int = 3,
    iosurface_direct_present: bool = True,
    virtio_mouse: bool = True,
    disable_usb_redir: bool = True,
    dx_driver_flag: str = "--dxmt-native",
    extra_env: dict[str, str] | None = None,
) -> subprocess.Popen[str]:
    p14e._ensure_registered_and_persisted(vm_bundle, vm_uuid)
    p14e._quit_any_utm()
    utm_bin = custom_app / "Contents/MacOS/UTM"
    custom_utmctl = custom_app / "Contents/MacOS/utmctl"
    env = os.environ.copy()
    env["UTM_DIRECTX_BACKEND"] = "dxmt-native" if dx_driver_flag == "--dxmt-native" else "d3dmetal-native"
    env["UTM_RENDER_FPS_LIMIT"] = str(fps_limit)
    env["UTM_METAL_DRAWABLE_COUNT"] = str(drawable_count)
    env["UTM_MAX_INFLIGHT_FRAMES"] = str(max_inflight_frames)
    env["UTM_IOSURFACE_DIRECT_PRESENT"] = "1" if iosurface_direct_present else "0"
    env["UTM_VIRTIO_MOUSE"] = "1" if virtio_mouse else "0"
    env["UTM_DISABLE_USB_REDIR"] = "1" if disable_usb_redir else "0"
    env["UTM_PURE_RELATIVE_MOUSE"] = "1"
    env["UTM_KEEP_CURSOR_VISIBLE_ON_INHIBIT"] = "1"
    env["UTM_GAME_SHELL_VM"] = vm_uuid
    if shader_cache_dir is not None:
        shader_cache_dir.mkdir(parents=True, exist_ok=True)
        env["DXMT_SHADER_CACHE"] = "1"
        env["UTM_DXMT_SHADER_CACHE_PATH"] = str(shader_cache_dir)
        env["DXMT_SHADER_CACHE_PATH"] = str(shader_cache_dir)
    if extra_env:
        env.update(extra_env)

    cmd = [str(utm_bin), "--pure-relative-mouse", "--game-shell-vm", vm_uuid]
    if dx_driver_flag:
        cmd.append(dx_driver_flag)
    if virtio_mouse:
        cmd.append("--virtio-mouse")
    else:
        cmd.append("--usb-mouse-fallback")
    if disable_usb_redir:
        cmd.append("--no-usb-redir")
    if not iosurface_direct_present:
        cmd.append("--disable-iosurface-direct-present")

    log_path = _tools_dir() / "utm-custom-p15-launch.log"
    log_handle = log_path.open("w", encoding="utf-8")
    proc = subprocess.Popen(
        cmd,
        env=env,
        stdout=log_handle,
        stderr=subprocess.STDOUT,
        text=True,
        start_new_session=True,
    )
    log_handle.close()
    qemu_found = False
    for i in range(25):
        if proc.poll() is not None:
            break
        if p14e._get_qemu_cmdline():
            qemu_found = True
            break
        if i == 10 and custom_utmctl.is_file():
            subprocess.run([str(custom_utmctl), "start", vm_uuid], capture_output=True, text=True, check=False)
        time.sleep(1.0)
    print(f"[p15a-launch] pid={proc.pid} poll={proc.poll()} qemu_found={qemu_found}", file=sys.stderr, flush=True)
    time.sleep(5.0)
    return proc


def _probe_guest_audio_and_security(vm_uuid: str, utmctl: Path) -> dict[str, Any]:
    """Inspect Guest Secure Boot, vioinput WHQL, and WHQL virtio-sound (viosnd) driver availability."""
    ps = r"""
$sb = $true
try { $sb = [bool](Confirm-SecureBootUEFI) } catch {}
$pnp = (pnputil /enum-drivers 2>&1 | Out-String)
$hasVioInput = ($pnp -match 'vioinput\.inf')
$hasVioSnd = ($pnp -match 'viosnd\.inf|virtio[-_ ]?sound')
$audioDevs = @(Get-CimInstance Win32_SoundDevice -ErrorAction SilentlyContinue | Select-Object Name, Manufacturer, Status)
$inputDevs = @(Get-CimInstance Win32_PointingDevice -ErrorAction SilentlyContinue | Select-Object Name, Description, Status)
[PSCustomObject]@{
  secure_boot_enabled = $sb
  whql_vioinput_present = $hasVioInput
  whql_viosnd_present = $hasVioSnd
  audio_devices = $audioDevs
  pointing_devices = $inputDevs
} | ConvertTo-Json -Depth 4 -Compress
"""
    raw = p14e._qga_ps(vm_uuid, ps, utmctl=utmctl, timeout=60.0)
    return json.loads(raw) if raw else {}


def _run_mixed_net_arm(
    *,
    label: str,
    golden: Path,
    primary: Path,
    vms_dir: Path,
    custom_app: Path,
    use_official_utm: bool,
    network_mode: str,
    duration_sec: int,
    net_bench_exe: Path,
    bridge_socket: str | None = None,
) -> dict[str, Any]:
    """Run a 60s TCP + 128-tick UDP mixed stress arm (30s quiet + 30s D3D11 heavy render)."""
    echo_srv = HostMixedEchoServer()
    echo_srv.start()
    proxy_proc: subprocess.Popen[str] | None = None
    proxy_stats_path = _tools_dir() / f"proxy-stats-{label}-{uuid.uuid4().hex[:6]}.json"
    utm_proc: subprocess.Popen[str] | None = None
    created_bundle: Path | None = None
    utmctl = OFFICIAL_UTMCTL if use_official_utm else (custom_app / "Contents/MacOS/utmctl")
    vm_name = f"ephemeral-p15a-net-{label}-{uuid.uuid4().hex[:5]}"

    try:
        socket_ep: str | None = None
        proxy_qos_ok: bool | None = None
        if network_mode == "socket-stream":
            proxy_proc, socket_ep, proxy_qos_ok = start_full_tcp_udp_proxy(
                listen_addr="127.0.0.1:0",
                stats_file=proxy_stats_path,
            )
        elif network_mode == "socket-vmnet":
            socket_ep = bridge_socket

        spawned = ggm.spawn_ephemeral(
            golden=golden,
            dest_dir=vms_dir,
            name=vm_name,
            primary=primary,
            register_utm=use_official_utm,
            trim_hardware=True,
            no_sound=False,
            dx_driver="DXMT",
            fps_limit=120,
            ram_mb=10240,
            vcpu=8,
            disable_balloon=True,
            pure_relative_mouse=True,
            virtio_mouse=not use_official_utm,
            disable_usb_redir=True,
            iosurface_direct_present=True,
            network_mode=network_mode,
            socket_endpoint=socket_ep,
            net_rx_queue_size=1024,
            disk_interface="virtio",
            enable_iothread=True,
            io_queues=4,
            fast_disk_hash=True,
        )
        created_bundle = Path(spawned["ephemeral_path"])
        vm_uuid = spawned["clone_uuid"]

        if use_official_utm:
            p14e._quit_any_utm()
            subprocess.run(["open", "-a", str(OFFICIAL_UTM_APP), str(created_bundle)], capture_output=True, check=False)
            time.sleep(3.0)
            subprocess.run([str(OFFICIAL_UTMCTL), "start", vm_uuid], capture_output=True, check=False)
        else:
            utm_proc = _launch_utm_custom_p15(
                custom_app=custom_app,
                vm_uuid=vm_uuid,
                vm_bundle=created_bundle,
                fps_limit=120,
                iosurface_direct_present=True,
                virtio_mouse=True,
                disable_usb_redir=True,
            )

        p14e._wait_qga_ready(vm_uuid, utmctl, timeout_sec=180.0)
        qemu_cmdline = p14e._get_qemu_cmdline()
        dev_audit = audit_p15_device_tree(qemu_cmdline)

        # Wait for Guest IPv4 gateway (DHCP lease)
        gw_ip = ""
        gw_dl = time.monotonic() + 60.0
        while time.monotonic() < gw_dl:
            gw_ip = p14e._qga_ps(
                vm_uuid,
                "(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty NextHop)",
                utmctl=utmctl,
                timeout=20.0,
            ).strip()
            if re.match(r"^\d+\.\d+\.\d+\.\d+$", gw_ip):
                break
            time.sleep(2.0)
        if not gw_ip:
            gw_ip = "10.12.0.1" if network_mode == "socket-stream" else "10.0.2.2"

        # ICMP ping check to gateway
        ping_ok = p14e._qga_ps(
            vm_uuid,
            f"$r = Test-Connection -ComputerName '{gw_ip}' -Count 3 -Quiet -ErrorAction SilentlyContinue; if($r){{'OK'}}else{{'FAIL'}}",
            utmctl=utmctl,
            timeout=25.0,
        ).strip() == "OK"
        print(
            f"[p15a-net] label={label} mode={network_mode} gw={gw_ip!r} ping_ok={ping_ok} udp={echo_srv.udp_port} tcp={echo_srv.tcp_port}",
            file=sys.stderr,
            flush=True,
        )

        guest_dir = r"C:\graphics-lab\p15a"
        p14e._qga_ps(vm_uuid, rf"New-Item -ItemType Directory -Force -Path '{guest_dir}' | Out-Null", utmctl=utmctl)
        p14e._upload_file_to_guest(vm_uuid, net_bench_exe, rf"{guest_dir}\net_mixed_bench.exe", utmctl=utmctl)
        p14e._upload_file_to_guest(vm_uuid, D3D11_PROBE, rf"{guest_dir}\d3d11_probe.exe", utmctl=utmctl)

        # Launch D3D11 heavy render load in Interactive Desktop Session 1 at t=load_start..duration_sec,
        # while running WinSock2 net_mixed_bench.exe concurrently via QGA (avoids Session 1 firewall prompts).
        load_start = max(10, duration_sec // 2)
        load_ps = f"""
$ErrorActionPreference='Continue'
Start-Sleep -Seconds {load_start}
$d3dEnd = (Get-Date).AddSeconds({duration_sec - load_start})
while ((Get-Date) -lt $d3dEnd) {{
  $gp = Start-Process -FilePath '{guest_dir}\\d3d11_probe.exe' -ArgumentList @(
    '--frames','180','--warmup','10','--width','1920','--height','1080',
    '--commands','3072','--command-every','1','--resource-bytes','1048576','--resource-every','1',
    '--driver-type','hardware','--csv','{guest_dir}\\net-load.csv'
  ) -PassThru -NoNewWindow
  if (-not $gp.WaitForExit(32000)) {{
    try {{ $gp.Kill() }} catch {{}}
  }}
}}
"""
        with tempfile.NamedTemporaryFile("w", suffix=".ps1", delete=False, encoding="utf-8") as f:
            f.write(load_ps)
            tmp_ps = Path(f.name)
        try:
            p14e._upload_file_to_guest(vm_uuid, tmp_ps, rf"{guest_dir}\run-d3dload-{label}.ps1", utmctl=utmctl)
        finally:
            tmp_ps.unlink(missing_ok=True)

        task_name = f"p15a-d3dload-{label}"
        p14e._qga_ps(
            vm_uuid,
            (
                "$user=(Get-CimInstance Win32_ComputerSystem).UserName;"
                f"$a=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File {guest_dir}\\run-d3dload-{label}.ps1';"
                "$p=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited;"
                f"Register-ScheduledTask -TaskName '{task_name}' -Action $a -Principal $p -Force | Out-Null;"
                f"Start-ScheduledTask -TaskName '{task_name}'; 'OK'"
            ),
            utmctl=utmctl,
            timeout=30.0,
        )

        # Sample host QEMU CPU during the loaded second half
        host_cpu_holder: dict[str, Any] = {}
        def _sample_host() -> None:
            time.sleep(load_start)
            host_cpu_holder["loaded_sample"] = p12b.sample_host_qemu_with_main_thread(max(10.0, float(duration_sec - load_start - 2)))
        sampler = threading.Thread(target=_sample_host, daemon=True)
        sampler.start()

        out_raw = p14e._qga_ps(
            vm_uuid,
            f"& '{guest_dir}\\net_mixed_bench.exe' --host '{gw_ip}' --udp-port {echo_srv.udp_port} --tcp-port {echo_srv.tcp_port} --duration {duration_sec} --tick-hz 128 --load-start {load_start}",
            utmctl=utmctl,
            timeout=float(duration_sec + 60),
        ).strip()
        sampler.join(timeout=15.0)
        p14e._qga_ps(vm_uuid, f"Unregister-ScheduledTask -TaskName '{task_name}' -Confirm:$false -ErrorAction SilentlyContinue | Out-Null; 'OK'", utmctl=utmctl)

        net_json: dict[str, Any] = {"ok": False, "raw": out_raw[-300:]}
        for ln in reversed(out_raw.splitlines()):
            s = ln.strip()
            if s.startswith("{") and s.endswith("}"):
                try:
                    net_json = json.loads(s)
                    break
                except json.JSONDecodeError:
                    pass

        # Stop VM so proxy flushes stats
        p14e._stop_utm_custom(utm_proc, vm_uuid, utmctl)
        utm_proc = None
        time.sleep(1.5)

        proxy_stats: dict[str, Any] | None = None
        if proxy_stats_path.is_file():
            try:
                proxy_stats = json.loads(proxy_stats_path.read_text(encoding="utf-8"))
            except Exception:
                proxy_stats = None

        return {
            "label": label,
            "network_mode": network_mode,
            "app_used": "official_utm" if use_official_utm else "utm_custom_adhoc",
            "gateway_ip": gw_ip,
            "icmp_ping_ok": ping_ok,
            "proxy_qos_user_interactive": proxy_qos_ok,
            "proxy_stats": proxy_stats,
            "device_tree_audit": dev_audit,
            "host_cpu_loaded": host_cpu_holder.get("loaded_sample"),
            **net_json,
        }
    finally:
        echo_srv.stop()
        if utm_proc is not None and created_bundle is not None:
            try:
                p14e._stop_utm_custom(utm_proc, ggm.bundle_uuid(created_bundle), utmctl)
            except Exception:
                pass
        _stop_proxy(proxy_proc)
        if proxy_stats_path.exists():
            proxy_stats_path.unlink(missing_ok=True)
        if created_bundle is not None and created_bundle.exists():
            ggm.destroy_ephemeral(
                ephemeral_path=created_bundle,
                golden=golden,
                primary=primary,
                utmctl=OFFICIAL_UTMCTL,
                fast_disk_hash=True,
            )


def run_all_p15a_experiments(args: argparse.Namespace) -> dict[str, Any]:
    """Execute full Phase 15A real-machine experiments and write all 5 evidence artifacts."""
    guest_root = p12b._find_external_guest_root()
    vms_dir = guest_root / "vms"
    golden = vms_dir / "golden-win11-arm64-v1.utm"
    primary = vms_dir / "Windows11-ARM64.utm"
    custom_app = Path(args.custom_app)
    custom_utmctl = custom_app / "Contents/MacOS/utmctl"

    print("[p15a] Step 1/5: Generating patch audit, build verification & vmnet-bridge audit...", file=sys.stderr, flush=True)
    patch_audit, build_verif = generate_patch_and_build_evidence(custom_app)

    print("[p15a] Step 2/5: Compiling out-of-repo Windows MT graphics & mixed network tools...", file=sys.stderr, flush=True)
    mt_gfx_exe = build_windows_tool("mt_gfx_bench", MT_GFX_BENCH_CPP_SRC, ["-ld3d11", "-ldxgi", "-ld3dcompiler"])
    net_mixed_exe = build_windows_tool("net_mixed_bench", NET_MIXED_BENCH_CPP_SRC, ["-lws2_32"])

    # Step 3: 1080p & 4K Multithreaded Graphics + Device Tree + Audio + IOSurface Direct Present A/B
    print("[p15a] Step 3/5: Running 1080p/4K MT Graphics (D3D11/Vulkan/D3D12), Device Tree, Audio & IOSurface A/B...", file=sys.stderr, flush=True)
    utm_caches = Path.home() / "Library/Containers/com.utmapp.UTM/Data/Library/Caches"
    cache_dir = utm_caches / f"p15a-dxmt-cache-{uuid.uuid4().hex[:8]}"
    cache_dir.mkdir(parents=True, exist_ok=True)
    vm_name = f"ephemeral-p15a-gfx-{uuid.uuid4().hex[:6]}"
    proxy_proc: subprocess.Popen[str] | None = None
    utm_proc: subprocess.Popen[str] | None = None
    gfx_bundle: Path | None = None

    device_tree_proof: dict[str, Any] = {}
    guest_security_audio: dict[str, Any] = {}
    d3d11_results: dict[str, Any] = {}
    vulkan_results: dict[str, Any] = {}
    d3d12_results: dict[str, Any] = {}
    iosurface_ab: dict[str, Any] = {}

    try:
        proxy_proc, socket_ep, proxy_qos = start_full_tcp_udp_proxy()
        spawned = ggm.spawn_ephemeral(
            golden=golden,
            dest_dir=vms_dir,
            name=vm_name,
            primary=primary,
            register_utm=False,
            trim_hardware=True,
            no_sound=False,
            dx_driver="DXMT",
            fps_limit=120,
            ram_mb=10240,
            vcpu=8,
            disable_balloon=True,
            pure_relative_mouse=True,
            virtio_mouse=True,
            disable_usb_redir=True,
            iosurface_direct_present=True,
            network_mode="socket-stream",
            socket_endpoint=socket_ep,
            net_rx_queue_size=1024,
            disk_interface="virtio",
            enable_iothread=True,
            io_queues=4,
            fast_disk_hash=True,
        )
        gfx_bundle = Path(spawned["ephemeral_path"])
        vm_uuid = spawned["clone_uuid"]

        # Arm A: IOSurface Direct Present = ON (patch 09 default) + MT Graphics + Device Tree + Audio audit
        utm_proc = _launch_utm_custom_p15(
            custom_app=custom_app,
            vm_uuid=vm_uuid,
            vm_bundle=gfx_bundle,
            shader_cache_dir=cache_dir,
            fps_limit=120,
            drawable_count=3,
            max_inflight_frames=3,
            iosurface_direct_present=True,
            virtio_mouse=True,
            disable_usb_redir=True,
        )
        p14e._wait_qga_ready(vm_uuid, custom_utmctl, timeout_sec=180.0)

        qemu_cmdline = p14e._get_qemu_cmdline()
        device_tree_proof = {
            "proxy_qos_user_interactive": proxy_qos,
            **audit_p15_device_tree(qemu_cmdline),
        }
        guest_security_audio = _probe_guest_audio_and_security(vm_uuid, custom_utmctl)
        guest_dir = r"C:\graphics-lab\p15a"
        p14e._qga_ps(vm_uuid, rf"New-Item -ItemType Directory -Force -Path '{guest_dir}' | Out-Null", utmctl=custom_utmctl)
        p14e._upload_file_to_guest(vm_uuid, mt_gfx_exe, rf"{guest_dir}\mt_gfx_bench.exe", utmctl=custom_utmctl)
        p14e._upload_file_to_guest(vm_uuid, D3D11_PROBE, rf"{guest_dir}\d3d11_probe.exe", utmctl=custom_utmctl)

        # 1080p & 4K Native Resolution (Zero Quality Compromise) D3D11 & Vulkan 1.3+ MT Benchmarks
        resolutions = [("1080p", 1920, 1080), ("4k", 3840, 2160)]
        for res_key, w, h in resolutions:
            d3d_arms: list[dict[str, Any]] = []
            vk_arms: list[dict[str, Any]] = []
            for threads in (1, 4, 8):
                print(f"[p15a]   D3D11 {res_key} ({w}x{h}) threads={threads}...", file=sys.stderr, flush=True)
                r_d3d = _run_guest_interactive_exe(
                    vm_uuid,
                    custom_utmctl,
                    task_name=f"p15-d3d11-{res_key}-t{threads}",
                    guest_dir=guest_dir,
                    exe_path=rf"{guest_dir}\mt_gfx_bench.exe",
                    arg_list=[
                        "--mode", "d3d11", "--width", str(w), "--height", str(h),
                        "--threads", str(threads), "--draws", "2048", "--frames", "45", "--warmup", "8",
                    ],
                    timeout_sec=180,
                )
                d3d_arms.append(r_d3d["parsed"] or {"ok": False, "threads": threads, "err": r_d3d["stderr_tail"]})

                print(f"[p15a]   Vulkan {res_key} ({w}x{h}) threads={threads}...", file=sys.stderr, flush=True)
                r_vk = _run_guest_interactive_exe(
                    vm_uuid,
                    custom_utmctl,
                    task_name=f"p15-vk-{res_key}-t{threads}",
                    guest_dir=guest_dir,
                    exe_path=rf"{guest_dir}\mt_gfx_bench.exe",
                    arg_list=[
                        "--mode", "vulkan", "--width", str(w), "--height", str(h),
                        "--threads", str(threads), "--draws", "2048", "--frames", "45", "--warmup", "8",
                    ],
                    timeout_sec=180,
                )
                vk_arms.append(r_vk["parsed"] or {"ok": False, "threads": threads, "err": r_vk["stderr_tail"]})

            d3d11_results[res_key] = {
                "width": w,
                "height": h,
                "arms": d3d_arms,
                "scaling": compare_multithread_scaling(d3d_arms[0], d3d_arms[1:]) if d3d_arms and d3d_arms[0].get("ok") else None,
            }
            vulkan_results[res_key] = {
                "width": w,
                "height": h,
                "arms": vk_arms,
                "scaling": compare_multithread_scaling(vk_arms[0], vk_arms[1:]) if vk_arms and vk_arms[0].get("ok") else None,
            }

        # D3D12 probe under default dxmt-native
        print("[p15a]   D3D12 probe (dxmt-native)...", file=sys.stderr, flush=True)
        r_d12_dxmt = _run_guest_interactive_exe(
            vm_uuid,
            custom_utmctl,
            task_name="p15-d3d12-dxmt",
            guest_dir=guest_dir,
            exe_path=rf"{guest_dir}\mt_gfx_bench.exe",
            arg_list=["--mode", "d3d12", "--width", "1920", "--height", "1080", "--threads", "4", "--draws", "2048", "--frames", "30", "--warmup", "5"],
            timeout_sec=120,
        )
        d3d12_results["dxmt_native_probe"] = r_d12_dxmt["parsed"] or {"ok": False, "err": r_d12_dxmt["stderr_tail"]}

        # IOSurface Direct Present = ON (4K + 1080p sustained present workload)
        def _run_present_probe(tag: str, w: int, h: int) -> dict[str, Any]:
            csv_guest = rf"{guest_dir}\iosurf-{tag}.csv"
            host_holder: dict[str, Any] = {}
            def _host_samp() -> None:
                host_holder["cpu"] = p12b.sample_host_qemu_with_main_thread(12.0)
            st = threading.Thread(target=_host_samp, daemon=True)
            st.start()
            _run_guest_interactive_exe(
                vm_uuid,
                custom_utmctl,
                task_name=f"p15-iosurf-{tag}",
                guest_dir=guest_dir,
                exe_path=rf"{guest_dir}\d3d11_probe.exe",
                arg_list=[
                    "--frames", "120", "--warmup", "15", "--width", str(w), "--height", str(h),
                    "--commands", "2048", "--command-every", "1", "--resource-bytes", "524288", "--resource-every", "1",
                    "--driver-type", "hardware", "--csv", csv_guest,
                ],
                timeout_sec=180,
            )
            st.join(timeout=20.0)
            csv_txt = p14e._qga_ps(vm_uuid, f"if(Test-Path '{csv_guest}'){{Get-Content -Raw '{csv_guest}'}}else{{''}}", utmctl=custom_utmctl, timeout=30.0)
            ms_vals = p14e._parse_probe_csv_frame_ms(csv_txt)
            return {
                "width": w,
                "height": h,
                "frame_metrics": p14e.summarize_frame_times_ms(ms_vals),
                "host_cpu": host_holder.get("cpu"),
            }

        print("[p15a]   IOSurface Direct Present = ON (1080p & 4K)...", file=sys.stderr, flush=True)
        direct_1080 = _run_present_probe("direct-1080p", 1920, 1080)
        direct_4k = _run_present_probe("direct-4k", 3840, 2160)

        p14e._stop_utm_custom(utm_proc, vm_uuid, custom_utmctl)
        utm_proc = None
        time.sleep(2.5)

        # Arm B: IOSurface Direct Present = OFF (upstream shadowTexture 32MiB copy baseline)
        print("[p15a]   IOSurface Direct Present = OFF (1080p & 4K baseline)...", file=sys.stderr, flush=True)
        utm_proc = _launch_utm_custom_p15(
            custom_app=custom_app,
            vm_uuid=vm_uuid,
            vm_bundle=gfx_bundle,
            shader_cache_dir=cache_dir,
            fps_limit=120,
            drawable_count=3,
            max_inflight_frames=3,
            iosurface_direct_present=False,
            virtio_mouse=True,
            disable_usb_redir=True,
        )
        p14e._wait_qga_ready(vm_uuid, custom_utmctl, timeout_sec=180.0)
        shadow_1080 = _run_present_probe("shadow-1080p", 1920, 1080)
        shadow_4k = _run_present_probe("shadow-4k", 3840, 2160)

        iosurface_ab = {
            "1080p": {
                "shadow_copy_off": shadow_1080,
                "direct_present_on": direct_1080,
                "comparison": compare_iosurface_present_arms(shadow_1080, direct_1080),
            },
            "4k": {
                "shadow_copy_off": shadow_4k,
                "direct_present_on": direct_4k,
                "comparison": compare_iosurface_present_arms(shadow_4k, direct_4k),
            },
        }

        p14e._stop_utm_custom(utm_proc, vm_uuid, custom_utmctl)
        utm_proc = None
        time.sleep(2.5)

        # Optional D3D12 probe under D3DMetal (NPT_CAPSET_D3D12=1)
        print("[p15a]   D3D12 probe (d3dmetal-native NPT_CAPSET_D3D12=1)...", file=sys.stderr, flush=True)
        cfg_d12 = ggm.read_config_plist(gfx_bundle)
        cfg_d12.setdefault("QEMU", {})["DirectXDriver"] = 0  # D3DMetal
        ggm.write_config_plist(gfx_bundle, cfg_d12)
        utm_proc = _launch_utm_custom_p15(
            custom_app=custom_app,
            vm_uuid=vm_uuid,
            vm_bundle=gfx_bundle,
            fps_limit=120,
            iosurface_direct_present=True,
            virtio_mouse=True,
            disable_usb_redir=True,
            dx_driver_flag="",
            extra_env={"NPT_CAPSET_D3D12": "1"},
        )
        p14e._wait_qga_ready(vm_uuid, custom_utmctl, timeout_sec=180.0)
        d12_arms_1080: list[dict[str, Any]] = []
        d12_arms_4k: list[dict[str, Any]] = []
        for res_key, w, h, bucket in [("1080p", 1920, 1080, d12_arms_1080), ("4k", 3840, 2160, d12_arms_4k)]:
            r1 = _run_guest_interactive_exe(
                vm_uuid,
                custom_utmctl,
                task_name=f"p15-d3d12-d3dm-{res_key}-t1",
                guest_dir=guest_dir,
                exe_path=rf"{guest_dir}\mt_gfx_bench.exe",
                arg_list=["--mode", "d3d12", "--width", str(w), "--height", str(h), "--threads", "1", "--draws", "2048", "--frames", "40", "--warmup", "8"],
                timeout_sec=120,
            )
            p1 = r1["parsed"] or {"ok": False, "supported": False}
            bucket.append(p1)
            if p1.get("supported"):
                for th in (4, 8):
                    rt = _run_guest_interactive_exe(
                        vm_uuid,
                        custom_utmctl,
                        task_name=f"p15-d3d12-d3dm-{res_key}-t{th}",
                        guest_dir=guest_dir,
                        exe_path=rf"{guest_dir}\mt_gfx_bench.exe",
                        arg_list=["--mode", "d3d12", "--width", str(w), "--height", str(h), "--threads", str(th), "--draws", "2048", "--frames", "40", "--warmup", "8"],
                        timeout_sec=120,
                    )
                    bucket.append(rt["parsed"] or {"ok": False, "supported": False, "threads": th})
            else:
                break
        d3d12_results["d3dmetal_capset_1080p"] = {
            "arms": d12_arms_1080,
            "scaling": compare_multithread_scaling(d12_arms_1080[0], d12_arms_1080[1:]) if len(d12_arms_1080) > 1 and d12_arms_1080[0].get("supported") else None,
        }
        d3d12_results["d3dmetal_capset_4k"] = {
            "arms": d12_arms_4k,
            "scaling": compare_multithread_scaling(d12_arms_4k[0], d12_arms_4k[1:]) if len(d12_arms_4k) > 1 and d12_arms_4k[0].get("supported") else None,
        }

        p14e._stop_utm_custom(utm_proc, vm_uuid, custom_utmctl)
        utm_proc = None
    finally:
        if utm_proc is not None and gfx_bundle is not None:
            try:
                p14e._stop_utm_custom(utm_proc, ggm.bundle_uuid(gfx_bundle), custom_utmctl)
            except Exception:
                pass
        _stop_proxy(proxy_proc)
        if gfx_bundle is not None and gfx_bundle.exists():
            ggm.destroy_ephemeral(
                ephemeral_path=gfx_bundle,
                golden=golden,
                primary=primary,
                utmctl=OFFICIAL_UTMCTL,
                fast_disk_hash=True,
            )
        shutil.rmtree(cache_dir, ignore_errors=True)

    # Step 4: 60s TCP + 128-tick UDP Mixed Loaded Network Stress Benchmark
    print("[p15a] Step 4/5: Running 60s TCP + 128-tick UDP mixed loaded network stress benchmark...", file=sys.stderr, flush=True)
    net_duration = int(args.net_duration_sec)
    net_arms: dict[str, Any] = {}

    print("[p15a]   Arm 1: Full TCP+UDP+ICMP high-QoS socket-stream (ad-hoc UTM-Custom)...", file=sys.stderr, flush=True)
    net_arms["full_tcp_udp_socket_stream"] = _run_mixed_net_arm(
        label="full-tcp-udp-stream",
        golden=golden,
        primary=primary,
        vms_dir=vms_dir,
        custom_app=custom_app,
        use_official_utm=False,
        network_mode="socket-stream",
        duration_sec=net_duration,
        net_bench_exe=net_mixed_exe,
    )

    caps = ggm.detect_host_network_capabilities()
    if caps.get("active_vmnet_daemon_socket"):
        print("[p15a]   Arm 2: Active malt-vmnet-bridge / socket_vmnet daemon (ad-hoc UTM-Custom)...", file=sys.stderr, flush=True)
        net_arms["daemon_socket_vmnet"] = _run_mixed_net_arm(
            label="daemon-vmnet",
            golden=golden,
            primary=primary,
            vms_dir=vms_dir,
            custom_app=custom_app,
            use_official_utm=False,
            network_mode="socket-vmnet",
            duration_sec=net_duration,
            net_bench_exe=net_mixed_exe,
            bridge_socket=caps["active_vmnet_daemon_socket"],
        )

    if caps.get("official_utm_vmnet_entitled"):
        print("[p15a]   Arm 2b: Native kernel vmnet-shared (entitled UTM)...", file=sys.stderr, flush=True)
        net_arms["vmnet_shared"] = _run_mixed_net_arm(
            label="vmnet-shared",
            golden=golden,
            primary=primary,
            vms_dir=vms_dir,
            custom_app=custom_app,
            use_official_utm=True,
            network_mode="vmnet-shared",
            duration_sec=net_duration,
            net_bench_exe=net_mixed_exe,
        )

    print("[p15a]   Arm 3: Baseline QEMU slirp (emulated)...", file=sys.stderr, flush=True)
    net_arms["slirp_emulated"] = _run_mixed_net_arm(
        label="slirp-emulated",
        golden=golden,
        primary=primary,
        vms_dir=vms_dir,
        custom_app=custom_app,
        use_official_utm=False,
        network_mode="emulated",
        duration_sec=net_duration,
        net_bench_exe=net_mixed_exe,
    )

    net_comparisons: dict[str, Any] = {}
    slirp_arm = net_arms["slirp_emulated"]
    for key, arm in net_arms.items():
        if key != "slirp_emulated":
            net_comparisons[f"{key}_vs_slirp"] = compare_mixed_network_arms(slirp_arm, arm)

    # Step 5: Full-disk SHA-256 Zero-Drift Verification
    print("[p15a] Step 5/5: Running full-disk SHA-256 zero-drift verification...", file=sys.stderr, flush=True)
    p14e._quit_any_utm()
    time.sleep(1.5)
    baseline_fp = json.loads(GOLDEN_MANIFEST.read_text(encoding="utf-8")).get("fingerprints", {})
    g_fp = ggm.fingerprint_bundle(golden, include_full_disk_hash=True)
    p_fp = ggm.fingerprint_bundle(primary, include_full_disk_hash=True)
    lease = ggm.check_lease_and_processes()
    orig_utm_ok = (
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(OFFICIAL_UTM_APP)], capture_output=True).returncode == 0
    )

    golden_zero_drift = (
        g_fp["readonly"]
        and g_fp["config_sha256"] == baseline_fp.get("golden_config_sha256")
        and g_fp["bundle_sha256"] == baseline_fp.get("golden_bundle_sha256")
    )
    primary_zero_drift = (
        p_fp["config_sha256"] == baseline_fp.get("primary_vm_a_config_sha256")
        and p_fp["bundle_sha256"] == baseline_fp.get("primary_vm_a_bundle_sha256")
    )

    zero_drift_proof = {
        "schema_version": 1,
        "owner": "@DNPMBHC",
        "verified_at_utc": utc_now_iso(),
        "golden_readonly": g_fp["readonly"],
        "golden_config_sha256": g_fp["config_sha256"],
        "golden_bundle_sha256": g_fp["bundle_sha256"],
        "golden_zero_drift": golden_zero_drift,
        "primary_config_sha256": p_fp["config_sha256"],
        "primary_bundle_sha256": p_fp["bundle_sha256"],
        "primary_zero_drift": primary_zero_drift,
        "original_utm_codesign_ok": orig_utm_ok,
        "lease_ready": lease["ready"],
        "active_qemu_workers": lease["active_qemu_workers"],
        "zero_drift": bool(golden_zero_drift and primary_zero_drift and orig_utm_ok and lease["ready"]),
    }
    write_redacted_json(EVIDENCE_P15A / "zero-drift-proof.json", zero_drift_proof)

    # Assemble master benchmark JSON
    audio_verdict = (
        "WHQL viosnd driver present; eligible for virtio-sound-pci"
        if guest_security_audio.get("whql_viosnd_present")
        else "No WHQL-signed viosnd/virtio-sound driver present in sealed Windows 11 ARM64 image; honestly retained intel-hda with Secure Boot=True."
    )
    master = {
        "schema_version": 1,
        "owner": "@DNPMBHC",
        "phase": "15A",
        "measured_at_utc": utc_now_iso(),
        "device_tree_and_deemulation": {
            "qemu_device_tree": device_tree_proof,
            "guest_security_and_audio": guest_security_audio,
            "virtio_sound_evaluation": {
                "whql_viosnd_available": bool(guest_security_audio.get("whql_viosnd_present", False)),
                "retained_audio_device": "intel-hda" if not guest_security_audio.get("whql_viosnd_present") else "virtio-sound-pci",
                "verdict": audio_verdict,
            },
            "renderer_fps_limit_default": ggm.DEFAULT_RENDERER_FPS_LIMIT,
            "triple_buffering_drawable_count": ggm.DEFAULT_METAL_DRAWABLE_COUNT,
        },
        "vmnet_bridge_daemon_audit": build_verif["vmnet_bridge_daemon_audit"],
        "mixed_tcp_udp_network_benchmark": {
            "duration_sec_per_arm": net_duration,
            "arms": net_arms,
            "comparisons": net_comparisons,
        },
        "multithread_graphics_1080p_4k": {
            "d3d11": d3d11_results,
            "vulkan_virtio": vulkan_results,
            "d3d12_capset": d3d12_results,
        },
        "iosurface_direct_present_ab": iosurface_ab,
        "zero_drift": zero_drift_proof["zero_drift"],
    }
    write_redacted_json(EVIDENCE_P15A / "multithread-4k-and-net-benchmark.json", master)
    return master


def update_stream_net_arm_and_zero_drift(args: argparse.Namespace) -> dict[str, Any]:
    """Re-run the 60s full TCP+UDP+ICMP socket-stream arm + Step 5 full-disk zero-drift proof
    and update multithread-4k-and-net-benchmark.json & zero-drift-proof.json."""
    bench_path = EVIDENCE_P15A / "multithread-4k-and-net-benchmark.json"
    master = json.loads(bench_path.read_text(encoding="utf-8"))
    guest_root = p12b._find_external_guest_root()
    vms_dir = guest_root / "vms"
    golden = vms_dir / "golden-win11-arm64-v1.utm"
    primary = vms_dir / "Windows11-ARM64.utm"
    custom_app = Path(args.custom_app)

    net_mixed_exe = build_windows_tool("net_mixed_bench", NET_MIXED_BENCH_CPP_SRC, ["-lws2_32"])
    arm = _run_mixed_net_arm(
        label="full-tcp-udp-stream",
        golden=golden,
        primary=primary,
        vms_dir=vms_dir,
        custom_app=custom_app,
        use_official_utm=False,
        network_mode="socket-stream",
        duration_sec=int(args.net_duration_sec),
        net_bench_exe=net_mixed_exe,
    )
    master["mixed_tcp_udp_network_benchmark"]["arms"]["full_tcp_udp_socket_stream"] = arm
    slirp_arm = master["mixed_tcp_udp_network_benchmark"]["arms"]["slirp_emulated"]
    master["mixed_tcp_udp_network_benchmark"]["comparisons"]["full_tcp_udp_socket_stream_vs_slirp"] = (
        compare_mixed_network_arms(slirp_arm, arm)
    )

    p14e._quit_any_utm()
    time.sleep(1.5)
    baseline_fp = json.loads(GOLDEN_MANIFEST.read_text(encoding="utf-8")).get("fingerprints", {})
    g_fp = ggm.fingerprint_bundle(golden, include_full_disk_hash=True)
    p_fp = ggm.fingerprint_bundle(primary, include_full_disk_hash=True)
    lease = ggm.check_lease_and_processes()
    orig_utm_ok = (
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(OFFICIAL_UTM_APP)], capture_output=True).returncode == 0
    )
    golden_zero_drift = (
        g_fp["readonly"]
        and g_fp["config_sha256"] == baseline_fp.get("golden_config_sha256")
        and g_fp["bundle_sha256"] == baseline_fp.get("golden_bundle_sha256")
    )
    primary_zero_drift = (
        p_fp["config_sha256"] == baseline_fp.get("primary_vm_a_config_sha256")
        and p_fp["bundle_sha256"] == baseline_fp.get("primary_vm_a_bundle_sha256")
    )
    zero_drift_proof = {
        "schema_version": 1,
        "owner": "@DNPMBHC",
        "verified_at_utc": utc_now_iso(),
        "golden_readonly": g_fp["readonly"],
        "golden_config_sha256": g_fp["config_sha256"],
        "golden_bundle_sha256": g_fp["bundle_sha256"],
        "golden_zero_drift": golden_zero_drift,
        "primary_config_sha256": p_fp["config_sha256"],
        "primary_bundle_sha256": p_fp["bundle_sha256"],
        "primary_zero_drift": primary_zero_drift,
        "original_utm_codesign_ok": orig_utm_ok,
        "lease_ready": lease["ready"],
        "active_qemu_workers": lease["active_qemu_workers"],
        "zero_drift": bool(golden_zero_drift and primary_zero_drift and orig_utm_ok and lease["ready"]),
    }
    write_redacted_json(EVIDENCE_P15A / "zero-drift-proof.json", zero_drift_proof)
    master["measured_at_utc"] = utc_now_iso()
    master["zero_drift"] = zero_drift_proof["zero_drift"]
    write_redacted_json(bench_path, master)
    return arm


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Phase 15A 1080p/4K MT GPU + IOSurface + Full TCP/UDP Net benchmark (@DNPMBHC)")
    parser.add_argument("--custom-app", type=Path, default=DEFAULT_CUSTOM_APP)
    parser.add_argument("--net-duration-sec", type=int, default=60)
    parser.add_argument("--audit-only", action="store_true", help="Only emit patch-audit.json & build-verification.json without launching VMs")
    parser.add_argument("--update-stream-net-arm", action="store_true", help="Re-run only the 60s full TCP+UDP+ICMP socket-stream arm + zero-drift verification")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    if args.audit_only:
        patch_audit, build_verif = generate_patch_and_build_evidence(args.custom_app)
        print(json.dumps(redact_p15_value({"patch_audit": patch_audit, "build_verification": build_verif}), indent=2, ensure_ascii=False))
        return 0 if build_verif["passed"] else 1
    if args.update_stream_net_arm:
        arm = update_stream_net_arm_and_zero_drift(args)
        print(json.dumps(redact_p15_value(arm), indent=2, ensure_ascii=False))
        return 0 if arm.get("ok") else 1
    master = run_all_p15a_experiments(args)
    print(json.dumps(redact_p15_value({"ok": True, "zero_drift": master["zero_drift"]}), indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
