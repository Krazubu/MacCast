// Cast V2 control channel: TLS on port 8009, length-prefixed protobuf
// CastMessage frames carrying JSON payloads, plus Bonjour discovery.

import Foundation
import Network

enum CastNamespace {
    static let connection = "urn:x-cast:com.google.cast.tp.connection"
    static let heartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
    static let receiver = "urn:x-cast:com.google.cast.receiver"
    static let webrtc = "urn:x-cast:com.google.cast.webrtc"
}

/// The subset of the CastMessage protobuf we use (string payloads only).
struct CastMessage {
    var source: String
    var destination: String
    var namespace: String
    var payload: String

    func encode() -> Data {
        var d = Data()
        func varint(_ value: UInt64) {
            var v = value
            while v >= 0x80 { d.append(UInt8(v & 0x7f) | 0x80); v >>= 7 }
            d.append(UInt8(v))
        }
        func string(_ tag: UInt8, _ s: String) {
            let bytes = Data(s.utf8)
            d.append(tag); varint(UInt64(bytes.count)); d.append(bytes)
        }
        d.append(0x08); varint(0)            // protocol_version = CASTV2_1_0
        string(0x12, source)                 // source_id
        string(0x1a, destination)            // destination_id
        string(0x22, namespace)              // namespace
        d.append(0x28); varint(0)            // payload_type = STRING
        string(0x32, payload)                // payload_utf8
        return d
    }

    static func decode(_ data: Data) -> CastMessage? {
        let b = [UInt8](data)
        var i = 0
        func varint() -> UInt64? {
            var result: UInt64 = 0, shift: UInt64 = 0
            while i < b.count {
                let x = b[i]; i += 1
                result |= UInt64(x & 0x7f) << shift
                if x & 0x80 == 0 { return result }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }
        var m = CastMessage(source: "", destination: "", namespace: "", payload: "")
        while i < b.count {
            guard let key = varint() else { return nil }
            switch key & 7 {
            case 0: guard varint() != nil else { return nil }
            case 1: i += 8
            case 5: i += 4
            case 2:
                guard let n = varint(), i + Int(n) <= b.count else { return nil }
                let s = String(decoding: b[i..<i + Int(n)], as: UTF8.self)
                i += Int(n)
                switch key >> 3 {
                case 2: m.source = s
                case 3: m.destination = s
                case 4: m.namespace = s
                case 6: m.payload = s
                default: break
                }
            default: return nil
            }
        }
        return m
    }
}

final class CastChannel {
    var onReady: (() -> Void)?
    var onMessage: ((CastMessage, [String: Any]) -> Void)?
    var onClose: ((String?) -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var heartbeat: DispatchSourceTimer?
    private var closed = false

    init(endpoint: NWEndpoint, queue: DispatchQueue) {
        let tls = NWProtocolTLS.Options()
        // Cast devices use self-signed certificates.
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, done in done(true) }, queue)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.connectionTimeout = 10
        tcp.noDelay = true
        connection = NWConnection(to: endpoint, using: NWParameters(tls: tls, tcp: tcp))
        self.queue = queue
    }

    /// The device's IP address once connected (used for the UDP media stream).
    var remoteHost: NWEndpoint.Host? {
        if case let .hostPort(host, _)? = connection.currentPath?.remoteEndpoint { return host }
        return nil
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.startHeartbeat()
                self.onReady?()
                self.readFrame()
            case .waiting(let error):
                self.close(reason: L("Device unreachable (%@)", error.localizedDescription))
            case .failed(let error):
                self.close(reason: L("Connection lost (%@)", error.localizedDescription))
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ namespace: String, _ json: [String: Any],
              from source: String = "sender-0", to destination: String = "receiver-0") {
        guard !closed,
              let payload = try? JSONSerialization.data(withJSONObject: json, options: [.withoutEscapingSlashes])
        else { return }
        let body = CastMessage(source: source, destination: destination, namespace: namespace,
                               payload: String(decoding: payload, as: UTF8.self)).encode()
        var frame = Data()
        frame.appendBE32(UInt32(body.count))
        frame.append(body)
        if namespace != CastNamespace.heartbeat {
            log("-> \(destination) \(namespace.split(separator: ".").last ?? "") \(String(decoding: payload.prefix(400), as: UTF8.self))")
        }
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    func close(reason: String? = nil) {
        guard !closed else { return }
        closed = true
        heartbeat?.cancel()
        connection.cancel()
        onClose?(reason)
    }

    private func startHeartbeat() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in self?.send(CastNamespace.heartbeat, ["type": "PING"]) }
        t.resume()
        heartbeat = t
    }

    private func readFrame() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, error in
            guard let self, !self.closed else { return }
            guard let data, data.count == 4, error == nil else {
                self.close(reason: L("Connection closed by the device"))
                return
            }
            let b = [UInt8](data)
            let length = Int(readBE32(b, 0))
            guard length > 0, length < 1 << 20 else { self.close(reason: L("Invalid message")); return }
            self.connection.receive(minimumIncompleteLength: length, maximumLength: length) { data, _, _, error in
                guard !self.closed else { return }
                guard let data, data.count == length, error == nil else {
                    self.close(reason: L("Connection closed by the device"))
                    return
                }
                if let message = CastMessage.decode(data) { self.dispatch(message) }
                self.readFrame()
            }
        }
    }

    private func dispatch(_ m: CastMessage) {
        let json = (try? JSONSerialization.jsonObject(with: Data(m.payload.utf8))) as? [String: Any] ?? [:]
        if m.namespace == CastNamespace.heartbeat {
            if json["type"] as? String == "PING" {
                send(CastNamespace.heartbeat, ["type": "PONG"], from: m.destination, to: m.source)
            }
            return
        }
        onMessage?(m, json)
    }
}

// MARK: - Discovery

struct CastDevice: Hashable {
    let id: String
    let name: String
    let model: String
    let endpoint: NWEndpoint
}

/// Browses `_googlecast._tcp` and reports devices able to show video.
final class CastBrowser {
    var onChange: (([CastDevice]) -> Void)?
    private var browser: NWBrowser?

    func start(queue: DispatchQueue = .main) {
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_googlecast._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            var byId: [String: CastDevice] = [:]
            for r in results {
                guard case let .service(service, _, _, _) = r.endpoint else { continue }
                var name = service, model = "", id = service
                if case let .bonjour(txt) = r.metadata {
                    name = txt["fn"] ?? service
                    model = txt["md"] ?? ""
                    id = txt["id"] ?? service
                    // Capability bit 0 = video output; skip audio-only devices and groups.
                    if let ca = txt["ca"].flatMap(Int.init), ca & 1 == 0 { continue }
                }
                if byId[id] == nil {
                    byId[id] = CastDevice(id: id, name: name, model: model, endpoint: r.endpoint)
                }
            }
            self?.onChange?(byId.values.sorted { $0.name.localizedCompare($1.name) == .orderedAscending })
        }
        b.stateUpdateHandler = { state in
            if case .failed(let e) = state { log("browser failed: \(e)") }
        }
        b.start(queue: queue)
        browser = b
    }
}

// MARK: - Helpers

extension Data {
    mutating func appendBE16(_ v: UInt16) {
        append(UInt8(v >> 8)); append(UInt8(v & 0xff))
    }
    mutating func appendBE32(_ v: UInt32) {
        append(UInt8(v >> 24)); append(UInt8((v >> 16) & 0xff))
        append(UInt8((v >> 8) & 0xff)); append(UInt8(v & 0xff))
    }
}

func readBE16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) << 8 | UInt16(b[o + 1]) }
func readBE32(_ b: [UInt8], _ o: Int) -> UInt32 {
    UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
}

func randomBytes(_ n: Int) -> [UInt8] { (0..<n).map { _ in UInt8.random(in: .min ... .max) } }
func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

private let logQueue = DispatchQueue(label: "log")
let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/CastMirror.log")
private let logHandle: FileHandle? = {
    let fm = FileManager.default
    if let size = (try? fm.attributesOfItem(atPath: logURL.path))?[.size] as? Int, size > 5_000_000 {
        try? fm.removeItem(at: logURL)
    }
    if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
    let h = try? FileHandle(forWritingTo: logURL)
    _ = try? h?.seekToEnd()
    return h
}()
private let logDateFormat: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
}()

func log(_ message: String) {
    let line = "\(logDateFormat.string(from: Date())) \(message)\n"
    logQueue.async {
        FileHandle.standardError.write(Data(line.utf8))
        logHandle?.write(Data(line.utf8))
    }
}

/// Localized UI string. Keys are the English text; translations live in
/// Resources/<language>.lproj/Localizable.strings (French for now).
func L(_ key: String, _ args: CVarArg...) -> String {
    let format = Bundle.main.localizedString(forKey: key, value: key, table: nil)
    return args.isEmpty ? format : String(format: format, arguments: args)
}
