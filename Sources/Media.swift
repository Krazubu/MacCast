// Media side: screen + system audio capture (ScreenCaptureKit), a synthetic
// test source, H.264 encoding (VideoToolbox) and Opus encoding (AudioToolbox).

import AVFoundation
import CoreMedia
import CoreText
import Foundation
import QuartzCore
import ScreenCaptureKit
import VideoToolbox

protocol MediaSource: AnyObject {
    var onVideo: ((CVPixelBuffer, CMTime) -> Void)? { get set }
    var onAudio: ((AVAudioPCMBuffer, Double) -> Void)? { get set }
    func start(completion: @escaping (Error?) -> Void)
    func stop()
}

/// Fits a display of the given aspect into maxHeight-p (16:9 box), even dimensions.
func videoSize(forDisplay display: CGDirectDisplayID, maxHeight: Int) -> (Int, Int) {
    let bounds = CGDisplayBounds(display)
    let w = max(bounds.width, 1), h = max(bounds.height, 1)
    let boxH = Double(maxHeight), boxW = boxH * 16 / 9
    let scale = min(boxW / w, boxH / h)
    func even(_ v: Double) -> Int { max(2, Int(v / 2) * 2) }
    return (even(w * scale), even(h * scale))
}

// MARK: - Screen capture

final class ScreenCapture: NSObject, MediaSource, SCStreamOutput, SCStreamDelegate {
    var onVideo: ((CVPixelBuffer, CMTime) -> Void)?
    var onAudio: ((AVAudioPCMBuffer, Double) -> Void)?
    var onError: ((Error) -> Void)?

    private let displayID: CGDirectDisplayID
    private let width: Int, height: Int, fps: Int
    private let audio: Bool
    private var stream: SCStream?
    private let videoQueue = DispatchQueue(label: "capture.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "capture.audio", qos: .userInteractive)
    private var refresh: DispatchSourceTimer?
    private var lastBuffer: CVPixelBuffer?
    private var lastTime: Double = 0

    init(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int, audio: Bool) {
        self.displayID = displayID
        self.width = width; self.height = height; self.fps = fps
        self.audio = audio
    }

    func start(completion: @escaping (Error?) -> Void) {
        Task {
            do {
                // A display created a moment ago (virtual 16:9 one) can take a little while to be listed.
                var found: SCDisplay?
                for attempt in 0..<20 {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    found = content.displays.first(where: { $0.displayID == self.displayID })
                    if found != nil || attempt == 19 { break }
                    try await Task.sleep(nanoseconds: 150_000_000)
                }
                guard let display = found else {
                    throw NSError(domain: "CastMirror", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: L("display %ld not found", Int(self.displayID))])
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let cfg = SCStreamConfiguration()
                cfg.width = self.width
                cfg.height = self.height
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(self.fps))
                cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                cfg.queueDepth = 6
                cfg.showsCursor = true
                cfg.scalesToFit = true
                cfg.capturesAudio = self.audio
                cfg.sampleRate = 48000
                cfg.channelCount = 2
                cfg.excludesCurrentProcessAudio = true
                let s = SCStream(filter: filter, configuration: cfg, delegate: self)
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.videoQueue)
                if self.audio { try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.audioQueue) }
                try await s.startCapture()
                self.stream = s
                self.videoQueue.async { self.startRefresh() }
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    func stop() {
        refresh?.cancel()
        let s = stream
        stream = nil
        Task { try? await s?.stopCapture() }
    }

    /// ScreenCaptureKit sends nothing while the screen is static; resend the
    /// last image regularly so the receiver keeps a live stream.
    private func startRefresh() {
        let t = DispatchSource.makeTimerSource(queue: videoQueue)
        t.schedule(deadline: .now() + 0.5, repeating: 0.25)
        t.setEventHandler { [weak self] in
            guard let self, let pb = self.lastBuffer else { return }
            let now = CACurrentMediaTime()
            if now - self.lastTime > 0.5 {
                self.lastTime = now
                self.onVideo?(pb, CMTime(seconds: now, preferredTimescale: 1_000_000_000))
            }
        }
        t.resume()
        refresh = t
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            guard let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = atts.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
                  let pb = CMSampleBufferGetImageBuffer(sb)
            else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            lastBuffer = pb
            lastTime = pts.seconds
            onVideo?(pb, pts)
        case .audio:
            if let pcm = pcmBuffer(sb) { onAudio?(pcm, CMSampleBufferGetPresentationTimeStamp(sb).seconds) }
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("capture stopped: \(error)")
        onError?(error)
    }

    private func pcmBuffer(_ sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let fd = CMSampleBufferGetFormatDescription(sb) else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: fd)
        let frames = CMSampleBufferGetNumSamples(sb)
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return nil }
        buf.frameLength = AVAudioFrameCount(frames)
        let st = CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames), into: buf.mutableAudioBufferList)
        return st == noErr ? buf : nil
    }
}

// MARK: - Test pattern

/// Moving colour pattern with a clock and a 440 Hz beep every second.
final class TestPatternSource: MediaSource {
    var onVideo: ((CVPixelBuffer, CMTime) -> Void)?
    var onAudio: ((AVAudioPCMBuffer, Double) -> Void)?

    private let width: Int, height: Int, fps: Int
    private let queue = DispatchQueue(label: "pattern", qos: .userInteractive)
    private var timers: [DispatchSourceTimer] = []
    private var pool: CVPixelBufferPool?
    private var frame = 0
    private var audioStart: Double = 0
    private var audioSamples: Int64 = 0
    private let audioFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!

    init(width: Int, height: Int, fps: Int) {
        self.width = width; self.height = height; self.fps = fps
    }

    func start(completion: @escaping (Error?) -> Void) {
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        audioStart = CACurrentMediaTime()

        let v = DispatchSource.makeTimerSource(queue: queue)
        v.schedule(deadline: .now(), repeating: 1.0 / Double(fps))
        v.setEventHandler { [weak self] in self?.drawFrame() }
        let a = DispatchSource.makeTimerSource(queue: queue)
        a.schedule(deadline: .now(), repeating: 0.02)
        a.setEventHandler { [weak self] in self?.makeAudio() }
        timers = [v, a]
        timers.forEach { $0.resume() }
        completion(nil)
    }

    func stop() { timers.forEach { $0.cancel() } }

    private func drawFrame() {
        guard let pool else { return }
        var pbOut: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
        guard let pb = pbOut else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height,
                               bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            let hue = CGFloat(frame % 600) / 600
            ctx.setFillColor(CGColor(srgbRed: 0.2 + 0.3 * hue, green: 0.25, blue: 0.5 - 0.3 * hue, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let barX = CGFloat((frame * 12) % width)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: barX, y: 0, width: 40, height: CGFloat(height)))
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
            let text = L("Cast Mirror — test pattern  %@  #%ld", f.string(from: Date()), frame)
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, CGFloat(height) / 14, nil)
            let attr = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
            ])
            ctx.textPosition = CGPoint(x: 40, y: CGFloat(height) / 2)
            CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        frame += 1
        onVideo?(pb, CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 1_000_000_000))
    }

    private func makeAudio() {
        let target = Int64((CACurrentMediaTime() - audioStart) * 48000)
        let n = target - audioSamples
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(n)) else { return }
        buf.frameLength = AVAudioFrameCount(n)
        let l = buf.floatChannelData![0], r = buf.floatChannelData![1]
        for i in 0..<Int(n) {
            let s = audioSamples + Int64(i)
            let on = (s % 48000) < 9600
            let v: Float = on ? 0.25 * sinf(Float(s) * 2 * .pi * 440 / 48000) : 0
            l[i] = v; r[i] = v
        }
        let pts = audioStart + Double(audioSamples) / 48000
        audioSamples = target
        onAudio?(buf, pts)
    }
}

// MARK: - H.264 encoder

final class VideoEncoder {
    /// Annex B access unit, key frame flag, presentation time (host seconds).
    var onFrame: ((Data, Bool, Double) -> Void)?

    private var session: VTCompressionSession?
    private let lock = NSLock()
    private var forceKey = true

    init?(width: Int, height: Int, fps: Int, bitrate: Int) {
        let spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true]
        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard status == noErr, let s else { log("VTCompressionSessionCreate failed \(status)"); return nil }
        let props: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_Main_AutoLevel,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
            kVTCompressionPropertyKey_DataRateLimits: [bitrate / 8 * 3 / 2, 1] as CFArray,
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: fps * 10,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 10,
        ]
        for (k, v) in props {
            let st = VTSessionSetProperty(s, key: k, value: v as CFTypeRef)
            if st != noErr { log("VT property \(k) failed \(st)") }
        }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(s)
        session = s
    }

    deinit { invalidate() }

    func invalidate() {
        lock.lock(); let s = session; session = nil; lock.unlock()
        if let s { VTCompressionSessionInvalidate(s) }
    }

    func requestKeyFrame() {
        lock.lock(); forceKey = true; lock.unlock()
    }

    func encode(_ pb: CVPixelBuffer, pts: CMTime) {
        lock.lock()
        let s = session
        let key = forceKey
        forceKey = false
        lock.unlock()
        guard let s else { return }
        let props: CFDictionary? = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(s, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid,
                                        frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sb in
            guard status == noErr, let sb, let self else { return }
            self.emit(sb)
        }
    }

    private func emit(_ sb: CMSampleBuffer) {
        let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]]
        let isKey = !(atts?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        guard let fd = CMSampleBufferGetFormatDescription(sb), let bb = CMSampleBufferGetDataBuffer(sb) else { return }
        let startCode: [UInt8] = [0, 0, 0, 1]
        var out = Data()

        var count = 0, headerLength: Int32 = 4
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                           parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                           nalUnitHeaderLengthOut: &headerLength)
        if isKey {
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                                      parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                      nalUnitHeaderLengthOut: nil) == noErr, let ptr {
                    out.append(contentsOf: startCode)
                    out.append(ptr, count: size)
                }
            }
        }

        let total = CMBlockBufferGetDataLength(bb)
        var avcc = [UInt8](repeating: 0, count: total)
        guard CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: total, destination: &avcc) == noErr else { return }
        let hl = Int(headerLength)
        var off = 0
        while off + hl <= total {
            var n = 0
            for i in 0..<hl { n = n << 8 | Int(avcc[off + i]) }
            off += hl
            guard n > 0, off + n <= total else { break }
            out.append(contentsOf: startCode)
            out.append(contentsOf: avcc[off..<off + n])
            off += n
        }
        onFrame?(out, isKey, CMSampleBufferGetPresentationTimeStamp(sb).seconds)
    }
}

// MARK: - Opus encoder

final class AudioEncoder {
    static let frameSize = 480  // 10 ms at 48 kHz
    /// Opus packet and the host time of its first sample.
    var onPacket: ((Data, Double) -> Void)?

    private let outFormat: AVAudioFormat
    private let bitrate: Int
    private var converter: AVAudioConverter?
    private var inFormat: AVAudioFormat?
    private var basePTS: Double = 0
    private var inputSeconds: Double = 0
    private var outputSamples: Int64 = 0

    init?(bitrate: Int) {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(Self.frameSize), mBytesPerFrame: 0, mChannelsPerFrame: 2,
            mBitsPerChannel: 0, mReserved: 0)
        guard let f = AVAudioFormat(streamDescription: &asbd) else { return nil }
        outFormat = f
        self.bitrate = bitrate
    }

    func encode(_ pcm: AVAudioPCMBuffer, pts: Double) {
        if converter == nil || inFormat != pcm.format {
            guard let c = AVAudioConverter(from: pcm.format, to: outFormat) else {
                log("no Opus converter for \(pcm.format)")
                return
            }
            c.bitRate = bitrate
            converter = c
            inFormat = pcm.format
            reanchor(pts)
        }
        guard let converter else { return }

        // Re-anchor timestamps after a gap or drift (capture paused, etc.).
        if abs(pts - (basePTS + inputSeconds)) > 0.1 {
            converter.reset()
            reanchor(pts)
        }
        inputSeconds += Double(pcm.frameLength) / pcm.format.sampleRate

        var supplied = false
        let out = AVAudioCompressedBuffer(format: outFormat, packetCapacity: 64,
                                          maximumPacketSize: max(converter.maximumOutputPacketSize, 1500))
        while true {
            out.packetCount = 0
            out.byteLength = 0
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                if supplied { inputStatus.pointee = .noDataNow; return nil }
                supplied = true
                inputStatus.pointee = .haveData
                return pcm
            }
            if let descs = out.packetDescriptions {
                for i in 0..<Int(out.packetCount) {
                    let d = descs[i]
                    let packet = Data(bytes: out.data.advanced(by: Int(d.mStartOffset)), count: Int(d.mDataByteSize))
                    onPacket?(packet, basePTS + Double(outputSamples) / 48000)
                    outputSamples += Int64(Self.frameSize)
                }
            }
            if status != .haveData || out.packetCount == 0 {
                if status == .error { log("opus encode error \(String(describing: error))") }
                break
            }
        }
    }

    private func reanchor(_ pts: Double) {
        basePTS = pts
        inputSeconds = 0
        outputSamples = 0
    }
}
