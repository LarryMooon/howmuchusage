import AppKit
import CodexUsageCore
import Combine
import ServiceManagement
import SwiftUI

@main
struct HowmuchusageMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: UsageViewModel?
    private var statusController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = UsageViewModel()
        self.model = model
        statusController = StatusItemController(model: model)
        statusController?.showPopoverSoon()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusController?.showPopover()
        return true
    }
}

@MainActor
final class UsageViewModel: ObservableObject {
    @Published private(set) var snapshot: CodexUsageSnapshot?
    @Published private(set) var errorMessage: String?
    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var launchAtLoginStatusText = "Off"
    @Published private(set) var launchAtLoginErrorMessage: String?
    @Published private(set) var lastRefresh = Date()

    private let reader = CodexUsageReader()
    private var timer: Timer?

    init() {
        refresh()
        refreshLaunchAtLoginStatus()
        timer = Timer.scheduledTimer(withTimeInterval: CodexUsageFormatter.refreshIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
                self?.refreshLaunchAtLoginStatus()
            }
        }
    }

    var output: ProbeOutput? {
        snapshot.map { ProbeOutput(snapshot: $0, now: Date()) }
    }

    func refresh() {
        do {
            snapshot = try reader.latestSnapshot()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        lastRefresh = Date()
    }

    func openUsage() {
        NSWorkspace.shared.open(CodexUsageFormatter.usageURL)
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginErrorMessage = nil
        } catch {
            launchAtLoginErrorMessage = error.localizedDescription
        }

        refreshLaunchAtLoginStatus()
    }

    func refreshLaunchAtLoginStatus() {
        let status = SMAppService.mainApp.status

        switch status {
        case .enabled:
            launchAtLoginEnabled = true
            launchAtLoginStatusText = "On"
        case .notRegistered:
            launchAtLoginEnabled = false
            launchAtLoginStatusText = "Off"
        case .requiresApproval:
            launchAtLoginEnabled = true
            launchAtLoginStatusText = "Needs approval"
        case .notFound:
            launchAtLoginEnabled = false
            launchAtLoginStatusText = "Move to Applications"
        @unknown default:
            launchAtLoginEnabled = false
            launchAtLoginStatusText = "Unknown"
        }
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }
}

@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let statusView: UsageStatusView
    private let popover: NSPopover
    private var cancellables = Set<AnyCancellable>()

    init(model: UsageViewModel) {
        statusItem = NSStatusBar.system.statusItem(withLength: UsageStatusView.preferredWidth)
        statusView = UsageStatusView(
            frame: NSRect(x: 0, y: 0, width: UsageStatusView.preferredWidth, height: NSStatusBar.system.thickness)
        )
        popover = NSPopover()
        super.init()

        statusView.onClick = { [weak self] in
            self?.togglePopover()
        }

        if let button = statusItem.button {
            button.title = ""
            button.image = nil
            button.toolTip = "Codex remaining quota"
            button.addSubview(statusView)
            statusView.frame = button.bounds
            statusView.autoresizingMask = [.width, .height]
        }

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: UsagePopover(model: model))

        model.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in
                self?.statusView.snapshot = snapshot
            }
            .store(in: &cancellables)

        model.$errorMessage
            .receive(on: RunLoop.main)
            .sink { [weak self] errorMessage in
                self?.statusView.errorMessage = errorMessage
            }
            .store(in: &cancellables)
    }

    func showPopoverSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.showPopover()
        }
    }

    func showPopover() {
        guard let button = statusItem.button else { return }

        if !popover.isShown {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }
}

final class UsageStatusView: NSView {
    static let preferredWidth: CGFloat = 80

    var snapshot: CodexUsageSnapshot? {
        didSet {
            needsDisplay = true
        }
    }

    var errorMessage: String? {
        didSet {
            needsDisplay = true
        }
    }

    var onClick: (() -> Void)?

    override var isFlipped: Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if let snapshot {
            let lines = CodexUsageFormatter.menuLines(snapshot: snapshot, now: Date())
            drawUsageLine(lines[0], row: 0)
            drawUsageLine(lines[1], row: 1)
        } else {
            drawPlaceholder()
        }
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onClick?()
    }

    private func drawUsageLine(_ line: CodexUsageFormatter.UsageLine, row: Int) {
        let rowHeight = bounds.height / 2
        let rowY = CGFloat(row) * rowHeight
        let textColor = NSColor.labelColor
        let color = barColor(remainingPercent: line.remainingPercent)
        let textY = rowY + max(0, (rowHeight - 8.5) / 2)
        let barHeight: CGFloat = 3
        let barY = rowY + max(0, (rowHeight - barHeight) / 2)

        drawText(
            line.label,
            rect: NSRect(x: 4, y: textY, width: 14, height: 8.5),
            fontSize: 7.2,
            color: textColor,
            alignment: .left
        )

        let barRect = NSRect(x: 22, y: barY, width: 28, height: barHeight)
        drawBatteryBar(rect: barRect, remainingPercent: line.remainingPercent, color: color)

        drawText(
            "\(line.remainingPercent)%",
            rect: NSRect(x: 54, y: textY, width: 23, height: 8.5),
            fontSize: 7.2,
            color: textColor,
            alignment: .right
        )
    }

    private func drawPlaceholder() {
        drawText(
            "5h --",
            rect: NSRect(x: 3, y: 1, width: bounds.width - 6, height: bounds.height / 2),
            fontSize: 7.4,
            color: .secondaryLabelColor,
            alignment: .left
        )
        drawText(
            "1w --",
            rect: NSRect(x: 3, y: bounds.height / 2, width: bounds.width - 6, height: bounds.height / 2),
            fontSize: 7.4,
            color: .secondaryLabelColor,
            alignment: .left
        )
    }

    private func drawBatteryBar(rect: NSRect, remainingPercent: Int, color: NSColor) {
        let radius = rect.height / 2
        let trackPath = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSColor.secondaryLabelColor.withAlphaComponent(0.18).setFill()
        trackPath.fill()

        let fillWidth = rect.width * CGFloat(max(0, min(100, remainingPercent))) / 100.0
        guard fillWidth > 0 else { return }

        let fillRect = NSRect(x: rect.minX, y: rect.minY, width: fillWidth, height: rect.height)
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius)
        color.setFill()
        fillPath.fill()
    }

    private func drawText(
        _ text: String,
        rect: NSRect,
        fontSize: CGFloat,
        color: NSColor,
        alignment: NSTextAlignment
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byClipping

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]

        text.draw(in: rect, withAttributes: attributes)
    }

    private func barColor(remainingPercent: Int) -> NSColor {
        switch remainingPercent {
        case ...5:
            return .systemRed
        case ...10:
            return .systemYellow
        default:
            return .systemGreen
        }
    }
}

struct UsagePopover: View {
    @ObservedObject var model: UsageViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let output = model.output {
                VStack(spacing: 7) {
                    BatteryUsageRow(
                        line: CodexUsageFormatter.usageLine(
                            label: "5h",
                            window: UsageWindowSnapshot(
                                usedPercent: Double(output.primaryUsedPercent),
                                windowMinutes: output.primaryWindowMinutes,
                                resetsAt: output.primaryResetAt
                            )
                        )
                    )

                    BatteryUsageRow(
                        line: CodexUsageFormatter.usageLine(
                            label: "1w",
                            window: UsageWindowSnapshot(
                                usedPercent: Double(output.secondaryUsedPercent),
                                windowMinutes: output.secondaryWindowMinutes,
                                resetsAt: output.secondaryResetAt
                            )
                        )
                    )
                }

                VStack(alignment: .leading, spacing: 3) {
                    DetailLine(label: "Update", value: "\(CodexUsageFormatter.timeFormatter.string(from: output.observedAt)) · \(output.stale ? "stale" : "fresh")")
                    DetailLine(label: "Source", value: "\(URL(fileURLWithPath: output.sourceFile).lastPathComponent):\(output.sourceLine)")
                }
                .font(.caption2)

                Divider()

                LaunchAtLoginRow(model: model)
            } else {
                Text(model.errorMessage ?? "No Codex usage snapshot found.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Refresh") {
                    model.refresh()
                }

                Button("Open Usage") {
                    model.openUsage()
                }

                Spacer()

                Button("Quit") {
                    model.quit()
                }
            }
        }
        .padding(14)
    }
}

struct LaunchAtLoginRow: View {
    @ObservedObject var model: UsageViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(
                isOn: Binding(
                    get: { model.launchAtLoginEnabled },
                    set: { model.setLaunchAtLoginEnabled($0) }
                )
            ) {
                HStack {
                    Text("Launch at Login")
                    Spacer(minLength: 8)
                    Text(model.launchAtLoginStatusText)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            if let message = model.launchAtLoginErrorMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.launchAtLoginStatusText == "Needs approval" {
                Text("Allow it in System Settings > Login Items.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if model.launchAtLoginStatusText == "Move to Applications" {
                Text("Install the app in Applications before enabling.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }
}

struct BatteryUsageRow: View {
    let line: CodexUsageFormatter.UsageLine

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(line.label)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .frame(width: 22, alignment: .leading)

                Text("\(line.remainingPercent)% left")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color)

                Spacer(minLength: 8)

                Text("reset \(line.remainingText)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            BatteryBar(remainingPercent: line.remainingPercent, height: 5)

            Text("reset \(line.resetText)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var color: Color {
        switch line.remainingPercent {
        case ...5:
            return .red
        case ...10:
            return .yellow
        default:
            return .green
        }
    }
}

struct BatteryBar: View {
    let remainingPercent: Int
    let height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(Color.secondary.opacity(0.16))

                RoundedRectangle(cornerRadius: height / 2)
                    .fill(color)
                    .frame(width: remainingPercent > 0 ? max(height, proxy.size.width * fillRatio) : 0)
            }
        }
        .frame(height: height)
    }

    private var fillRatio: CGFloat {
        CGFloat(max(0, min(100, remainingPercent))) / 100.0
    }

    private var color: Color {
        switch remainingPercent {
        case ...5:
            return .red
        case ...10:
            return .yellow
        default:
            return .green
        }
    }
}

struct DetailLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }
}
