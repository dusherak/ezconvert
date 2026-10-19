import AppKit

// MARK: - Radial menu view

/// Two-ring donut. The inner ring holds actions and groups; hovering a group opens its
/// actions as an arc in the outer ring. After a drop the same view shrinks to a progress ring.
final class RadialView: NSView {
    static let size: CGFloat = 540
    let hubRadius: CGFloat = 56
    let ring1: (inner: CGFloat, outer: CGFloat) = (62, 156)
    let ring2: (inner: CGFloat, outer: CGFloat) = (162, 252)
    let accent = NSColor(srgbRed: 1.0, green: 0.55, blue: 0.15, alpha: 1)

    enum Mode { case menu, working, done, failed }
    private(set) var mode: Mode = .menu

    var items: [MenuItem] = [] { didSet { setHover(top: nil, child: nil, expanded: nil); mode = .menu; needsDisplay = true } }
    var fileCount = 0
    private(set) var hoveredTop: Int?
    private(set) var hoveredChild: Int?
    private(set) var expanded: Int?
    var onDrop: ((Action, String, [URL]) -> Void)?
    var onCancel: (() -> Void)?

    // Progress state
    private var workTitle = ""
    private var fraction: Double = 0
    private var spinPhase: CGFloat = 0
    private var spinTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    private var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

    // MARK: Geometry (degrees, counter-clockwise from 3 o'clock; item 0 sits at 12 o'clock)

    private var topStep: CGFloat { 360 / CGFloat(max(items.count, 1)) }
    private func topMid(_ i: Int) -> CGFloat { 90 - topStep * CGFloat(i) }
    private func childStep(_ g: Int) -> CGFloat { min(34, 330 / CGFloat(max(items[g].children.count, 1))) }
    private func childMid(_ g: Int, _ j: Int) -> CGFloat {
        let n = CGFloat(items[g].children.count)
        return topMid(g) - (CGFloat(j) - (n - 1) / 2) * childStep(g)
    }

    private func angleDiff(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        var d = (a - b).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    private func topIndex(atAngle deg: CGFloat) -> Int {
        var fromTop = (90 - deg + topStep / 2).truncatingRemainder(dividingBy: 360)
        if fromTop < 0 { fromTop += 360 }
        return Int(fromTop / topStep) % items.count
    }

    /// The action under the pointer, if any, with its display path.
    var selection: (action: Action, path: String)? {
        guard let t = hoveredTop else { return nil }
        let item = items[t]
        if let a = item.action { return (a, a.title) }
        if let c = hoveredChild { return (item.children[c], "\(item.title) → \(item.children[c].title)") }
        return nil
    }

    private func setHover(top: Int?, child: Int?, expanded: Int?) {
        if top != hoveredTop || child != hoveredChild || expanded != self.expanded {
            hoveredTop = top; hoveredChild = child; self.expanded = expanded
            needsDisplay = true
        }
    }

    func updateHover(at point: CGPoint) {
        guard mode == .menu, !items.isEmpty else { return }
        let dx = point.x - center.x, dy = point.y - center.y
        let r = hypot(dx, dy), deg = atan2(dy, dx) * 180 / .pi

        if r < ring1.inner {
            return setHover(top: nil, child: nil, expanded: nil)
        }
        // Outer ring: pick a child of the open group if the pointer is over its arc.
        if r > ring1.outer + 3, let g = expanded {
            for j in items[g].children.indices where abs(angleDiff(deg, childMid(g, j))) <= childStep(g) / 2 {
                return setHover(top: g, child: j, expanded: g)
            }
        }
        if r > ring2.outer + 60 { return setHover(top: nil, child: nil, expanded: expanded) }
        let t = topIndex(atAngle: deg)
        setHover(top: t, child: nil, expanded: items[t].isGroup ? t : nil)
    }

    // MARK: Progress

    func beginWork(title: String) {
        mode = .working
        workTitle = title
        fraction = 0
        spinTimer?.invalidate()
        spinTimer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] _ in
            guard let self, self.mode == .working, self.fraction == 0 else { return }
            self.spinPhase = (self.spinPhase - 6).truncatingRemainder(dividingBy: 360)
            self.needsDisplay = true
        }
        needsDisplay = true
    }

    func setProgress(_ f: Double) {
        guard mode == .working else { return }
        fraction = max(fraction, min(f, 1))
        needsDisplay = true
    }

    func finishWork(success: Bool) {
        spinTimer?.invalidate()
        spinTimer = nil
        mode = success ? .done : .failed
        fraction = 1
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        if mode == .menu { drawMenu() } else { drawProgress() }
    }

    private func sector(_ r0: CGFloat, _ r1: CGFloat, _ a0: CGFloat, _ a1: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: r1, startAngle: a0, endAngle: a1)
        path.appendArc(withCenter: center, radius: r0, startAngle: a1, endAngle: a0, clockwise: true)
        path.close()
        return path
    }

    private func drawLabel(_ title: String, symbol: String, at angle: CGFloat, radius: CGFloat, hot: Bool, small: Bool = false) {
        let rad = angle * .pi / 180
        let p = CGPoint(x: center.x + cos(rad) * radius, y: center.y + sin(rad) * radius)
        let fg = hot ? NSColor.black : NSColor(white: 0.92, alpha: 1)
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: small ? 14 : 17, weight: .medium)) {
            let t = img.tinted(fg)
            t.draw(in: NSRect(x: p.x - t.size.width / 2, y: p.y + 2, width: t.size.width, height: t.size.height))
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: small ? 10.5 : 11, weight: .semibold), .foregroundColor: fg,
        ]
        let s = title as NSString
        let sz = s.size(withAttributes: attrs)
        s.draw(at: CGPoint(x: p.x - sz.width / 2, y: p.y - sz.height - 2), withAttributes: attrs)
    }

    private func drawMenu() {
        let gap: CGFloat = items.count > 1 ? 1.2 : 0
        let disc = NSBezierPath(ovalIn: NSRect(x: center.x - ring1.outer, y: center.y - ring1.outer,
                                               width: ring1.outer * 2, height: ring1.outer * 2))
        NSColor(white: 0.11, alpha: 0.95).setFill()
        disc.fill()
        NSColor(white: 1, alpha: 0.12).setStroke()
        disc.stroke()

        for (i, item) in items.enumerated() {
            let mid = topMid(i), a0 = mid - topStep / 2 + gap, a1 = mid + topStep / 2 - gap
            let hot = hoveredTop == i && (!item.isGroup || hoveredChild == nil)
            let open = expanded == i
            (hot ? accent : open ? NSColor(white: 1, alpha: 0.16) : NSColor(white: 1, alpha: 0.06)).setFill()
            sector(ring1.inner + 4, ring1.outer - 5, a0, a1).fill()
            drawLabel(item.title, symbol: item.symbol, at: mid, radius: (ring1.inner + ring1.outer) / 2 + 2, hot: hot)
            if item.isGroup {
                // Small arc on the outer edge marks a group.
                let mark = NSBezierPath()
                let span = min(topStep * 0.3, 16)
                mark.appendArc(withCenter: center, radius: ring1.outer - 11, startAngle: mid - span / 2, endAngle: mid + span / 2)
                mark.lineWidth = 2.5
                mark.lineCapStyle = .round
                (open ? accent : NSColor(white: 1, alpha: 0.35)).setStroke()
                mark.stroke()
            }
        }

        if let g = expanded {
            let n = items[g].children.count, step = childStep(g)
            let first = childMid(g, 0) + step / 2, last = childMid(g, n - 1) - step / 2
            NSColor(white: 0.11, alpha: 0.95).setFill()
            sector(ring2.inner - 2, ring2.outer, last - 1, first + 1).fill()
            for (j, child) in items[g].children.enumerated() {
                let mid = childMid(g, j), hot = hoveredChild == j
                (hot ? accent : NSColor(white: 1, alpha: 0.06)).setFill()
                sector(ring2.inner + 3, ring2.outer - 5, mid - step / 2 + 1, mid + step / 2 - 1).fill()
                drawLabel(child.title, symbol: child.symbol, at: mid, radius: (ring2.inner + ring2.outer) / 2 + 2, hot: hot, small: true)
            }
        }

        // Centre: cancel target and what will happen on drop
        fillHub()
        if let sel = selection {
            drawCentered(sel.action.title, size: 14, weight: .bold, color: accent, dy: 8)
            drawCentered("\(fileCount) file\(fileCount == 1 ? "" : "s")", size: 10, weight: .regular, color: NSColor(white: 0.6, alpha: 1), dy: -10)
        } else if let g = expanded {
            drawCentered(items[g].title, size: 13, weight: .bold, color: NSColor(white: 0.9, alpha: 1), dy: 8)
            drawCentered("pick one ↗", size: 10, weight: .regular, color: NSColor(white: 0.6, alpha: 1), dy: -10)
        } else {
            drawCentered("Cancel", size: 14, weight: .bold, color: NSColor(white: 0.6, alpha: 1), dy: 8)
            drawCentered("drop here", size: 10, weight: .regular, color: NSColor(white: 0.5, alpha: 1), dy: -10)
        }
    }

    private func fillHub() {
        let hub = NSBezierPath(ovalIn: NSRect(x: center.x - hubRadius, y: center.y - hubRadius,
                                              width: hubRadius * 2, height: hubRadius * 2))
        NSColor(white: 0.14, alpha: 0.97).setFill()
        hub.fill()
    }

    private func drawProgress() {
        fillHub()
        let r = hubRadius - 8
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: r, startAngle: 0, endAngle: 360)
        track.lineWidth = 6
        NSColor(white: 1, alpha: 0.12).setStroke()
        track.stroke()

        let color: NSColor = mode == .failed ? .systemRed : mode == .done ? .systemGreen : accent
        let arc = NSBezierPath()
        if mode == .working && fraction == 0 {
            arc.appendArc(withCenter: center, radius: r, startAngle: spinPhase, endAngle: spinPhase + 80)
        } else {
            arc.appendArc(withCenter: center, radius: r, startAngle: 90, endAngle: 90 - 360 * CGFloat(fraction), clockwise: true)
        }
        arc.lineWidth = 6
        arc.lineCapStyle = .round
        color.setStroke()
        arc.stroke()

        switch mode {
        case .working:
            drawCentered(fraction > 0 ? "\(Int(fraction * 100))%" : "…", size: 15, weight: .bold, color: .white, dy: 6)
            drawCentered(workTitle, size: 9.5, weight: .medium, color: NSColor(white: 0.65, alpha: 1), dy: -11)
        case .done, .failed:
            let name = mode == .done ? "checkmark" : "xmark"
            if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 26, weight: .bold)) {
                let t = img.tinted(color)
                t.draw(in: NSRect(x: center.x - t.size.width / 2, y: center.y - t.size.height / 2,
                                  width: t.size.width, height: t.size.height))
            }
        case .menu: break
        }
    }

    private func drawCentered(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, dy: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
        let str = s as NSString
        let sz = str.size(withAttributes: attrs)
        str.draw(at: CGPoint(x: center.x - sz.width / 2, y: center.y - sz.height / 2 + dy), withAttributes: attrs)
    }

    // MARK: Drag destination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateHover(at: convert(sender.draggingLocation, from: nil))
        return selection == nil ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if mode == .menu { setHover(top: nil, child: nil, expanded: expanded) }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        updateHover(at: convert(sender.draggingLocation, from: nil))
        guard mode == .menu, let sel = selection,
              let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                               options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty
        else { onCancel?(); return false }
        onDrop?(sel.action, sel.path, urls)
        return true
    }
}

extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let img = copy() as! NSImage
        img.lockFocus()
        color.set()
        NSRect(origin: .zero, size: img.size).fill(using: .sourceAtop)
        img.unlockFocus()
        img.isTemplate = false
        return img
    }
}

// MARK: - Floating panels

final class OverlayPanel: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
    }
    override var canBecomeKey: Bool { false }
}

/// Small rounded toast in the bottom-right corner reporting results.
final class Toast {
    private let panel = OverlayPanel(size: NSSize(width: 320, height: 64))
    private let label = NSTextField(wrappingLabelWithString: "")
    private var hideWork: DispatchWorkItem?
    private var revealTarget: URL?

    init() {
        let bg = NSVisualEffectView(frame: panel.contentView!.bounds)
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 14
        bg.autoresizingMask = [.width, .height]
        label.frame = bg.bounds.insetBy(dx: 14, dy: 10)
        label.autoresizingMask = [.width, .height]
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.maximumNumberOfLines = 3
        bg.addSubview(label)
        let click = NSClickGestureRecognizer(target: self, action: #selector(reveal))
        bg.addGestureRecognizer(click)
        panel.contentView = bg
    }

    func show(_ text: String, reveal url: URL? = nil, seconds: Double = 4) {
        revealTarget = url
        label.stringValue = text + (url != nil ? "\nClick to show in Finder" : "")
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - 336, y: screen.minY + 16))
        }
        panel.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    @objc private func reveal() {
        if let url = revealTarget { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        panel.orderOut(nil)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let panel = OverlayPanel(size: NSSize(width: RadialView.size, height: RadialView.size))
    let radial = RadialView(frame: NSRect(x: 0, y: 0, width: RadialView.size, height: RadialView.size))
    let toast = Toast()
    var statusItem: NSStatusItem!
    var monitors: [Any] = []
    let aiMenu = NSMenu()
    let dragPasteboard = NSPasteboard(name: .drag)
    var changeCountAtMouseDown = 0
    var shownForChangeCount = -1
    var watchTimer: Timer?
    /// The conversion whose progress the panel is showing (0 = none).
    var activeJob = 0
    var jobCounter = 0
    let work = DispatchQueue(label: "ezconvert.convert", qos: .userInitiated)
    var demo = false

    func applicationDidFinishLaunching(_ note: Notification) {
        panel.contentView = radial
        radial.onDrop = { [weak self] action, path, urls in self?.perform(action, title: path, on: urls) }
        radial.onCancel = { [weak self] in self?.hideMenu() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "circle.circle.fill", accessibilityDescription: "ezconvert")
        let statusMenu = NSMenu()
        statusMenu.addItem(withTitle: "Hold ⇧ Shift while dragging a file", action: nil, keyEquivalent: "").isEnabled = false
        statusMenu.addItem(.separator())
        let aiItem = NSMenuItem(title: "Study AI", action: nil, keyEquivalent: "")
        aiItem.submenu = aiMenu
        statusMenu.addItem(aiItem)
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "Quit ezconvert", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = statusMenu
        buildAIMenu()

        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self else { return }
            self.changeCountAtMouseDown = self.dragPasteboard.changeCount
        } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            self?.dragMoved()
        } as Any)

        if demo {
            radial.items = menu(for: [URL(fileURLWithPath: "/tmp/demo.mov")])
            radial.fileCount = 1
            showMenu(at: NSPoint(x: NSScreen.main!.frame.midX, y: NSScreen.main!.frame.midY), watch: false)
        }
    }

    // MARK: Study AI settings

    func buildAIMenu() {
        aiMenu.removeAllItems()
        let engine = StudySettings.engine, hasKey = StudySettings.claudeKey != nil
        let apple = aiMenu.addItem(withTitle: "On-device (Apple Intelligence)", action: #selector(useApple), keyEquivalent: "")
        apple.state = engine == .apple ? .on : .off
        let claude = aiMenu.addItem(withTitle: "Claude (Anthropic API)" + (hasKey ? "" : " — needs a key"), action: #selector(useClaude), keyEquivalent: "")
        claude.state = engine == .claude ? .on : .off
        aiMenu.addItem(.separator())
        aiMenu.addItem(withTitle: hasKey ? "Change Claude API key…" : "Add Claude API key…", action: #selector(askForKey), keyEquivalent: "")
        if hasKey { aiMenu.addItem(withTitle: "Remove Claude API key", action: #selector(removeKey), keyEquivalent: "") }
        for item in aiMenu.items { item.target = self }
    }

    @objc func useApple() { StudySettings.engine = .apple; buildAIMenu() }

    @objc func useClaude() {
        if StudySettings.claudeKey == nil { askForKey() } else { StudySettings.engine = .claude; buildAIMenu() }
    }

    @objc func askForKey() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Claude API key"
        alert.informativeText = "Paste an API key from console.anthropic.com. It's stored in your Mac's Keychain and only ever sent to api.anthropic.com. Slide text is sent to Anthropic when Claude is selected."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "sk-ant-…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        if StudySettings.saveClaudeKey(key) {
            StudySettings.engine = .claude
            toast.show("Claude API key saved — Study now uses Claude")
        } else {
            toast.show("✗ Couldn't save the key to the Keychain", seconds: 6)
        }
        buildAIMenu()
    }

    @objc func removeKey() {
        StudySettings.removeClaudeKey()
        StudySettings.engine = .apple
        buildAIMenu()
    }

    /// Called for every system-wide mouse drag; opens the menu when Shift is held over a fresh file drag.
    func dragMoved() {
        guard !(panel.isVisible && radial.mode == .menu),
              NSEvent.modifierFlags.contains(.shift),
              dragPasteboard.changeCount != changeCountAtMouseDown,
              dragPasteboard.changeCount != shownForChangeCount,
              let urls = dragPasteboard.readObjects(forClasses: [NSURL.self],
                                                    options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty
        else { return }
        shownForChangeCount = dragPasteboard.changeCount
        activeJob = 0  // a running conversion keeps going; its result shows in the toast
        radial.items = menu(for: urls)
        radial.fileCount = urls.count
        showMenu(at: NSEvent.mouseLocation, watch: true)
    }

    func showMenu(at point: NSPoint, watch: Bool) {
        var origin = NSPoint(x: point.x - RadialView.size / 2, y: point.y - RadialView.size / 2)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) })?.frame {
            origin.x = min(max(origin.x, screen.minX), screen.maxX - RadialView.size)
            origin.y = min(max(origin.y, screen.minY), screen.maxY - RadialView.size)
        }
        panel.setFrameOrigin(origin)
        panel.ignoresMouseEvents = false
        panel.invalidateShadow()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        guard watch else { return }
        // Close the menu once the mouse button is released anywhere else.
        watchTimer?.invalidate()
        watchTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            if NSEvent.pressedMouseButtons & 1 == 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    if self?.radial.mode == .menu { self?.hideMenu() }
                }
            }
        }
    }

    func hideMenu() {
        watchTimer?.invalidate()
        watchTimer = nil
        panel.orderOut(nil)
    }

    /// Runs the action, turning the menu into a progress ring at the same spot.
    func perform(_ action: Action, title: String, on urls: [URL]) {
        watchTimer?.invalidate()
        watchTimer = nil
        jobCounter += 1
        let job = jobCounter
        activeJob = job
        radial.beginWork(title: action.title)
        panel.ignoresMouseEvents = true
        panel.invalidateShadow()

        let update: (Double) -> Void = { [weak self] f in
            DispatchQueue.main.async {
                guard let self, self.activeJob == job else { return }
                self.radial.setProgress(f)
            }
        }
        let finish: (Result<[URL], Error>) -> Void = { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                var ok = false
                switch result {
                case .success(let outs):
                    ok = true
                    NSSound(named: "Glass")?.play()
                    let name = outs.count == 1 ? outs[0].lastPathComponent : "\(outs.count) files"
                    self.toast.show("✓ \(title) → \(name)", reveal: outs.first)
                case .failure(let error):
                    NSSound(named: "Basso")?.play()
                    self.toast.show("✗ \(title) failed: \(error.localizedDescription)", seconds: 8)
                }
                guard self.activeJob == job else { return }
                self.radial.finishWork(success: ok)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    guard self.activeJob == job else { return }
                    self.activeJob = 0
                    NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; self.panel.animator().alphaValue = 0 },
                                                         completionHandler: { if self.activeJob == 0 && self.radial.mode != .menu { self.hideMenu() } })
                }
            }
        }
        let body = {
            progress.onUpdate = update
            progress.begin(0, of: 1)
            let result = Result { try action.run(urls) }
            progress.onUpdate = nil
            finish(result)
        }
        if action.mainThread {
            DispatchQueue.main.async(execute: body)
        } else {
            work.async(execute: body)
        }
    }
}

// MARK: - Entry point

let args = CommandLine.arguments
func fail(_ msg: String, _ code: Int32) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(code)
}

if args.count >= 2, args[1] == "--list" {
    // ezconvert --list FILE...   → prints the menu offered for those files
    let urls = args.dropFirst(2).map { URL(fileURLWithPath: $0) }
    for item in menu(for: urls) {
        print(item.isGroup ? "\(item.title) ▸ " + item.children.map(\.title).joined(separator: ", ") : item.title)
    }
    exit(0)
}
if args.count >= 3, args[1] == "--run" {
    // ezconvert --run "Group/Title" FILE...   → runs one action headlessly (for testing)
    let urls = args.dropFirst(3).map { URL(fileURLWithPath: $0) }
    guard let action = allActions(for: urls).first(where: { $0.path == args[2] })?.action else { fail("No action \(args[2])", 2) }
    _ = NSApplication.shared
    var lastShown = -1
    progress.onUpdate = { f in
        let pct = Int(f * 100) / 25 * 25
        if pct > lastShown { lastShown = pct; FileHandle.standardError.write("progress \(pct)%\n".data(using: .utf8)!) }
    }
    progress.begin(0, of: 1)
    do { for out in try action.run(urls) { print(out.path) } } catch { fail("error: \(error.localizedDescription)", 1) }
    exit(0)
}
if args.count >= 5, args[1] == "--snapshot" {
    // ezconvert --snapshot OUT.png STATE FILE...   → renders the donut to a PNG
    // STATE: "menu", "group:G:C" (group G open, child C hovered), "work:0.4", "spin", "done"
    _ = NSApplication.shared
    let view = RadialView(frame: NSRect(x: 0, y: 0, width: RadialView.size, height: RadialView.size))
    view.appearance = NSAppearance(named: .darkAqua)
    let urls = args.dropFirst(4).map { URL(fileURLWithPath: $0) }
    view.items = menu(for: urls)
    view.fileCount = urls.count
    let state = args[3].split(separator: ":").map(String.init)
    let c = CGPoint(x: RadialView.size / 2, y: RadialView.size / 2)
    func point(_ deg: CGFloat, _ r: CGFloat) -> CGPoint { CGPoint(x: c.x + cos(deg * .pi / 180) * r, y: c.y + sin(deg * .pi / 180) * r) }
    switch state[0] {
    case "group":
        let g = Int(state[1])!, n = view.items.count
        view.updateHover(at: point(90 - 360 / CGFloat(n) * CGFloat(g), 110))
        if state.count > 2, let ch = Int(state[2]) {
            let kids = CGFloat(view.items[g].children.count), step = min(34, 330 / kids)
            view.updateHover(at: point(90 - 360 / CGFloat(n) * CGFloat(g) - (CGFloat(ch) - (kids - 1) / 2) * step, 205))
        }
    case "work": view.beginWork(title: "MP4"); view.setProgress(Double(state[1])!)
    case "spin": view.beginWork(title: "PDF")
    case "done": view.beginWork(title: "PNG"); view.finishWork(success: true)
    default: break
    }
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
delegate.demo = args.contains("--demo")
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
