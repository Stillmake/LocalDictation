import SwiftUI

struct MainView: View {
    private var service: ASRService { AppViewModel.shared.service }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive
    @State private var dictation = LiveDictation()
    @State private var isEditingHotwords = false
    @State private var isChoosingModel = false

    var body: some View {
        Group {
            if service.modelFolder == nil {
                ContentUnavailableView {
                    Label("No Model", systemImage: "folder.badge.questionmark")
                } description: {
                    Text("Choose a folder holding a Qwen3-ASR MLX model.")
                } actions: {
                    Button("Choose Model Folder…") { isChoosingModel = true }
                }
                .fileImporter(isPresented: $isChoosingModel, allowedContentTypes: [.folder], onCompletion: useModelFolder)
                .navigationTitle("LocalDictation")
                .navigationSubtitle(service.state.title)
                .buttonBorderShape(.capsule)
            } else {
                Form {
                    Section {
                        ScrollView {
                            Text(dictation.text.isEmpty ? (service.isRunning ? "Dictate with the microphone button" : "Start the service to dictate") : dictation.text)
                                .foregroundStyle(dictation.text.isEmpty ? .tertiary : .primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        .frame(height: 72)
                        .padding(.bottom, 32)
                        .overlay(alignment: .bottomLeading) {
                            Button {
                                dictation.toggle()
                            } label: {
                                Group {
                                    switch dictation.state {
                                    case .idle:
                                        Image(systemName: "mic")
                                            .font(.system(size: 12, weight: .bold))
                                    case .starting:
                                        ProgressView().controlSize(.mini)
                                    case .recording:
                                        RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 10, height: 10)
                                    case .failed:
                                        Image(systemName: "exclamationmark.triangle")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(.orange)
                                    }
                                }
                                .frame(width: 24, height: 24)
                                .background {
                                    ZStack {
                                        Circle().fill(Color(nsColor: .labelColor).opacity(0.2))
                                        if dictation.state == .recording {
                                            // Swells with the input level.
                                            Circle().fill(.red)
                                                .scaleEffect(reduceMotion ? 1 : 1 + 0.2 * CGFloat(min(dictation.level * 8, 1)))
                                        }
                                    }
                                }
                                .animation(.default, value: dictation.state)
                                .animation(.default, value: dictation.level)
                            }
                            .buttonStyle(.plain)
                            // Stopping stays possible even if the model went away mid-session.
                            .disabled(!service.isRunning && dictation.state != .starting && dictation.state != .recording)
                            .help({
                                if case .failed(let message) = dictation.state { return message }
                                return dictation.state == .recording ? "Stop Dictation" : "Dictate"
                            }())
                            .accessibilityLabel(dictation.state == .recording ? "Stop Dictation" : "Dictate")
                        }
                        .overlay(alignment: .bottomTrailing) {
                            if !dictation.text.isEmpty {
                                Button {
                                    dictation.clear()
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 12, weight: .bold))
                                        .frame(width: 24, height: 24)
                                        .background(Color(nsColor: .labelColor).opacity(0.2), in: .circle)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Clear")
                                .transition(.blurReplace)
                            }
                        }
                        .animation(.default, value: dictation.text.isEmpty)
                    } header: {
                        HStack {
                            Text("Dictation")
                            Spacer()
                            if let detected = dictation.language {
                                Text(detected).foregroundStyle(.secondary)
                            }
                            Button("Copy Transcript", systemImage: "doc.on.doc") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(dictation.text, forType: .string)
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .disabled(dictation.text.isEmpty)
                        }
                    }

                    Section("Options") {
                        LabeledContent("Hotwords") {
                            HStack {
                                let count = AppViewModel.shared.hotwords.count
                                Text(count == 0 ? "None" : "\(count)")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                Button("Edit…") { isEditingHotwords = true }
                            }
                        }
                        .sheet(isPresented: $isEditingHotwords) { HotwordsSheet() }
                        Toggle("Launch at Login", isOn: Bindable(AppViewModel.shared).launchAtLogin)
                            .help("Start LocalDictation hidden in the menu bar when you log in")
                    }
                    .disabled(dictation.state == .starting || dictation.state == .recording)

                    Section {
                        LabeledContent("Endpoint") {
                            HStack(spacing: 6) {
                                Text(service.endpoint.absoluteString)
                                    .monospaced()
                                    .textSelection(.enabled)
                                Button("Copy Endpoint", systemImage: "doc.on.doc") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(service.endpoint.absoluteString, forType: .string)
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                            }
                        }
                    } footer: {
                        Text("Apps on this Mac can send audio to this OpenAI-compatible endpoint.")
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
                .alert(
                    service.missingModel?.errorDescription ?? "",
                    isPresented: Binding { service.missingModel != nil } set: { if !$0 { service.missingModel = nil } },
                    presenting: service.missingModel
                ) { _ in
                } message: { missing in
                    Text(missing.recoverySuggestion!)
                }
                .safeAreaBar(edge: .bottom) {
                    HStack {
                        Button("Replace Model Folder…", systemImage: "folder") { isChoosingModel = true }
                            .help(service.modelFolder?.path(percentEncoded: false) ?? "")
                            .disabled(dictation.state == .starting || dictation.state == .recording)
                            .fileImporter(isPresented: $isChoosingModel, allowedContentTypes: [.folder], onCompletion: useModelFolder)
                        Spacer()
                        #if DEBUG
                        Button {
                            dictation.stop(finalize: false)
                            service.clearModelFolder()
                        } label: {
                            Image(systemName: "folder.badge.minus")
                        }
                        #endif
                        Button("Hide to Menu Bar", systemImage: "menubar.arrow.up.rectangle") { AppViewModel.shared.hideToMenuBar() }
                            .help("Close this window and keep LocalDictation running in the menu bar")
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                }
                .navigationTitle("LocalDictation")
                .navigationSubtitle(service.state.title)
                .buttonBorderShape(.capsule)
                .toolbar {
                    ToolbarSpacer(.flexible)
                    ToolbarItemGroup(placement: .automatic) {
                        if service.isRunning {
                            Button("Stop Service", systemImage: "stop.fill") {
                                dictation.stop(finalize: false)
                                service.stop()
                            }
                            .help("Stop the service and free the model's memory")
                        } else {
                            Button("Start Service", systemImage: "play.fill") { service.start() }
                                .help("Start the endpoint; the model loads on the first request")
                        }
                        Button("Quit", systemImage: "power") { NSApplication.shared.terminate(nil) }
                            .help("Quit LocalDictation")
                    }
                }
            }
        }
        // Coming back to the window re-checks the folder, catching a model deleted or installed meanwhile.
        .onChange(of: appearsActive, initial: true) { _, active in
            guard active else { return }
            let folder = service.modelFolder
            service.refreshModelFolder()
            if service.modelFolder != folder { dictation.stop(finalize: false) }
        }
    }

    /// Picker completion for both screens; a folder failing validation leaves the current model in place.
    private func useModelFolder(_ result: Result<URL, any Error>) {
        do {
            try service.useModelFolder(result.get())
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
