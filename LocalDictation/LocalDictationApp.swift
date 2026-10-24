import AppKit
import Observation
import ServiceManagement
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
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        NSApp.windowsMenu = windowMenu
        let mainMenu = NSMenu()
        for submenu in [appMenu, fileMenu, windowMenu] {
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

        // A login-item launch starts in the menu bar; the Apple event is only current during launch.
        let event = NSAppleEventManager.shared().currentAppleEvent
        if event?.eventID == kAEOpenApplication, event?.paramDescriptor(forKeyword: keyAELaunchedAsLogInItem)?.typeCodeValue == keyAELaunchedAsLogInItem {
            NSApp.setActivationPolicy(.accessory)
        } else {
            AppViewModel.shared.showWindow()
        }
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

    /// Mirrors the login item's registration; a launch at login starts hidden in the menu bar.
    var launchAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            do {
                try launchAtLogin ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
            } catch {
                NSAlert(error: error).runModal()
            }
            let enabled = SMAppService.mainApp.status == .enabled
            if launchAtLogin != enabled { launchAtLogin = enabled }
        }
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
        /// Listening with the model not yet loaded; the first transcription loads it.
        case standby(String)
        case ready(String)
        case failed(String)

        var title: String {
            switch self {
            case .stopped: "Stopped"
            case .standby(let model): "Standby · \(model)"
            case .loading: "Loading model…"
            case .ready(let model): "Ready · \(model)"
            case .failed(let reason): "Failed: \(reason)"
            }
        }
    }

    /// A server-side fault, so the endpoint answers 500 rather than blaming the request.
    struct LoadFailed: LocalizedError {
        let underlying: any Error
        var errorDescription: String? { "model failed to load: \(underlying.localizedDescription)" }
    }

    private(set) var state = State.stopped
    /// The validated model folder, persisted by path; `nil` until the user picks one.
    private(set) var modelFolder = UserDefaults.standard.string(forKey: "modelFolder").map { URL(filePath: $0, directoryHint: .isDirectory) }
    let endpoint: URL
    private let port: UInt16 = 8765
    private let transcriber = Transcriber()
    private var server: HTTPServer?
    private var loading: Task<Void, any Error>?
    private var unloading: Task<Void, Never>?
    /// Fires after 30 idle minutes to free the model; every transcription re-arms it.
    private var idleRelease: Task<Void, Never>?

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

    /// Binds the HTTP listener; the model loads on the first transcription.
    func start() {
        guard let modelFolder else {
            state = .failed("choose a model folder")
            return
        }
        do {
            server = try server ?? HTTPServer(port: port, service: self)
        } catch {
            state = .failed("port \(port): \(error.localizedDescription)")
            return
        }
        state = .standby(modelFolder.lastPathComponent)
    }

    /// Releases the port and the model's memory.
    func stop() {
        server = nil
        state = .stopped
        unload()
    }

    /// The served model's name, known before it loads, so clients can list it while on standby.
    var modelName: String? {
        switch state {
        case .standby(let name), .ready(let name): name
        case .loading: modelFolder?.lastPathComponent
        case .stopped, .failed: nil
        }
    }

    func transcribe(_ samples: [Float], language: String?, hotwords: String?) async throws -> Qwen3ASRModel.Output {
        try await prepare()
        defer { armIdleRelease() }
        return try await transcriber.transcribe(samples, language: language, hotwords: hotwords)
    }

    func transcribe(_ audioURL: URL, language: String?, hotwords: String?) async throws -> Qwen3ASRModel.Output {
        try await prepare()
        defer { armIdleRelease() }
        return try await transcriber.transcribe(audioURL, language: language, hotwords: hotwords)
    }

    /// Loads the model if needed; concurrent callers share one load. Disarms the idle release, so it cannot
    /// unload between here and the transcription.
    private func prepare() async throws {
        idleRelease?.cancel()
        if case .ready = state { return }
        if loading == nil {
            guard server != nil, let modelFolder else { throw Transcriber.NotReady() }
            state = .loading
            loading = Task { [unloading, transcriber] in
                // Load → unload → load stays ordered: wait for any pending unload from a prior release.
                await unloading?.value
                do {
                    try await transcriber.load(from: modelFolder)
                    try Task.checkCancellation()
                    state = .ready(modelFolder.lastPathComponent)
                } catch {
                    guard !Task.isCancelled else { throw error }
                    state = .failed(error.localizedDescription)
                    // A later Start retries instead of replaying this failure.
                    loading = nil
                    if let missing = error as? Transcriber.ModelMissing {
                        // The saved folder changed since it was picked; say so instead of leaving only a status line.
                        let alert = NSAlert()
                        alert.alertStyle = .critical
                        alert.messageText = missing.errorDescription!
                        alert.informativeText = missing.recoverySuggestion!
                        alert.runModal()
                    }
                    throw LoadFailed(underlying: error)
                }
            }
        }
        try await loading!.value
    }

    private func armIdleRelease() {
        idleRelease?.cancel()
        idleRelease = Task {
            try? await Task.sleep(for: .seconds(30 * 60))
            guard !Task.isCancelled, case .ready(let name) = state else { return }
            unload()
            state = .standby(name)
        }
    }

    /// Frees the model's memory, keeping the port.
    private func unload() {
        idleRelease?.cancel()
        let pending = loading
        pending?.cancel()
        loading = nil
        // Unload only after an in-flight load settles, so it cannot resurrect the weights.
        unloading = Task { [transcriber] in
            _ = try? await pending?.value
            await transcriber.unload()
        }
    }
}
