import AppKit
import Combine
import os
import SwiftUI
import UsageCore

@MainActor
final class StatusItemController: NSObject {
    private let store: UsageStore
    private let statusItem: NSStatusItem
    private let statusView: UsageStatusView
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []

    // Auto size: full bars when they fit, numbers only when macOS hides the item.
    private var autoCompact = false
    private var lastDowngradeAt: Date?
    private var lastUpgradeAt: Date?
    private var failedUpgrades = 0
    private var fitTimer: Timer?
    private var fallbackPanel: NSPanel?
    private var lastLoggedFit: String?
    private let log = Logger(subsystem: "com.larrymoon.howmuchusage", category: "menubar")

    init(store: UsageStore) {
        self.store = store
        statusItem = NSStatusBar.system.statusItem(withLength: UsageStatusView.width(forBlocks: 2))
        statusView = UsageStatusView(frame: NSRect(x: 0, y: 0, width: UsageStatusView.width(forBlocks: 2), height: NSStatusBar.system.thickness))
        super.init()

        statusView.onClick = { [weak self] in self?.togglePopover() }
        if let button = statusItem.button {
            button.title = ""
            button.image = nil
            button.addSubview(statusView)
            statusView.frame = button.bounds
            statusView.autoresizingMask = [.width, .height]
        }

        popover.behavior = .transient
        let hosting = NSHostingController(rootView: UsagePopover(store: store, settings: store.settings))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting

        store.objectWillChange
            .merge(with: store.settings.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                // objectWillChange fires before the change lands.
                DispatchQueue.main.async { self?.render() }
            }
            .store(in: &cancellables)
        render()
        startFitMonitoring()
    }

    // MARK: - Auto size

    private var isCompact: Bool {
        switch store.settings.menuBarSize {
        case .full: return false
        case .compact: return true
        case .auto: return autoCompact
        }
    }

    private func startFitMonitoring() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.checkFit() }
        })
        // Another app coming forward changes how much menu bar space is left.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                // Let the new app's menus settle before trying full size.
                try? await Task.sleep(nanoseconds: 400_000_000)
                self?.tryFullSize()
            }
        })
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tryFullSize(force: true) }
        })
        // Occlusion notifications are not guaranteed for status items; poll lightly as a backstop.
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkFit() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        fitTimer = timer
    }

    /// True when macOS left the item off the visible menu bar for lack of room.
    private var isHiddenForSpace: Bool {
        guard NSMenu.menuBarVisible(), let window = statusItem.button?.window else { return false }
        let frame = window.frame
        var reason: String?
        if !window.isVisible {
            reason = "window not visible"
        } else if !window.occlusionState.contains(.visible) {
            reason = "occluded"
        } else if let screen = window.screen ?? NSScreen.main {
            if !screen.frame.intersects(frame) {
                reason = "off screen"
            } else if let right = Self.rightOfNotch(on: screen), frame.minX < right.minX - 1 {
                // On notched Macs only items right of the notch are shown.
                reason = "left of notch area (minX \(Int(frame.minX)) < \(Int(right.minX)))"
            }
        }
        let summary = "frame=\(Int(frame.minX)),\(Int(frame.minY)) w=\(Int(frame.width)) compact=\(isCompact) hidden=\(reason ?? "no")"
        if summary != lastLoggedFit {
            lastLoggedFit = summary
            log.info("fit: \(summary, privacy: .public)")
        }
        return reason != nil
    }

    /// The visible menu bar area to the right of the camera notch, in global
    /// coordinates, or nil on screens without a notch.
    private static func rightOfNotch(on screen: NSScreen) -> NSRect? {
        guard #available(macOS 12.0, *), let area = screen.auxiliaryTopRightArea, area.width > 0 else { return nil }
        // Documented relative to the screen; convert when it is not already global.
        if area.minX >= screen.frame.minX, area.maxX <= screen.frame.maxX + 1 { return area }
        return area.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
    }

    private func checkFit() {
        guard store.settings.menuBarSize == .auto, !autoCompact else { return }
        let now = Date()
        if isHiddenForSpace {
            // Hidden again right after trying full size: wait longer next time.
            if let lastUpgradeAt, now.timeIntervalSince(lastUpgradeAt) < 5 {
                failedUpgrades = min(failedUpgrades + 1, 5)
            }
            autoCompact = true
            lastDowngradeAt = now
            lastUpgradeAt = nil
            render()
        } else if let lastUpgradeAt, now.timeIntervalSince(lastUpgradeAt) > 5 {
            // Full size stayed visible: the space is really there.
            failedUpgrades = 0
            self.lastUpgradeAt = nil
        }
    }

    private func tryFullSize(force: Bool = false) {
        guard store.settings.menuBarSize == .auto, autoCompact else { return }
        let cooldown = force ? 0 : 20 * pow(2, Double(failedUpgrades))
        if let lastDowngradeAt, Date().timeIntervalSince(lastDowngradeAt) < cooldown { return }
        autoCompact = false
        lastUpgradeAt = Date()
        render()
        // If it does not fit, the next check shrinks it back within a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.checkFit() }
    }

    func showPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        if isHiddenForSpace {
            // Relaunching the app is the way back when macOS hides the item:
            // shrink it and show the same controls in a window instead.
            if store.settings.menuBarSize == .auto, !autoCompact {
                autoCompact = true
                lastDowngradeAt = Date()
                render()
            }
            showFallbackPanel()
            return
        }
        store.popoverOpened()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func showFallbackPanel() {
        store.popoverOpened()
        let panel: NSPanel
        if let existing = fallbackPanel {
            panel = existing
        } else {
            panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 600),
                styleMask: [.titled, .closable, .utilityWindow],
                backing: .buffered,
                defer: true
            )
            panel.title = "Howmuchusage"
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            let hosting = NSHostingController(rootView: UsagePopover(store: store, settings: store.settings))
            hosting.sizingOptions = [.preferredContentSize]
            panel.contentViewController = hosting
            fallbackPanel = panel
        }
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.layoutIfNeeded()
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 12, y: visible.maxY - size.height - 8))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func showPopoverSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.showPopover() }
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func render() {
        let now = store.now
        let blocks = store.visibleProviders.map { provider -> UsageStatusView.Block in
            let state = store.state(for: provider)
            guard let snapshot = state.snapshot, let freshness = store.freshness(for: provider) else {
                return UsageStatusView.Block(tag: provider.shortTag, rows: [nil, nil])
            }
            let session = snapshot.session.map { UsageDisplay.line(for: $0, freshness: freshness, now: now) }
            let weekly = snapshot.weekly.map { UsageDisplay.line(for: $0, freshness: freshness, now: now) }
            return UsageStatusView.Block(tag: provider.shortTag, rows: [session, weekly])
        }

        let compact = isCompact
        let width = UsageStatusView.width(forBlocks: blocks.count, compact: compact)
        if statusItem.length != width { statusItem.length = width }
        statusView.compact = compact
        statusView.blocks = blocks
        statusItem.button?.toolTip = tooltip()
    }

    private func tooltip() -> String {
        store.visibleProviders.map { provider in
            let state = store.state(for: provider)
            guard let snapshot = state.snapshot else { return "\(provider.displayName): not connected" }
            let lines = [snapshot.session, snapshot.weekly].compactMap { $0 }
                .map { "\($0.shortLabel) \($0.remainingPercent)% left" }
                .joined(separator: ", ")
            return "\(provider.displayName): \(lines) · \(UsageFormat.age(since: snapshot.observedAt, now: store.now))"
        }
        .joined(separator: "\n")
    }
}

/// Draws the original two-row battery layout, once per provider:
/// `CL  5h [====  ] 64%`
///     `1w [======] 80%`
final class UsageStatusView: NSView {
    struct Block: Equatable {
        let tag: String
        /// Session row, weekly row. `nil` draws `--`.
        let rows: [DisplayLine?]
    }

    static let tagWidth: CGFloat = 13
    static let rowsWidth: CGFloat = 84
    static let compactRowsWidth: CGFloat = 22
    static let blockGap: CGFloat = 5

    static func width(forBlocks count: Int, compact: Bool = false) -> CGFloat {
        let blocks = CGFloat(max(1, count))
        let rows = compact ? compactRowsWidth : rowsWidth
        return blocks * (tagWidth + rows) + (blocks - 1) * blockGap + 2
    }

    var blocks: [Block] = [] {
        didSet { if blocks != oldValue { needsDisplay = true } }
    }

    /// Numbers only (no labels or bars) to save menu bar space.
    var compact = false {
        didSet { if compact != oldValue { needsDisplay = true } }
    }

    var onClick: (() -> Void)?

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        var x: CGFloat = 1
        for block in blocks {
            drawBlock(block, originX: x)
            x += Self.tagWidth + (compact ? Self.compactRowsWidth : Self.rowsWidth) + Self.blockGap
        }
    }

    private func drawBlock(_ block: Block, originX: CGFloat) {
        drawText(
            block.tag,
            rect: NSRect(x: originX, y: (bounds.height - 9) / 2, width: Self.tagWidth, height: 9),
            fontSize: 7.6,
            weight: .heavy,
            color: .labelColor,
            alignment: .left
        )

        let rowsX = originX + Self.tagWidth
        for (index, line) in block.rows.prefix(2).enumerated() {
            drawRow(line, placeholder: index == 0 ? "5h" : "1w", row: index, originX: rowsX)
        }
    }

    private func drawRow(_ line: DisplayLine?, placeholder: String, row: Int, originX: CGFloat) {
        let rowHeight = bounds.height / 2
        let rowY = CGFloat(row) * rowHeight
        let textY = rowY + max(0, (rowHeight - 8.5) / 2)

        if compact {
            // Row order (top 5h, bottom 1w) carries the meaning; color carries the level.
            let text: String
            let color: NSColor
            if let line {
                text = (line.isApproximate ? "~" : "") + line.percentText
                color = line.level == .good ? .labelColor : Self.color(for: line.level)
            } else {
                text = "--"
                color = Self.dimmedText
            }
            drawText(text, rect: NSRect(x: originX, y: textY, width: Self.compactRowsWidth, height: 8.5),
                     fontSize: 7.4, weight: .bold, color: color, alignment: .right)
            return
        }
        let barHeight: CGFloat = 3
        let barY = rowY + max(0, (rowHeight - barHeight) / 2)

        guard let line else {
            drawText("\(placeholder) --", rect: NSRect(x: originX + 1, y: textY, width: Self.rowsWidth - 2, height: 8.5),
                     fontSize: 7.2, weight: .semibold, color: Self.dimmedText, alignment: .left)
            return
        }

        let isStale = line.level == .stale
        let textColor: NSColor = isStale ? Self.dimmedText : .labelColor
        drawText(line.displayLabel, rect: NSRect(x: originX + 1, y: textY, width: 22, height: 8.5),
                 fontSize: 7.2, weight: .semibold, color: textColor, alignment: .left)
        drawBar(rect: NSRect(x: originX + 25, y: barY, width: 30, height: barHeight),
                remaining: line.remainingPercent ?? 0, color: Self.color(for: line.level))
        drawText(line.percentText, rect: NSRect(x: originX + 58, y: textY, width: 25, height: 8.5),
                 fontSize: 7.2, weight: .semibold, color: textColor, alignment: .right)
    }

    static func color(for level: UsageLevel) -> NSColor {
        switch level {
        case .good: return .systemGreen
        case .warning: return .systemYellow
        case .critical: return .systemRed
        case .stale: return dimmedText
        }
    }

    /// Old or unknown values: still clearly readable on tinted menu bars,
    /// just visibly weaker than live values.
    static var dimmedText: NSColor { NSColor.labelColor.withAlphaComponent(0.6) }

    private func drawBar(rect: NSRect, remaining: Int, color: NSColor) {
        let radius = rect.height / 2
        NSColor.labelColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()

        let fill = rect.width * CGFloat(max(0, min(100, remaining))) / 100
        guard fill > 0 else { return }
        color.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: rect.minX, y: rect.minY, width: max(fill, rect.height), height: rect.height),
            xRadius: radius,
            yRadius: radius
        ).fill()
    }

    private func drawText(
        _ text: String,
        rect: NSRect,
        fontSize: CGFloat,
        weight: NSFont.Weight,
        color: NSColor,
        alignment: NSTextAlignment
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byClipping
        text.draw(in: rect, withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ])
    }
}
