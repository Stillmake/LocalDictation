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
        statusItem.button?.image = NSImage(named: "menubar.icon")
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
            statusItem.button?.toolTip = "LocalDictation — \(AppViewModel.shared.service.state.title)"
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
        let hosting = NSHostingController(rootView: MainView())
        // Bridge SwiftUI's navigationTitle/Subtitle and toolbar into the AppKit window.
        hosting.sceneBridgingOptions = [.title, .toolbars]
        // The window owns its fixed size: otherwise SwiftUI's fitting size resizes it, and the small "No Model"
        // screen shrinks it.
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("PlaygroundWindow")
        if !window.setFrameUsingName("PlaygroundWindow") { window.center() }
        // After restoring, so only the saved position survives; a size saved while resizable is overridden.
        window.setContentSize(NSSize(width: 560, height:520))
        return window
    }()

    private init() {}

    func showWindow() {
        NSApp.setActivationPolicy(.regular)
        if window.isMiniaturized { window.deminiaturize(nil) }
        // Coming back from the accessory policy, `activate()` is only a cooperative request and can be refused
        // or land before the policy switch settles, leaving the window behind the frontmost app.
        // `orderFrontRegardless` raises it either way.
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate()
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
        case stopped, loading
        case ready(String)
        case failed(String)

        var title: String {
            switch self {
            case .stopped: "Stopped"
            case .loading: "Loading model…"
            case .ready(let model): "Ready · \(model)"
            case .failed(let reason): "Failed: \(reason)"
            }
        }
    }

    private(set) var state = State.stopped
    /// The validated model folder, persisted by path; `nil` until the user picks one.
    private(set) var modelFolder = UserDefaults.standard.string(forKey: "modelFolder").map { URL(filePath: $0, directoryHint: .isDirectory) }
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

    /// Validates `folder` before adopting it, so a bad pick never replaces a working model; reloads if running.
    func useModelFolder(_ folder: URL) throws {
        try Transcriber.validate(folder)
        modelFolder = folder
        UserDefaults.standard.set(folder.path(percentEncoded: false), forKey: "modelFolder")
        if isRunning { stop() }
        start()
    }

    #if DEBUG
    /// Forgets the saved folder and unloads the model, returning to the "No Model" screen.
    func clearModelFolder() {
        stop()
        modelFolder = nil
        UserDefaults.standard.removeObject(forKey: "modelFolder")
    }
    #endif

    /// Binds the HTTP listener and loads the model.
    func start() {
        guard let modelFolder else {
            state = .failed("choose a model folder")
            return
        }
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
                try await transcriber.load(from: modelFolder)
                guard !Task.isCancelled else { return }
                state = .ready(modelFolder.lastPathComponent)
            } catch {
                guard !Task.isCancelled else { return }
                state = .failed(error.localizedDescription)
                if let missing = error as? Transcriber.ModelMissing {
                    // The saved folder changed since it was picked; say so instead of leaving only a status line.
                    let alert = NSAlert()
                    alert.alertStyle = .critical
                    alert.messageText = missing.errorDescription!
                    alert.informativeText = missing.recoverySuggestion!
                    alert.runModal()
                }
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
