// Cast Mirror: mirror the Mac screen (and sound) to a Cast device, without Chrome.
//
//   Cast Mirror.app                    menu bar app
//   CastMirror --cast "<name>" [...]   command line, for testing:
//       --pattern      send a test pattern instead of the screen
//       --no-audio     video only
//       --720          720p instead of 1080p
//       --delay <ms>   receiver target delay (default 400)
//       --seconds <n>  stop after n seconds (default 30)
//       --list         just list the devices found

import AppKit

enum CLI {
    static var session: MirrorSession?
    static let browser = CastBrowser()

    static func run(_ args: [String]) -> Never {
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let listOnly = args.contains("--list")
        let name = value("--cast") ?? ""
        var options = MirrorOptions()
        options.testPattern = args.contains("--pattern")
        options.audio = !args.contains("--no-audio")
        if args.contains("--720") { options.maxHeight = 720 }
        if let d = value("--delay").flatMap(Int.init) { options.targetDelayMs = d }
        let seconds = value("--seconds").flatMap(Double.init) ?? 30

        browser.onChange = { devices in
            if listOnly {
                for d in devices { print("\(d.name)\t\(d.model)\t\(d.id)") }
                return
            }
            guard session == nil,
                  let device = devices.first(where: { name.isEmpty || $0.name.localizedCaseInsensitiveContains(name) })
            else { return }
            let s = MirrorSession(device: device, options: options)
            s.onPhase = { phase in
                log("phase: \(phase)")
                if case .ended(let reason) = phase { exit(reason == nil ? 0 : 1) }
            }
            session = s
            s.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { s.stop() }
        }
        browser.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + (listOnly ? 3 : 10)) {
            if listOnly { exit(0) }
            if session == nil { log("no device matching \"\(name)\""); exit(1) }
        }
        dispatchMain()
    }
}

let arguments = CommandLine.arguments
if arguments.contains("--modes") {
    // Dry run of "Optimiser pour l'écran de destination": nothing is changed.
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    for id in ids {
        print("display \(id): current \(CGDisplayCopyDisplayMode(id).map(describe) ?? "?")")
        for h in [1080, 720] {
            let t = destinationResolution(maxHeight: h)
            print("  for \(t.0)x\(t.1): \(bestMode(for: id, target: t).map(describe) ?? "no mode with this aspect ratio")")
        }
    }
    exit(0)
}
if arguments.contains("--cast") || arguments.contains("--list") {
    _ = NSApplication.shared  // window server connection for ScreenCaptureKit
    CLI.run(arguments)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
