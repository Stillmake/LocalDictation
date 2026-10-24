import AVFoundation
import Observation

/// Dictation into an editable text. Live over a batch model: the open segment is re-decoded every tick and
/// shown as its volatile tail; a pause (or the length cap) finalizes it — one last decode, committed, audio
/// dropped — so each re-decode costs a bounded amount regardless of session length.
///
/// The editor text present at start is a fixed prefix the transcript is appended to. Any user edit ends the
/// session and drops results still in flight: the editor is the user's again.
@MainActor
@Observable
final class LiveDictation {
    enum State: Equatable {
        case idle, starting, recording
        case failed(String)
    }

    private(set) var state = State.idle
    /// Editor content: the user's text plus this session's transcript.
    private(set) var text = ""
    private(set) var language: String?
    /// Smoothed input RMS, 0…1, for the level indicator.
    private(set) var level: Float = 0

    @ObservationIgnored private var microphone: Microphone?
    /// Identifies the session allowed to write `text`; replacing it orphans every in-flight result.
    @ObservationIgnored private var session = UUID()
    /// The running session's loop, including its final flush after a finalizing stop.
    @ObservationIgnored private var loop: Task<Void, Never>?

    func toggle() {
        switch state {
        case .idle, .failed:
            Task { await start() }
        case .starting, .recording:
            stop(finalize: true)
        }
    }

    func userEdited(_ newValue: String) {
        text = newValue
        switch state {
        case .starting, .recording:
            stop(finalize: false)
        case .idle, .failed:
            // A finalizing stop's flush may still be pending; it must not overwrite the edit.
            session = UUID()
        }
    }

    /// Ends capture. Finalizing keeps the session so its loop flushes the open segment into `text`;
    /// otherwise the session is orphaned and nothing more is written.
    func stop(finalize: Bool) {
        guard state == .starting || state == .recording else { return }
        if !finalize { session = UUID() }
        microphone?.stop()
        microphone = nil
        state = .idle
    }

    private func start() async {
        let session = UUID()
        self.session = session
        state = .starting

        // Ask only while undetermined; a granted or denied decision is final until changed in System Settings.
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            break
        case .undetermined:
            guard await AVAudioApplication.requestRecordPermission() else {
                if self.session == session { state = .idle }
                return
            }
        default:
            state = .failed("Microphone access is off. Turn it on in System Settings › Privacy & Security › Microphone.")
            return
        }
        // The previous session's final flush lands in `text` before this one captures its prefix.
        await loop?.value
        guard self.session == session, state == .starting else { return }

        let microphone = Microphone()
        do {
            try microphone.start()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        self.microphone = microphone
        state = .recording
        language = nil
        let prefix = text
        // Snapshot for the session: every segment decodes against the same context.
        let hotwords = AppViewModel.shared.hotwords.isEmpty ? nil : AppViewModel.shared.hotwords.joined(separator: ", ")

        loop = Task {
            let sampleRate = Qwen3ASRModel.sampleRate
            var committed = ""
            while self.session == session {
                let recording = state == .recording
                if recording { try? await Task.sleep(for: .milliseconds(300)) }

                let segment = microphone.pending()
                level = recording ? max(Self.rms(segment.suffix(sampleRate / 10)), level * 0.6) : 0
                let duration = Double(segment.count) / Double(sampleRate)
                // 100 ms frame energies: a trailing ≥600 ms run below the floor marks a pause.
                let frames = stride(from: 0, to: segment.count, by: sampleRate / 10).map {
                    Self.rms(segment[$0..<min($0 + sampleRate / 10, segment.count)])
                }
                let silence: Float = 0.012
                let paused = frames.count >= 6 && frames.suffix(6).allSatisfy { $0 < silence }
                let hasSpeech = frames.contains { $0 >= silence }
                let finalize = !recording || (duration >= 2.5 && paused) || duration >= 20

                if finalize && !hasSpeech {
                    // Pure silence: drop it without spending a decode.
                    microphone.discard(segment.count)
                    text = Self.join(prefix, committed)
                } else if hasSpeech && (duration >= 0.5 || !recording) {
                    do {
                        let output = try await AppViewModel.shared.service.transcribe(
                            segment, language: nil, hotwords: hotwords
                        )
                        guard self.session == session else { break }
                        if output.language != nil { language = output.language }
                        if finalize {
                            committed = Self.join(committed, output.text)
                            microphone.discard(segment.count)
                            text = Self.join(prefix, committed)
                        } else {
                            text = Self.join(prefix, Self.join(committed, output.text))
                        }
                    } catch {
                        guard self.session == session else { break }
                        microphone.stop()
                        self.microphone = nil
                        state = .failed(error.localizedDescription)
                        break
                    }
                }
                if !recording { break }
            }
            level = 0
        }
    }

    private nonisolated static func rms(_ samples: some Collection<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    /// Space between segments unless either side is whitespace or a script written without spaces (CJK, kana, …).
    private static func join(_ head: String, _ tail: String) -> String {
        let tail = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = head.unicodeScalars.last, let first = tail.unicodeScalars.first else { return head + tail }
        let unspaced = { (scalar: Unicode.Scalar) in
            scalar.properties.isIdeographic
                || [0x0E00...0x0EFF, 0x1000...0x109F, 0x1780...0x17FF, 0x3000...0x30FF, 0xFF00...0xFFEF]
                    .contains { $0.contains(scalar.value) }
        }
        return last.properties.isWhitespace || unspaced(last) || unspaced(first) ? head + tail : head + " " + tail
    }
}

/// Default input device → 16 kHz mono Float32, accumulated until the consumer discards it.
private final class Microphone: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []

    func start() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(Qwen3ASRModel.sampleRate), channels: 1, interleaved: false
        )!
        let converter = AVAudioConverter(from: inputFormat, to: target)!
        converter.downmix = true

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            let output = AVAudioPCMBuffer(
                pcmFormat: target,
                frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / inputFormat.sampleRate) + 1
            )!
            var supplied = false
            // `.noDataNow` (not `.endOfStream`) keeps the converter's resampler state across tap buffers.
            converter.convert(to: output, error: nil) { _, status in
                defer { supplied = true }
                status.pointee = supplied ? .noDataNow : .haveData
                return supplied ? nil : buffer
            }
            guard let self, let channel = output.floatChannelData?[0] else { return }
            let converted = UnsafeBufferPointer(start: channel, count: Int(output.frameLength))
            self.lock.withLock { self.samples.append(contentsOf: converted) }
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    func pending() -> [Float] {
        lock.withLock { samples }
    }

    func discard(_ count: Int) {
        lock.withLock { samples.removeFirst(min(count, samples.count)) }
    }
}
