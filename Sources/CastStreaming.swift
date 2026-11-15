// Cast Streaming sender: AES-CTR encrypted frames split into Cast RTP
// packets, RTCP sender reports, and handling of the receiver's feedback
// (ACK checkpoint, NACK retransmission, picture loss -> key frame).

import CommonCrypto
import Foundation
import Network
import QuartzCore

struct StreamConfig {
    let index: Int
    let ssrc: UInt32
    let payloadType: UInt8
    let clockRate: Double
    let aesKey: [UInt8]
    let aesIvMask: [UInt8]

    static func make(index: Int, ssrc: UInt32, payloadType: UInt8, clockRate: Double) -> StreamConfig {
        StreamConfig(index: index, ssrc: ssrc, payloadType: payloadType, clockRate: clockRate,
                     aesKey: randomBytes(16), aesIvMask: randomBytes(16))
    }
}

/// Maps host time (CACurrentMediaTime / CMClock host time) to RTP and NTP time.
struct MediaClock {
    let host0 = CACurrentMediaTime()
    let wall0 = Date().timeIntervalSince1970
    let rtpBase = UInt32.random(in: 0 ... UInt32.max)

    func rtp(_ t: Double, rate: Double) -> UInt32 {
        let ticks = Int64(((t - host0) * rate).rounded())
        return UInt32(truncatingIfNeeded: Int64(rtpBase) &+ ticks)
    }

    func ntp(_ t: Double) -> (UInt32, UInt32) {
        let s = wall0 + (t - host0) + 2_208_988_800
        let sec = s.rounded(.down)
        return (UInt32(sec), UInt32(min((s - sec) * 4_294_967_296.0, 4_294_967_295.0)))
    }
}

final class UDPTransport {
    var onPacket: ((Data) -> Void)?
    private let connection: NWConnection

    init(host: NWEndpoint.Host, port: UInt16, queue: DispatchQueue) {
        let params = NWParameters.udp
        params.serviceClass = .interactiveVideo
        connection = NWConnection(host: host, port: NWEndpoint.Port(rawValue: port)!, using: params)
        connection.stateUpdateHandler = { state in
            if case .failed(let e) = state { log("udp failed: \(e)") }
        }
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, _, _, error in
            if let data, !data.isEmpty { self?.onPacket?(data) }
            if error == nil { self?.receive() }
        }
    }

    func send(_ packets: [Data]) {
        guard !packets.isEmpty else { return }
        connection.batch {
            for p in packets { connection.send(content: p, completion: .idempotent) }
        }
    }

    func close() { connection.cancel() }
}

final class CastRTPStream {
    let config: StreamConfig
    let receiverSSRC: UInt32
    var onKeyFrameRequest: (() -> Void)?

    private let transport: UDPTransport
    private static let maxPayload = 1200
    private let historyDepth: Int64

    private var nextFrameId: Int64 = 0
    private var sequence = UInt16.random(in: 0 ... .max)
    private var history: [Int64: [Data]] = [:]
    private var lastResend: [Int64: Double] = [:]
    private var lastKeyRequest: Double = 0
    private var packetCount: UInt32 = 0
    private var octetCount: UInt32 = 0

    // Stats
    private(set) var checkpoint: Int64 = -1
    private(set) var retransmits = 0
    private(set) var keyFrameRequests = 0
    var framesSent: Int64 { nextFrameId }

    init(config: StreamConfig, receiverSSRC: UInt32, transport: UDPTransport) {
        self.config = config
        self.receiverSSRC = receiverSSRC
        self.transport = transport
        historyDepth = config.clockRate == 90000 ? 150 : 200
    }

    func sendFrame(_ frame: Data, rtpTimestamp: UInt32, keyFrame: Bool) {
        let frameId = nextFrameId
        nextFrameId += 1
        let payload = encrypt(frame, frameId: frameId)

        var chunks: [Data] = []
        var offset = 0
        repeat {
            let end = min(offset + Self.maxPayload, payload.count)
            chunks.append(payload.subdata(in: offset..<end))
            offset = end
        } while offset < payload.count

        let maxPid = UInt16(chunks.count - 1)
        let referenced = keyFrame ? frameId : frameId - 1
        var packets: [Data] = []
        packets.reserveCapacity(chunks.count)
        for (pid, chunk) in chunks.enumerated() {
            var p = Data(capacity: 19 + chunk.count)
            p.append(0x80)                                                  // V=2
            p.append((UInt16(pid) == maxPid ? 0x80 : 0) | config.payloadType) // M, PT
            p.appendBE16(sequence); sequence &+= 1
            p.appendBE32(rtpTimestamp)
            p.appendBE32(config.ssrc)
            p.append((keyFrame ? 0x80 : 0) | 0x40)                          // K, R, no extensions
            p.append(UInt8(truncatingIfNeeded: frameId))
            p.appendBE16(UInt16(pid))
            p.appendBE16(maxPid)
            p.append(UInt8(truncatingIfNeeded: referenced))
            p.append(chunk)
            packets.append(p)
        }
        history[frameId] = packets
        history[frameId - historyDepth] = nil
        packetCount &+= UInt32(packets.count)
        octetCount &+= UInt32(payload.count)
        transport.send(packets)

        // Receiver stuck far behind (lost frame it can't recover): restart from a key frame.
        if config.clockRate == 90000, frameId - checkpoint > 45 { requestKeyFrame() }
    }

    func senderReport(clock: MediaClock) -> Data {
        let now = CACurrentMediaTime()
        let (sec, frac) = clock.ntp(now)
        var p = Data(capacity: 28)
        p.append(0x80); p.append(200); p.appendBE16(6)
        p.appendBE32(config.ssrc)
        p.appendBE32(sec); p.appendBE32(frac)
        p.appendBE32(clock.rtp(now, rate: config.clockRate))
        p.appendBE32(packetCount)
        p.appendBE32(octetCount)
        return p
    }

    func pictureLoss() {
        requestKeyFrame()
    }

    func feedback(checkpoint ck: UInt8, losses: [(UInt8, UInt16, UInt8)]) {
        let acked = expand(ck)
        if acked > checkpoint { checkpoint = acked }
        let now = CACurrentMediaTime()
        var resend: [Data] = []
        for (f8, pid, mask) in losses {
            let frameId = expand(f8)
            guard let packets = history[frameId] else {
                if frameId > checkpoint { requestKeyFrame() }
                continue
            }
            var pids: [Int]
            if pid == 0xFFFF {
                pids = Array(packets.indices)
            } else {
                pids = [Int(pid)]
                for bit in 0..<8 where mask & (1 << bit) != 0 { pids.append(Int(pid) + bit + 1) }
            }
            for p in pids where p < packets.count {
                let key = frameId << 16 | Int64(p)
                if now - (lastResend[key] ?? 0) > 0.04 {
                    lastResend[key] = now
                    resend.append(packets[p])
                }
            }
        }
        if lastResend.count > 4000 { lastResend = lastResend.filter { now - $0.value < 1 } }
        retransmits += resend.count
        transport.send(resend)
    }

    private func requestKeyFrame() {
        let now = CACurrentMediaTime()
        guard now - lastKeyRequest > 1 else { return }
        lastKeyRequest = now
        keyFrameRequests += 1
        onKeyFrameRequest?()
    }

    /// Expands an 8-bit truncated frame id to the closest id already sent.
    private func expand(_ v: UInt8) -> Int64 {
        let latest = nextFrameId - 1
        var c = (latest & ~0xff) | Int64(v)
        if c > latest { c -= 256 }
        return c
    }

    private func encrypt(_ data: Data, frameId: Int64) -> Data {
        var iv = [UInt8](repeating: 0, count: 16)
        let fid = UInt32(truncatingIfNeeded: frameId)
        iv[8] = UInt8(fid >> 24); iv[9] = UInt8((fid >> 16) & 0xff)
        iv[10] = UInt8((fid >> 8) & 0xff); iv[11] = UInt8(fid & 0xff)
        for i in 0..<16 { iv[i] ^= config.aesIvMask[i] }

        var cryptor: CCCryptorRef?
        let status = CCCryptorCreateWithMode(
            CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
            CCPadding(ccNoPadding), iv, config.aesKey, 16, nil, 0, 0,
            CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
        guard status == kCCSuccess, let cryptor else { return data }
        defer { CCCryptorRelease(cryptor) }
        var out = Data(count: data.count)
        var moved = 0
        out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { i in
                _ = CCCryptorUpdate(cryptor, i.baseAddress, data.count, o.baseAddress, data.count, &moved)
            }
        }
        return out
    }
}

/// Parses a compound RTCP packet from the receiver and routes it to the streams.
func handleRTCP(_ data: Data, streams: [CastRTPStream]) {
    let b = [UInt8](data)
    var off = 0
    while off + 4 <= b.count {
        let fmt = b[off] & 0x1f
        let pt = b[off + 1]
        let length = (Int(readBE16(b, off + 2)) + 1) * 4
        guard b[off] >> 6 == 2, off + length <= b.count else { return }
        if pt == 206, length >= 12 {
            let media = readBE32(b, off + 8)
            if let stream = streams.first(where: { $0.config.ssrc == media }) {
                if fmt == 1 {
                    stream.pictureLoss()
                } else if fmt == 15, length >= 20, b[off + 12 ..< off + 16].elementsEqual(Array("CAST".utf8)) {
                    let count = Int(b[off + 17])
                    var losses: [(UInt8, UInt16, UInt8)] = []
                    for i in 0..<count {
                        let o = off + 20 + 4 * i
                        guard o + 4 <= off + length else { break }
                        losses.append((b[o], readBE16(b, o + 1), b[o + 3]))
                    }
                    stream.feedback(checkpoint: b[off + 16], losses: losses)
                }
            }
        }
        off += length
    }
}
