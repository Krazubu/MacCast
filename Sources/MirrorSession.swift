// One mirroring session: connect, launch the Cast mirroring receiver app,
// negotiate streams (OFFER/ANSWER), then capture, encode and send.

import AVFoundation
import CoreGraphics
import Foundation
import IOKit.pwr_mgt
import Network
import QuartzCore

struct MirrorOptions {
    var displayID: CGDirectDisplayID = CGMainDisplayID()
    var maxHeight = 1080
    var fps = 30
    var audio = true
    var targetDelayMs = 400
    var testPattern = false

    var videoBitrate: Int { maxHeight >= 1080 ? 6_000_000 : 3_500_000 }
}

final class MirrorSession {
    /// Cast "audio + video mirroring" receiver application (what Chrome uses for tab/desktop casting).
    static let mirroringAppId = "0F5096E8"

    enum Phase: Equatable {
        case connecting, launching, negotiating, streaming
        case ended(String?)
    }

    var onPhase: ((Phase) -> Void)?
    let device: CastDevice
    let options: MirrorOptions

    private let queue = DispatchQueue(label: "cast.session", qos: .userInteractive)
    private var phase: Phase = .connecting
    private var channel: CastChannel?
    private var transportId: String?
    private var appSessionId: String?
    private var requestId = 0
    private var audioConfig: StreamConfig?
    private var videoConfig: StreamConfig?
    private var udp: UDPTransport?
    private var audioStream: CastRTPStream?
    private var videoStream: CastRTPStream?
    private var clock = MediaClock()
    private var source: MediaSource?
    private var videoEncoder: VideoEncoder?
    private var audioEncoder: AudioEncoder?
    private var timers: [DispatchSourceTimer] = []
    private let size: (Int, Int)
    /// Keeps the display (and so the Mac) from idling to sleep while casting:
    /// a sleeping display stops ScreenCaptureKit and ends the cast.
    private var awakeAssertion: IOPMAssertionID = 0

    init(device: CastDevice, options: MirrorOptions) {
        self.device = device
        self.options = options
        if options.testPattern {
            size = options.maxHeight >= 1080 ? (1920, 1080) : (1280, 720)
        } else {
            size = videoSize(forDisplay: options.displayID, maxHeight: options.maxHeight)
        }
    }

    func start() { queue.async { self.connect() } }
    func stop() { queue.async { self.finish(nil) } }

    // MARK: Control channel

    private func connect() {
        set(.connecting)
        let reason = L("Cast Mirror is casting to %@", device.name) as CFString
        if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                       IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &awakeAssertion) != kIOReturnSuccess {
            awakeAssertion = 0
        }
        log("connecting to \(device.name) (\(device.model)) \(device.endpoint)")
        let ch = CastChannel(endpoint: device.endpoint, queue: queue)
        ch.onReady = { [weak self] in self?.channelReady() }
        ch.onMessage = { [weak self] m, json in self?.handle(m, json) }
        ch.onClose = { [weak self] reason in self?.finish(reason ?? L("Connection closed")) }
        channel = ch
        ch.start()
        after(20) { [weak self] in
            guard let self, self.phase != .streaming else { return }
            self.finish(L("The device is not responding"))
        }
    }

    private func channelReady() {
        guard let ch = channel else { return }
        log("connected, remote \(ch.remoteHost.map { "\($0)" } ?? "?")")
        ch.send(CastNamespace.connection, ["type": "CONNECT"])
        set(.launching)
        requestId += 1
        ch.send(CastNamespace.receiver, ["type": "LAUNCH", "requestId": requestId, "appId": Self.mirroringAppId])
    }

    private func handle(_ m: CastMessage, _ json: [String: Any]) {
        let type = json["type"] as? String ?? ""
        if m.namespace != CastNamespace.receiver || type != "RECEIVER_STATUS" {
            log("<- \(m.source) \(m.namespace.split(separator: ".").last ?? "") \(m.payload.prefix(600))")
        }
        switch (m.namespace, type) {
        case (CastNamespace.receiver, "RECEIVER_STATUS"):
            receiverStatus(json)
        case (CastNamespace.receiver, "LAUNCH_ERROR"), (CastNamespace.receiver, "INVALID_REQUEST"):
            finish(L("The device refuses screen mirroring (%@)", json["reason"] as? String ?? type))
        case (CastNamespace.webrtc, "ANSWER"):
            answer(json)
        case (CastNamespace.connection, "CLOSE"):
            if m.source == transportId { finish(L("Cast closed by the device")) }
        default:
            break
        }
    }

    private func receiverStatus(_ json: [String: Any]) {
        let apps = ((json["status"] as? [String: Any])?["applications"] as? [[String: Any]]) ?? []
        let app = apps.first { $0["appId"] as? String == Self.mirroringAppId }
        guard let app, let tid = app["transportId"] as? String else {
            if transportId != nil { finish(L("Cast stopped on the device")) }
            return
        }
        guard tid != transportId else { return }
        if phase == .streaming { finish(L("Cast replaced on the device")); return }
        log("mirroring app running, transport \(tid)")
        transportId = tid
        appSessionId = app["sessionId"] as? String
        channel?.send(CastNamespace.connection, ["type": "CONNECT"], to: tid)
        sendOffer(to: tid)
    }

    private func sendOffer(to tid: String) {
        let a = StreamConfig.make(index: 0, ssrc: UInt32.random(in: 1 ..< 500_000), payloadType: 96, clockRate: 48000)
        let v = StreamConfig.make(index: 1, ssrc: UInt32.random(in: 500_000 ..< 1_000_000), payloadType: 101, clockRate: 90000)
        audioConfig = a
        videoConfig = v
        var streams: [[String: Any]] = []
        if options.audio {
            streams.append([
                "index": a.index, "type": "audio_source", "codecName": "opus", "rtpProfile": "cast",
                "rtpPayloadType": Int(a.payloadType), "ssrc": Int(a.ssrc), "targetDelay": options.targetDelayMs,
                "aesKey": hex(a.aesKey), "aesIvMask": hex(a.aesIvMask), "receiverRtcpEventLog": false,
                "bitRate": 128_000, "sampleRate": 48000, "timeBase": "1/48000", "channels": 2,
            ])
        }
        streams.append([
            "index": v.index, "type": "video_source", "codecName": "h264", "rtpProfile": "cast",
            "rtpPayloadType": Int(v.payloadType), "ssrc": Int(v.ssrc), "targetDelay": options.targetDelayMs,
            "aesKey": hex(v.aesKey), "aesIvMask": hex(v.aesIvMask), "receiverRtcpEventLog": false,
            "timeBase": "1/90000", "maxFrameRate": "\(options.fps * 1000)/1000",
            "maxBitRate": options.videoBitrate, "profile": "main", "level": "4",
            "resolutions": [["width": size.0, "height": size.1]], "errorRecoveryMode": "castv2",
        ])
        requestId += 1
        channel?.send(CastNamespace.webrtc, [
            "type": "OFFER", "seqNum": requestId,
            "offer": ["castMode": "mirroring", "receiverGetStatus": true, "supportedStreams": streams],
        ], to: tid)
        set(.negotiating)
    }

    private func answer(_ json: [String: Any]) {
        guard phase == .negotiating else { return }
        guard json["result"] as? String == "ok", let a = json["answer"] as? [String: Any],
              let port = (a["udpPort"] as? NSNumber)?.uint16Value
        else {
            let err = (json["error"] as? [String: Any])?["description"] as? String ?? L("invalid answer")
            finish(L("Stream refused by the device: %@", err))
            return
        }
        guard let host = channel?.remoteHost, let audioConfig, let videoConfig else {
            finish(L("Unknown device address")); return
        }
        let indexes = (a["sendIndexes"] as? [NSNumber])?.map(\.intValue) ?? []
        let ssrcs = (a["ssrcs"] as? [NSNumber])?.map(\.uint32Value) ?? []

        let transport = UDPTransport(host: host, port: port, queue: queue)
        udp = transport
        for (n, index) in indexes.enumerated() {
            let rs = n < ssrcs.count ? ssrcs[n] : 0
            if index == videoConfig.index {
                videoStream = CastRTPStream(config: videoConfig, receiverSSRC: rs, transport: transport)
            } else if index == audioConfig.index, options.audio {
                audioStream = CastRTPStream(config: audioConfig, receiverSSRC: rs, transport: transport)
            }
        }
        guard videoStream != nil else { finish(L("The device does not accept H.264 video")); return }
        let streams = [videoStream, audioStream].compactMap { $0 }
        transport.onPacket = { data in handleRTCP(data, streams: streams) }
        log("streaming to \(host):\(port), \(size.0)x\(size.1), audio \(audioStream != nil)")
        startMedia()
    }

    // MARK: Media

    private func startMedia() {
        clock = MediaClock()
        sendSenderReports()
        every(0.25) { [weak self] in self?.sendSenderReports() }
        every(2) { [weak self] in self?.logStats() }

        guard let ve = VideoEncoder(width: size.0, height: size.1, fps: options.fps, bitrate: options.videoBitrate) else {
            finish(L("H.264 encoder unavailable")); return
        }
        videoEncoder = ve
        ve.onFrame = { [weak self] data, key, pts in
            self?.queue.async { self?.sendVideo(data, key: key, pts: pts) }
        }
        videoStream?.onKeyFrameRequest = { [weak ve] in
            log("key frame requested")
            ve?.requestKeyFrame()
        }

        if audioStream != nil, let ae = AudioEncoder(bitrate: 128_000) {
            audioEncoder = ae
            ae.onPacket = { [weak self] data, pts in
                self?.queue.async { self?.sendAudio(data, pts: pts) }
            }
        }

        let src: MediaSource
        if options.testPattern {
            src = TestPatternSource(width: size.0, height: size.1, fps: options.fps)
        } else {
            let capture = ScreenCapture(displayID: options.displayID, width: size.0, height: size.1,
                                        fps: options.fps, audio: audioStream != nil)
            capture.onError = { [weak self] e in
                self?.queue.async { self?.finish(L("Capture interrupted (%@)", e.localizedDescription)) }
            }
            src = capture
        }
        src.onVideo = { [weak ve] pb, pts in ve?.encode(pb, pts: pts) }
        let ae = audioEncoder
        src.onAudio = { [weak ae] pcm, pts in ae?.encode(pcm, pts: pts) }
        source = src
        src.start { [weak self] error in
            guard let self else { return }
            self.queue.async {
                if let error {
                    self.finish(L("Screen capture failed: %@", error.localizedDescription))
                } else {
                    self.set(.streaming)
                }
            }
        }
    }

    private func sendVideo(_ data: Data, key: Bool, pts: Double) {
        guard phase == .streaming || phase == .negotiating else { return }
        videoStream?.sendFrame(data, rtpTimestamp: clock.rtp(pts, rate: 90000), keyFrame: key)
    }

    private func sendAudio(_ data: Data, pts: Double) {
        guard phase == .streaming || phase == .negotiating else { return }
        audioStream?.sendFrame(data, rtpTimestamp: clock.rtp(pts, rate: 48000), keyFrame: true)
    }

    private func sendSenderReports() {
        let reports = [videoStream, audioStream].compactMap { $0?.senderReport(clock: clock) }
        udp?.send(reports)
    }

    private func logStats() {
        func describe(_ s: CastRTPStream?, _ name: String) -> String {
            guard let s else { return "\(name) off" }
            return "\(name) sent \(s.framesSent) acked \(s.checkpoint + 1) retx \(s.retransmits) keyreq \(s.keyFrameRequests)"
        }
        log("stats: \(describe(videoStream, "video")) | \(describe(audioStream, "audio"))")
    }

    // MARK: Teardown

    private func finish(_ reason: String?) {
        if case .ended = phase { return }
        log("session end: \(reason ?? "stopped")")
        timers.forEach { $0.cancel() }
        timers = []
        source?.stop()
        source = nil
        videoEncoder?.invalidate()
        if let ch = channel {
            if let sid = appSessionId {
                requestId += 1
                ch.send(CastNamespace.receiver, ["type": "STOP", "requestId": requestId, "sessionId": sid])
            }
            queue.asyncAfter(deadline: .now() + 0.3) { ch.close() }
        }
        udp?.close()
        if awakeAssertion != 0 {
            IOPMAssertionRelease(awakeAssertion)
            awakeAssertion = 0
        }
        set(.ended(reason))
    }

    // MARK: Helpers

    private func set(_ p: Phase) {
        if case .ended = phase { return }
        phase = p
        let cb = onPhase
        DispatchQueue.main.async { cb?(p) }
    }

    private func after(_ seconds: Double, _ block: @escaping () -> Void) {
        queue.asyncAfter(deadline: .now() + seconds, execute: block)
    }

    private func every(_ seconds: Double, _ block: @escaping () -> Void) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + seconds, repeating: seconds)
        t.setEventHandler(handler: block)
        t.resume()
        timers.append(t)
    }
}
