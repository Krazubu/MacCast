// "Optimiser pour l'écran de destination": switch the Mac display to the
// resolution of the stream sent to the Cast device (or the largest smaller
// one with the same aspect ratio), and put the original mode back afterwards.

import CoreGraphics
import Foundation

/// Cast receivers don't report their screen size; what they show is the
/// mirroring stream, which is 16:9 at 1080p or 720p.
func destinationResolution(maxHeight: Int) -> (Int, Int) {
    maxHeight >= 1080 ? (1920, 1080) : (1280, 720)
}

func describe(_ m: CGDisplayMode) -> String {
    let hidpi = m.pixelWidth > m.width ? " HiDPI" : ""
    return "\(m.width)x\(m.height)\(hidpi) @\(Int(m.refreshRate.rounded()))Hz"
}

/// Best mode for the target: same aspect ratio, not larger than the target,
/// largest first; ties prefer the current refresh rate, then HiDPI.
func bestMode(for display: CGDirectDisplayID, target: (Int, Int)) -> CGDisplayMode? {
    let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
    guard let all = CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode] else { return nil }
    let (tw, th) = target
    let currentRate = CGDisplayCopyDisplayMode(display)?.refreshRate ?? 0
    let candidates = all.filter { m in
        guard m.isUsableForDesktopGUI(), m.width <= tw, m.height <= th else { return false }
        // Same aspect ratio within 1% (e.g. 1366x768 counts as 16:9).
        let a = Double(m.width) / Double(m.height), t = Double(tw) / Double(th)
        return abs(a - t) / t < 0.01
    }
    return candidates.max { a, b in
        if a.width != b.width { return a.width < b.width }
        let ar = abs(a.refreshRate - currentRate) < 0.5, br = abs(b.refreshRate - currentRate) < 0.5
        if ar != br { return br }
        return (a.pixelWidth > a.width ? 1 : 0) < (b.pixelWidth > b.width ? 1 : 0)
    }
}

enum DisplayModeError: LocalizedError {
    case noMatchingMode(Int, Int)
    case configurationFailed(CGError)

    var errorDescription: String? {
        switch self {
        case .noMatchingMode(let w, let h):
            return "l'écran du Mac n'a aucune résolution au format \(w)x\(h) ou plus petite au même format"
        case .configurationFailed(let e):
            return "changement de résolution refusé (erreur \(e.rawValue))"
        }
    }
}

/// Remembers the mode a display had before we changed it.
final class DisplayModeSwitcher {
    private var original: (CGDirectDisplayID, CGDisplayMode)?

    /// Switches `display` to the best mode for `target`. Returns the mode now in use.
    @discardableResult
    func apply(display: CGDirectDisplayID, target: (Int, Int)) throws -> CGDisplayMode {
        if let (id, _) = original, id != display { restore() }
        guard let mode = bestMode(for: display, target: target) else {
            throw DisplayModeError.noMatchingMode(target.0, target.1)
        }
        let current = CGDisplayCopyDisplayMode(display)
        if let current, current.ioDisplayModeID == mode.ioDisplayModeID {
            return mode
        }
        if original == nil, let current { original = (display, current) }
        try set(display, mode)
        log("display \(display): \(current.map(describe) ?? "?") -> \(describe(mode)) for \(target.0)x\(target.1)")
        return mode
    }

    func restore() {
        guard let (id, mode) = original else { return }
        original = nil
        do {
            try set(id, mode)
            log("display \(id): restored \(describe(mode))")
        } catch {
            log("display \(id): restore failed: \(error.localizedDescription)")
        }
    }

    private func set(_ display: CGDirectDisplayID, _ mode: CGDisplayMode) throws {
        var config: CGDisplayConfigRef?
        var err = CGBeginDisplayConfiguration(&config)
        guard err == .success, let config else { throw DisplayModeError.configurationFailed(err) }
        err = CGConfigureDisplayWithDisplayMode(config, display, mode, nil)
        guard err == .success else {
            CGCancelDisplayConfiguration(config)
            throw DisplayModeError.configurationFailed(err)
        }
        // For this login session only: a crash never leaves the Mac in the new mode for good.
        err = CGCompleteDisplayConfiguration(config, .forSession)
        guard err == .success else { throw DisplayModeError.configurationFailed(err) }
    }
}
