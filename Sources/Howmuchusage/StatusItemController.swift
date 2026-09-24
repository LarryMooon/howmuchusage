import AppKit
import Combine
import SwiftUI
import UsageCore

@MainActor
final class StatusItemController: NSObject {
    private let store: UsageStore
    private let statusItem: NSStatusItem
    private let statusView: UsageStatusView
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()

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
    }

    func showPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        store.popoverOpened()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
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

        let width = UsageStatusView.width(forBlocks: blocks.count)
        if statusItem.length != width { statusItem.length = width }
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
    static let blockGap: CGFloat = 5

    static func width(forBlocks count: Int) -> CGFloat {
        let blocks = CGFloat(max(1, count))
        return blocks * (tagWidth + rowsWidth) + (blocks - 1) * blockGap + 2
    }

    var blocks: [Block] = [] {
        didSet { if blocks != oldValue { needsDisplay = true } }
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
            x += Self.tagWidth + Self.rowsWidth + Self.blockGap
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
