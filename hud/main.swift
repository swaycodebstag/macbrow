// macbrow HUD: a small floating pill on the desktop showing what the voice agent is doing,
// in the shape people already know from Wispr Flow.
//
// It reads one word from MACBROW_STATE_FILE (default /tmp/macbrow-state), which agent.py
// rewrites on every state change. Bars animate while it is hearing you or speaking, and
// sit flat when it is idle. Clicking the pill toggles the mute file agent.py watches, so
// the pill is also the mute button. Drag it anywhere; the position is remembered.
// Right-click to quit.
//
// Build: swiftc -O -o build/macbrow-hud hud/main.swift   (see ./console.sh hud)

import AppKit

let stateURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACBROW_STATE_FILE"] ?? "/tmp/macbrow-state")
let muteURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACBROW_MUTE_FILE"] ?? "/tmp/macbrow-muted")

func agentRunning() -> Bool {
    // The process is the source of truth for "running at all"; a stale state file left by a
    // crash would otherwise keep showing the last thing it was doing.
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    task.arguments = ["-f", "agent.py console"]
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    try? task.run()
    task.waitUntilExit()
    return task.terminationStatus == 0
}

func currentState() -> String {
    if !agentRunning() { return "not running" }
    guard let raw = try? String(contentsOf: stateURL, encoding: .utf8) else { return "starting" }
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return s.isEmpty ? "starting" : s
}

final class PillView: NSView {
    var state: String = "" { didSet { if state != oldValue { needsDisplay = true } } }
    var phase: CGFloat = 0
    private var dragStart = NSPoint.zero
    private var didDrag = false

    var isActive: Bool { state == "HEARING YOU" || state == "SPEAKING" || state == "THINKING" }

    // No amber or orange anywhere: green is the live signal, grey the muted one.
    private var accent: NSColor {
        switch state {
        case "HEARING YOU": return .systemGreen
        case "SPEAKING": return .systemPurple
        case "THINKING": return .systemTeal
        case "listening": return .systemBlue
        case "MUTED": return .systemGray
        default: return .systemRed
        }
    }

    private var caption: String? {
        switch state {
        case "MUTED": return "MUTED"
        case "not running", "stopped": return "OFF"
        case "starting": return "..."
        default: return nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        let radius = r.height / 2
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).addClip()
        NSColor(calibratedWhite: 0.07, alpha: 0.93).setFill()
        r.fill()

        let color = accent
        if let text = caption {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: color,
                .kern: 1.4,
            ]
            let s = NSAttributedString(string: text, attributes: attrs)
            s.draw(at: NSPoint(x: (r.width - s.size().width) / 2, y: r.midY - 7))
            return
        }

        // Five bars. Active states breathe; idle sits as a flat row of dots.
        let count = 5
        let barWidth: CGFloat = 3.5
        let gap: CGFloat = 5
        let total = CGFloat(count) * barWidth + CGFloat(count - 1) * gap
        var x = (r.width - total) / 2
        let maxHeight = r.height - 16
        for i in 0..<count {
            var h: CGFloat = barWidth
            if isActive {
                let wave = sin(phase + CGFloat(i) * 0.9)
                h = barWidth + (maxHeight - barWidth) * (0.35 + 0.65 * abs(wave))
            }
            let bar = NSRect(x: x, y: r.midY - h / 2, width: barWidth, height: h)
            color.setFill()
            NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            x += barWidth + gap
        }
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = event.locationInWindow
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let w = window else { return }
        didDrag = true
        let p = NSEvent.mouseLocation
        w.setFrameOrigin(NSPoint(x: p.x - dragStart.x, y: p.y - dragStart.y))
    }

    override func mouseUp(with event: NSEvent) {
        guard let w = window else { return }
        if didDrag {
            UserDefaults.standard.set(NSStringFromPoint(w.frame.origin), forKey: "hudOrigin")
            return
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: muteURL.path) {
            try? fm.removeItem(at: muteURL)
        } else {
            fm.createFile(atPath: muteURL.path, contents: Data())
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(
            NSMenuItem(
                title: "Quit macbrow HUD",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: NSPanel!
    var view: PillView!

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)  // no Dock icon, no menu bar

        let size = NSSize(width: 104, height: 34)
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        view = PillView(frame: NSRect(origin: .zero, size: size))
        panel.contentView = view

        if let saved = UserDefaults.standard.string(forKey: "hudOrigin") {
            panel.setFrameOrigin(NSPointFromString(saved))
        } else if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.minY + 28))
        }
        panel.orderFrontRegardless()

        view.state = currentState()
        // Two clocks: the state file is cheap to read but involves a pgrep, so poll it four
        // times a second; the bars animate at screen speed off a separate, free timer.
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.view.state = currentState()
        }
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let v = self?.view, v.isActive else { return }
            v.phase += 0.45
            v.needsDisplay = true
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
