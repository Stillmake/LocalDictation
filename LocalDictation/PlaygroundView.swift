import SwiftUI

struct PlaygroundView: View {
    private var service: ASRService { AppViewModel.shared.service }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dictation = LiveDictation()
    @State private var isEditingHotwords = false

    var body: some View {
        Form {
            Section {
                ScrollView {
                    Text(dictation.text.isEmpty ? (isReady ? "Dictate with the microphone button" : service.isRunning ? "The model is loading…" : "Start the service to dictate") : dictation.text)
                        .foregroundStyle(dictation.text.isEmpty ? .tertiary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(minHeight: 180)
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
                        .keyboardShortcut("r", modifiers: .command)
                        // Stopping stays possible even if the model went away mid-session.
                        .disabled(!isReady && dictation.state != .starting && dictation.state != .recording)
                        .help({
                            if case .failed(let message) = dictation.state { return message }
                            return dictation.state == .recording ? "Stop Dictation (⌘R)" : "Dictate (⌘R)"
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
                            .help("Clear")
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
                    .help("Copy Transcript")
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
                        .help("Copy Endpoint")
                    }
                }
            } footer: {
                Text("Apps on this Mac can send audio to this OpenAI-compatible endpoint.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .safeAreaBar(edge: .bottom) {
            HStack {
                Spacer()
                Button("Hide to Menu Bar", systemImage: "menubar.arrow.up.rectangle") { AppViewModel.shared.hideToMenuBar() }
                    .help("Close this window and keep LocalDictation running in the menu bar")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .navigationTitle("LocalDictation")
        .navigationSubtitle(service.state.title)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if service.isRunning {
                    Button("Stop Service", systemImage: "stop.fill") {
                        dictation.stop(finalize: false)
                        service.stop()
                    }
                    .help("Stop the service and free the model's memory")
                } else {
                    Button("Start Service", systemImage: "play.fill") { service.start() }
                        .help("Load the model and start the endpoint")
                }
                Button("Quit", systemImage: "power") { NSApplication.shared.terminate(nil) }
                    .help("Quit LocalDictation (⌘Q)")
            }
        }
    }

    private var isReady: Bool {
        if case .ready = service.state { true } else { false }
    }
}
