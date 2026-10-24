import AVFoundation
import Foundation
import MLX

/// Owns the single resident Qwen3-ASR model. Actor isolation serializes inference across all clients.
actor Transcriber {
    struct NotReady: LocalizedError {
        var errorDescription: String? { "model is not loaded yet" }
    }

    static let modelName = "Qwen3-ASR-0.6B-8bit"

    private var model: Qwen3ASRModel?

    var isReady: Bool { model != nil }

    struct ModelMissing: LocalizedError {
        let files: [String]
        var errorDescription: String? { "Model files missing: \(files.joined(separator: ", "))" }
        var recoverySuggestion: String? { "Run ./update-model.sh in the project folder, then rebuild." }
    }

    /// Loads the model whose files the folder-synchronized group copies flat into `Contents/Resources`.
    func load() throws {
        guard model == nil else { return }
        let resources = Bundle.main.resourceURL!
        // Name what's absent up front; otherwise a missing file surfaces as an opaque read or weight-key error.
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: resources.path(percentEncoded: false))) ?? []
        let missing = ["config.json", "vocab.json", "merges.txt", "tokenizer_config.json"].filter { !contents.contains($0) }
            + (contents.contains { $0.hasSuffix(".safetensors") } ? [] : ["*.safetensors"])
        guard missing.isEmpty else { throw ModelMissing(files: missing) }
        model = try Qwen3ASRModel.load(from: resources)
    }

    /// Drops the weights and returns MLX's buffer cache to the system.
    func unload() {
        model = nil
        Memory.clearCache()
    }

    /// `hotwords` lands in the system-prompt context slot, biasing decoding toward those terms.
    func transcribe(_ audioURL: URL, language: String?, hotwords: String?) throws -> Qwen3ASRModel.Output {
        guard let model else { throw NotReady() }

        // Decode any AVAudioFile format and resample + downmix to 16 kHz mono Float32 in one conversion.
        let file = try AVAudioFile(forReading: audioURL)
        let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(Qwen3ASRModel.sampleRate), channels: 1, interleaved: false
        )!
        let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: source)
        let converter = AVAudioConverter(from: file.processingFormat, to: target)!
        converter.downmix = true
        let output = AVAudioPCMBuffer(
            pcmFormat: target,
            frameCapacity: AVAudioFrameCount(Double(source.frameLength) * target.sampleRate / file.processingFormat.sampleRate) + 1
        )!
        var supplied = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            defer { supplied = true }
            status.pointee = supplied ? .endOfStream : .haveData
            return supplied ? nil : source
        }
        if let conversionError { throw conversionError }

        let samples = Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
        return try transcribe(samples, language: language, hotwords: hotwords)
    }

    /// `samples`: mono 16 kHz Float32.
    func transcribe(_ samples: [Float], language: String?, hotwords: String?) throws -> Qwen3ASRModel.Output {
        guard let model else { throw NotReady() }
        return model.transcribe(MLXArray(samples), context: hotwords ?? "", language: language)
    }
}
