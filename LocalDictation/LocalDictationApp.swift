import AppKit
import Observation
import SwiftUI

/// AppKit lifecycle: the delegate owns the menu bar, window and status item; SwiftUI only renders content.
@main
enum LocalDictationApp {
    static func main() {
        MainActor.assumeIsolated {
            // `run()` never returns, so this local keeps the (weakly held) delegate alive.
            let delegate = AppDelegate()
            NSApplication.shared.delegate = delegate
            NSApplication.shared.run()
        }
    }
}

/// Owns the menu bar and status item; window presentation lives in `AppViewModel`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About LocalDictation", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide LocalDictation", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit LocalDictation", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu
        let mainMenu = NSMenu()
        for submenu in [appMenu, fileMenu, editMenu, windowMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            mainMenu.addItem(item)
        }
        NSApp.mainMenu = mainMenu

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(showWindow)
        trackStatusIcon()

        AppViewModel.shared.showWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Dock click, or relaunch from Finder/Spotlight while running, brings the window back.
        AppViewModel.shared.showWindow()
        return false
    }

    private func trackStatusIcon() {
        withObservationTracking {
            let state = AppViewModel.shared.service.state
            let image = NSImage(systemSymbolName: state.symbol, accessibilityDescription: "LocalDictation")
            image?.isTemplate = true
            statusItem.button?.image = image
            statusItem.button?.toolTip = "LocalDictation — \(state.title)"
        } onChange: {
            Task { @MainActor in self.trackStatusIcon() }
        }
    }

    @objc private func showWindow() {
        AppViewModel.shared.showWindow()
    }
}

/// App-wide state and window presentation. Regular app by default (Dock icon, menu bar); Hide to Menu Bar
/// drops to the accessory policy — Dock icon gone, service still running behind the status item.
@MainActor
@Observable
final class AppViewModel {
    static let shared = AppViewModel()

    let service = ASRService()

    /// Terms that bias recognition, sent as the model's context. Persisted on every change.
    var hotwords = UserDefaults.standard.stringArray(forKey: "hotwords") ?? [] {
        didSet { UserDefaults.standard.set(hotwords, forKey: "hotwords") }
    }

    @ObservationIgnored private lazy var window: NSWindow = {
        let hosting = NSHostingController(rootView: PlaygroundView())
        // Bridge SwiftUI's navigationTitle/Subtitle and toolbar into the AppKit window.
        hosting.sceneBridgingOptions = [.title, .toolbars]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 520, height: 640))
        window.contentMinSize = NSSize(width: 460, height: 520)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("PlaygroundWindow")
        if !window.setFrameUsingName("PlaygroundWindow") { window.center() }
        return window
    }()

    private init() {}

    func showWindow() {
        NSApp.setActivationPolicy(.regular)
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// The only path to menu-bar-only mode; a plain close (red button, ⌘W) keeps the Dock icon.
    func hideToMenuBar() {
        window.close()
        NSApp.setActivationPolicy(.accessory)
    }
}

@MainActor
@Observable
final class ASRService {
    enum State {
        case stopped, loading, ready
        case failed(String)

        var title: String {
            switch self {
            case .stopped: "Stopped"
            case .loading: "Loading model…"
            case .ready: "Ready · \(Transcriber.modelName)"
            case .failed(let reason): "Failed: \(reason)"
            }
        }

        var symbol: String {
            switch self {
            case .stopped: "waveform.slash"
            case .loading: "waveform.badge.ellipsis"
            case .ready: "waveform"
            case .failed: "waveform.badge.exclamationmark"
            }
        }
    }

    private(set) var state = State.stopped
    let endpoint: URL
    private let port: UInt16 = 8765
    private let transcriber = Transcriber()
    private var server: HTTPServer?
    private var loading: Task<Void, Never>?
    private var unloading: Task<Void, Never>?

    var isRunning: Bool {
        if case .stopped = state { false } else if case .failed = state { false } else { true }
    }

    init() {
        endpoint = URL(string: "http://127.0.0.1:\(port)/v1")!
        start()
    }

    /// Binds the HTTP listener and loads the model.
    func start() {
        do {
            server = try server ?? HTTPServer(port: port, transcriber: transcriber)
        } catch {
            state = .failed("port \(port): \(error.localizedDescription)")
            return
        }
        state = .loading
        loading = Task { [unloading, transcriber] in
            // Load → unload → load stays ordered: wait for any pending unload from a prior stop.
            await unloading?.value
            do {
                try await transcriber.load()
                guard !Task.isCancelled else { return }
                state = .ready
            } catch {
                guard !Task.isCancelled else { return }
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Releases the port and the model's memory.
    func stop() {
        let pending = loading
        pending?.cancel()
        loading = nil
        server = nil
        state = .stopped
        // Unload only after an in-flight load settles, so it cannot resurrect the weights.
        unloading = Task { [transcriber] in
            await pending?.value
            await transcriber.unload()
        }
    }

    func transcribe(_ samples: [Float], language: String?, hotwords: String?) async throws -> Qwen3ASRModel.Output {
        try await transcriber.transcribe(samples, language: language, hotwords: hotwords)
    }
}
