import AppKit
import ChessArenaCore
import SwiftUI

@MainActor
final class ArenaDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let runtime = MatchRuntime()
    private var windows: [NSWindow] = []
    private var lockedFrame: [ObjectIdentifier: NSSize] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let programSize = NSSize(width: CGFloat(StageMetrics.width), height: CGFloat(StageMetrics.height))
        let controlSize = NSSize(width: 500, height: 700)
        let program = makeWindow(
            title: "ChessArena Program",
            rect: NSRect(
                x: visible.minX,
                y: max(visible.minY, visible.maxY - programSize.height),
                width: programSize.width,
                height: programSize.height
            ),
            size: programSize,
            borderless: true,
            root: ProgramView(runtime: runtime)
        )
        program.isMovableByWindowBackground = true

        let control = makeWindow(
            title: "ChessArena Control",
            rect: NSRect(
                x: min(visible.maxX - controlSize.width, visible.minX + programSize.width + 16),
                y: max(visible.minY, visible.maxY - controlSize.height),
                width: controlSize.width,
                height: controlSize.height
            ),
            size: controlSize,
            borderless: false,
            root: ControlView(runtime: runtime)
        )
        windows = [program, control]
        lock(program, content: programSize)
        lock(control, content: controlSize)
        program.makeKeyAndOrderFront(nil)
        control.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        lockedFrame[ObjectIdentifier(sender)] ?? frameSize
    }

    private func lock(_ window: NSWindow, content: NSSize) {
        let origin = window.frame.origin
        let frame = window.frameRect(forContentRect: NSRect(origin: origin, size: content))
        window.delegate = self
        window.setFrame(frame, display: true)
        lockedFrame[ObjectIdentifier(window)] = frame.size
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func makeWindow<Content: View>(
        title: String,
        rect: NSRect,
        size: NSSize,
        borderless: Bool,
        root: Content
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: rect,
            styleMask: borderless ? [.borderless] : [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isRestorable = false
        window.sharingType = .readOnly
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        host.sizingOptions = []
        window.contentView = host
        window.setContentSize(size)
        window.contentMinSize = size
        window.contentMaxSize = size
        return window
    }
}

@main
enum ArenaMain {
    static func main() {
        let app = NSApplication.shared
        if let index = CommandLine.arguments.firstIndex(of: "--preview"), CommandLine.arguments.count > index + 1 {
            let board = BoardScene()
            board.applyCamera(at: 0)
            if let image = board.renderFrame(), let tiff = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
                do { try png.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])); print("Preview saved") }
                catch { print("Preview write failed"); exit(1) }
            } else { print("Preview render failed"); exit(1) }
            return
        }
        let delegate = ArenaDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
