import SwiftUI

struct PlaygroundView: View {
    private var service: ASRService { AppViewModel.shared.service }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dictation = LiveDictation()
    @State private var isEditingHotwords = false

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    Button {
                        if dictation.isRecording {
                            dictation.stop()
                        } else {
                            Task {
                                await dictation.start()
                            }
                        }
                    } label: {
                        Image(systemName: dictation.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 26, weight: .semibold))
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 64, height: 64)
                            .foregroundStyle(.white)
                            .background(dictation.isRecording ? Color.red : Color.accentColor, in: .circle)
                            .overlay {
                                // Input level ring: grows with the smoothed RMS while recording.
                                Circle()
                                    .stroke(Color.red.opacity(0.35), lineWidth: 6)
                                    .scaleEffect(reduceMotion ? 1 : 1 + CGFloat(min(dictation.level * 8, 1)) * 0.35)
                                    .opacity(dictation.isRecording ? 1 : 0)
                                    .animation(.easeOut(duration: 0.25), value: dictation.level)
                            }
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!isReady && !dictation.isRecording)
                    .help(dictation.isRecording ? "Stop Dictation (⌘R)" : "Start Dictation (⌘R)")
                    .accessibilityLabel(dictation.isRecording ? "Stop Dictation" : "Start Dictation")

                    if let startDate = dictation.startDate, dictation.isRecording {
                        Text(startDate, style: .timer)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        Text(isReady ? "Press to dictate" : service.isRunning ? "The model is loading…" : "Start the service to dictate")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)

                Group {
                    if let error = dictation.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    } else if dictation.text.isEmpty {
                        Text(dictation.isRecording ? "Listening…" : "The transcript appears here as you speak.")
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    } else {
                        // Committed text is final; the volatile tail is the open segment's latest hypothesis.
                        Text("\(dictation.committed)\(Text(dictation.text.dropFirst(dictation.committed.count)).foregroundStyle(.secondary))")
                            .lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                .textSelection(.enabled)
                .frame(minHeight: 120, alignment: .top)
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
            .disabled(dictation.isRecording)

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
                        dictation.stop()
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
