// Qwen3-ASR inference on MLX. Trimmed from mlx-audio-swift (MIT, © 2025 Prince Canuma):
// Models/Qwen3ASR/Qwen3ASR.swift and MLXAudioCore/DSP.swift. Greedy batch decoding only.

import Foundation
import MLX
import MLXNN

// MARK: - Config

struct Qwen3ASRConfig: Decodable {
    struct Audio: Decodable {
        let numMelBins: Int
        let encoderLayers: Int
        let encoderAttentionHeads: Int
        let encoderFfnDim: Int
        let dModel: Int
        let maxSourcePositions: Int
        let nWindow: Int
        let outputDim: Int
        let nWindowInfer: Int
        let downsampleHiddenSize: Int
    }

    struct Text: Decodable {
        let vocabSize: Int
        let hiddenSize: Int
        let intermediateSize: Int
        let numHiddenLayers: Int
        let numAttentionHeads: Int
        let numKeyValueHeads: Int
        let headDim: Int
        let rmsNormEps: Float
        let tieWordEmbeddings: Bool
        let ropeTheta: Float
    }

    struct Thinker: Decodable {
        let audioConfig: Audio
        let textConfig: Text
        let audioTokenId: Int
    }

    struct Quantization: Decodable {
        let groupSize: Int
        let bits: Int
        let mode: QuantizationMode?
    }

    let thinkerConfig: Thinker
    let supportLanguages: [String]
    let quantization: Quantization?
}

// MARK: - Audio Encoder

private final class EncoderAttention: Module {
    let numHeads: Int
    let headDim: Int

    @ModuleInfo(key: "q_proj") var qProj: Linear
    @ModuleInfo(key: "k_proj") var kProj: Linear
    @ModuleInfo(key: "v_proj") var vProj: Linear
    @ModuleInfo(key: "out_proj") var outProj: Linear

    init(_ config: Qwen3ASRConfig.Audio) {
        numHeads = config.encoderAttentionHeads
        headDim = config.dModel / numHeads
        _qProj.wrappedValue = Linear(config.dModel, config.dModel)
        _kProj.wrappedValue = Linear(config.dModel, config.dModel)
        _vProj.wrappedValue = Linear(config.dModel, config.dModel)
        _outProj.wrappedValue = Linear(config.dModel, config.dModel)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let (B, L) = (x.dim(0), x.dim(1))
        let split = { (t: MLXArray) in t.reshaped(B, L, self.numHeads, self.headDim).transposed(0, 2, 1, 3) }
        let output = MLXFast.scaledDotProductAttention(
            queries: split(qProj(x)), keys: split(kProj(x)), values: split(vProj(x)),
            scale: pow(Float(headDim), -0.5), mask: .none
        )
        return outProj(output.transposed(0, 2, 1, 3).reshaped(B, L, -1))
    }
}

private final class EncoderLayer: Module {
    @ModuleInfo(key: "self_attn") var selfAttn: EncoderAttention
    @ModuleInfo(key: "self_attn_layer_norm") var selfAttnLayerNorm: LayerNorm
    @ModuleInfo(key: "fc1") var fc1: Linear
    @ModuleInfo(key: "fc2") var fc2: Linear
    @ModuleInfo(key: "final_layer_norm") var finalLayerNorm: LayerNorm

    init(_ config: Qwen3ASRConfig.Audio) {
        _selfAttn.wrappedValue = EncoderAttention(config)
        _selfAttnLayerNorm.wrappedValue = LayerNorm(dimensions: config.dModel)
        _fc1.wrappedValue = Linear(config.dModel, config.encoderFfnDim)
        _fc2.wrappedValue = Linear(config.encoderFfnDim, config.dModel)
        _finalLayerNorm.wrappedValue = LayerNorm(dimensions: config.dModel)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let h = x + selfAttn(selfAttnLayerNorm(x))
        return h + fc2(gelu(fc1(finalLayerNorm(h))))
    }
}

private final class AudioEncoder: Module {
    let nWindow: Int
    let nWindowInfer: Int
    // Leading underscore keeps the precomputed table out of the module's parameter tree.
    let _positionalEmbedding: MLXArray

    @ModuleInfo(key: "conv2d1") var conv2d1: Conv2d
    @ModuleInfo(key: "conv2d2") var conv2d2: Conv2d
    @ModuleInfo(key: "conv2d3") var conv2d3: Conv2d
    @ModuleInfo(key: "conv_out") var convOut: Linear
    @ModuleInfo(key: "layers") var layers: [EncoderLayer]
    @ModuleInfo(key: "ln_post") var lnPost: LayerNorm
    @ModuleInfo(key: "proj1") var proj1: Linear
    @ModuleInfo(key: "proj2") var proj2: Linear

    init(_ config: Qwen3ASRConfig.Audio) {
        nWindow = config.nWindow
        nWindowInfer = config.nWindowInfer

        // Sinusoidal table: [sin | cos] over log-spaced timescales up to 10⁴.
        let half = config.dModel / 2
        let invTimescales = exp(-log(Float(10_000)) / Float(half - 1) * MLXArray(0..<half).asType(.float32))
        let scaledTime = MLXArray(0..<config.maxSourcePositions).asType(.float32).reshaped(-1, 1) * invTimescales
        _positionalEmbedding = concatenated([sin(scaledTime), cos(scaledTime)], axis: 1)

        let hidden = config.downsampleHiddenSize
        _conv2d1.wrappedValue = Conv2d(inputChannels: 1, outputChannels: hidden, kernelSize: 3, stride: 2, padding: 1)
        _conv2d2.wrappedValue = Conv2d(inputChannels: hidden, outputChannels: hidden, kernelSize: 3, stride: 2, padding: 1)
        _conv2d3.wrappedValue = Conv2d(inputChannels: hidden, outputChannels: hidden, kernelSize: 3, stride: 2, padding: 1)
        // Mel bins after three stride-2 convolutions: ⌈⌈⌈n/2⌉/2⌉/2⌉.
        let freqAfterConv = ((((config.numMelBins + 1) / 2) + 1) / 2 + 1) / 2
        _convOut.wrappedValue = Linear(hidden * freqAfterConv, config.dModel, bias: false)
        _layers.wrappedValue = (0..<config.encoderLayers).map { _ in EncoderLayer(config) }
        _lnPost.wrappedValue = LayerNorm(dimensions: config.dModel)
        _proj1.wrappedValue = Linear(config.dModel, config.dModel)
        _proj2.wrappedValue = Linear(config.dModel, config.outputDim)
    }

    /// `mel`: [nMels, nFrames] → [tokens, outputDim].
    func callAsFunction(_ mel: MLXArray) -> MLXArray {
        let nFrames = mel.dim(1)
        let chunkSize = nWindow * 2
        let chunkStarts = Array(stride(from: 0, to: nFrames, by: chunkSize))
        let chunkLengths = chunkStarts.map { min(chunkSize, nFrames - $0) }
        // Full-width zero padding of the tail chunk preserves the reference conv boundary behavior.
        let chunks = zip(chunkStarts, chunkLengths).map { start, length in
            padded(mel[0..., start..<(start + length)], widths: [IntOrPair((0, 0)), IntOrPair((0, chunkSize - length))])
        }
        let lengthsAfterConv = chunkLengths.map { (0..<3).reduce($0) { length, _ in (length + 1) / 2 } }

        var hidden: [MLXArray] = []
        var chunkIndex = 0
        for batchStart in stride(from: 0, to: chunks.count, by: 128) {
            let batch = Array(chunks[batchStart..<min(batchStart + 128, chunks.count)])
            var x = stacked(batch, axis: 0).expandedDimensions(axis: -1)  // [b, mels, t, 1]
            x = gelu(conv2d3(gelu(conv2d2(gelu(conv2d1(x))))))
            let (f, t, c) = (x.dim(1), x.dim(2), x.dim(3))
            x = convOut(x.transposed(0, 2, 3, 1).reshaped(batch.count, t, c * f))
            x = x + _positionalEmbedding[0..<t].expandedDimensions(axis: 0)
            eval(x)
            for i in 0..<batch.count {
                hidden.append(x[i, 0..<lengthsAfterConv[chunkIndex]])
                chunkIndex += 1
            }
        }
        let sequence = concatenated(hidden, axis: 0)

        // Full self-attention within each window of `nWindowInfer / chunkSize` chunks, none across windows.
        let chunksPerWindow = max(1, nWindowInfer / chunkSize)
        var windowsByLength: [Int: [(index: Int, data: MLXArray)]] = [:]
        var offset = 0
        for (index, windowStart) in stride(from: 0, to: lengthsAfterConv.count, by: chunksPerWindow).enumerated() {
            let length = lengthsAfterConv[windowStart..<min(windowStart + chunksPerWindow, lengthsAfterConv.count)].reduce(0, +)
            windowsByLength[length, default: []].append((index, sequence[offset..<(offset + length)]))
            offset += length
        }

        var processed: [(index: Int, data: MLXArray)] = []
        for group in windowsByLength.values {
            for batchStart in stride(from: 0, to: group.count, by: 256) {
                let items = group[batchStart..<min(batchStart + 256, group.count)]
                var batch = stacked(items.map(\.data), axis: 0)
                for layer in layers {
                    batch = layer(batch)
                }
                eval(batch)
                processed += items.enumerated().map { j, item in (item.index, batch[j]) }
            }
        }
        let encoded = concatenated(processed.sorted { $0.index < $1.index }.map(\.data), axis: 0)
        return proj2(gelu(proj1(lnPost(encoded))))
    }
}

// MARK: - Text Decoder

/// Growable KV buffer, preallocated in steps of 256 positions to avoid per-token concatenation.
private final class KVCache {
    private(set) var offset = 0
    private var keys: MLXArray?
    private var values: MLXArray?

    func update(keys newKeys: MLXArray, values newValues: MLXArray) -> (MLXArray, MLXArray) {
        let previous = offset
        let count = newKeys.dim(2)
        if keys == nil || previous + count > keys!.dim(2) {
            let (B, H, D) = (newKeys.dim(0), newKeys.dim(1), newKeys.dim(3))
            let grow = ((count + 255) / 256) * 256
            let extraKeys = MLXArray.zeros([B, H, grow, D], dtype: newKeys.dtype)
            let extraValues = MLXArray.zeros([B, H, grow, newValues.dim(3)], dtype: newValues.dtype)
            if let keys, let values {
                self.keys = concatenated([keys[.ellipsis, ..<previous, 0...], extraKeys], axis: 2)
                self.values = concatenated([values[.ellipsis, ..<previous, 0...], extraValues], axis: 2)
            } else {
                keys = extraKeys
                values = extraValues
            }
        }
        offset += count
        keys![.ellipsis, previous..<offset, 0...] = newKeys
        values![.ellipsis, previous..<offset, 0...] = newValues
        return (keys![.ellipsis, ..<offset, 0...], values![.ellipsis, ..<offset, 0...])
    }
}

private final class DecoderAttention: Module {
    let numHeads: Int
    let numKvHeads: Int
    let headDim: Int
    let rope: RoPE

    @ModuleInfo(key: "q_proj") var qProj: Linear
    @ModuleInfo(key: "k_proj") var kProj: Linear
    @ModuleInfo(key: "v_proj") var vProj: Linear
    @ModuleInfo(key: "o_proj") var oProj: Linear
    @ModuleInfo(key: "q_norm") var qNorm: RMSNorm
    @ModuleInfo(key: "k_norm") var kNorm: RMSNorm

    init(_ config: Qwen3ASRConfig.Text) {
        numHeads = config.numAttentionHeads
        numKvHeads = config.numKeyValueHeads
        headDim = config.headDim
        rope = RoPE(dimensions: headDim, traditional: false, base: config.ropeTheta)
        _qProj.wrappedValue = Linear(config.hiddenSize, numHeads * headDim, bias: false)
        _kProj.wrappedValue = Linear(config.hiddenSize, numKvHeads * headDim, bias: false)
        _vProj.wrappedValue = Linear(config.hiddenSize, numKvHeads * headDim, bias: false)
        _oProj.wrappedValue = Linear(numHeads * headDim, config.hiddenSize, bias: false)
        _qNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: config.rmsNormEps)
        _kNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: config.rmsNormEps)
    }

    func callAsFunction(_ x: MLXArray, cache: KVCache) -> MLXArray {
        let (B, L) = (x.dim(0), x.dim(1))
        let queries = rope(qNorm(qProj(x).reshaped(B, L, numHeads, headDim)).transposed(0, 2, 1, 3), offset: cache.offset)
        let keys = rope(kNorm(kProj(x).reshaped(B, L, numKvHeads, headDim)).transposed(0, 2, 1, 3), offset: cache.offset)
        let values = vProj(x).reshaped(B, L, numKvHeads, headDim).transposed(0, 2, 1, 3)
        let (cachedKeys, cachedValues) = cache.update(keys: keys, values: values)
        // `.causal` aligns to the bottom-right, so chunked prefill over an existing cache stays correct.
        let output = MLXFast.scaledDotProductAttention(
            queries: queries, keys: cachedKeys, values: cachedValues,
            scale: pow(Float(headDim), -0.5), mask: L > 1 ? .causal : .none
        )
        return oProj(output.transposed(0, 2, 1, 3).reshaped(B, L, -1))
    }
}

private final class DecoderMLP: Module {
    @ModuleInfo(key: "gate_proj") var gateProj: Linear
    @ModuleInfo(key: "up_proj") var upProj: Linear
    @ModuleInfo(key: "down_proj") var downProj: Linear

    init(_ config: Qwen3ASRConfig.Text) {
        _gateProj.wrappedValue = Linear(config.hiddenSize, config.intermediateSize, bias: false)
        _upProj.wrappedValue = Linear(config.hiddenSize, config.intermediateSize, bias: false)
        _downProj.wrappedValue = Linear(config.intermediateSize, config.hiddenSize, bias: false)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        downProj(silu(gateProj(x)) * upProj(x))
    }
}

private final class DecoderLayer: Module {
    @ModuleInfo(key: "self_attn") var selfAttn: DecoderAttention
    @ModuleInfo(key: "mlp") var mlp: DecoderMLP
    @ModuleInfo(key: "input_layernorm") var inputLayernorm: RMSNorm
    @ModuleInfo(key: "post_attention_layernorm") var postAttentionLayernorm: RMSNorm

    init(_ config: Qwen3ASRConfig.Text) {
        _selfAttn.wrappedValue = DecoderAttention(config)
        _mlp.wrappedValue = DecoderMLP(config)
        _inputLayernorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        _postAttentionLayernorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
    }

    func callAsFunction(_ x: MLXArray, cache: KVCache) -> MLXArray {
        let h = x + selfAttn(inputLayernorm(x), cache: cache)
        return h + mlp(postAttentionLayernorm(h))
    }
}

private final class TextModel: Module {
    @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding
    @ModuleInfo(key: "layers") var layers: [DecoderLayer]
    @ModuleInfo(key: "norm") var norm: RMSNorm

    init(_ config: Qwen3ASRConfig.Text) {
        _embedTokens.wrappedValue = Embedding(embeddingCount: config.vocabSize, dimensions: config.hiddenSize)
        _layers.wrappedValue = (0..<config.numHiddenLayers).map { _ in DecoderLayer(config) }
        _norm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
    }

    func callAsFunction(_ embeddings: MLXArray, caches: [KVCache]) -> MLXArray {
        norm(zip(layers, caches).reduce(embeddings) { h, pair in pair.0(h, cache: pair.1) })
    }
}

// MARK: - Model

final class Qwen3ASRModel: Module {
    struct Output: Sendable {
        let text: String
        let language: String?
    }

    static let sampleRate = 16_000

    private let config: Qwen3ASRConfig
    private let tokenizer: BPETokenizer

    @ModuleInfo(key: "audio_tower") private var audioTower: AudioEncoder
    @ModuleInfo(key: "model") private var model: TextModel
    @ModuleInfo(key: "lm_head") private var lmHead: Linear?

    private init(_ config: Qwen3ASRConfig, tokenizer: BPETokenizer) {
        self.config = config
        self.tokenizer = tokenizer
        let text = config.thinkerConfig.textConfig
        _audioTower.wrappedValue = AudioEncoder(config.thinkerConfig.audioConfig)
        _model.wrappedValue = TextModel(text)
        _lmHead.wrappedValue = text.tieWordEmbeddings ? nil : Linear(text.hiddenSize, text.vocabSize, bias: false)
    }

    static func load(from directory: URL) throws -> Qwen3ASRModel {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let config = try decoder.decode(Qwen3ASRConfig.self, from: Data(contentsOf: directory.appending(path: "config.json")))
        let model = Qwen3ASRModel(config, tokenizer: try BPETokenizer(directory: directory))

        var weights: [String: MLXArray] = [:]
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where file.pathExtension == "safetensors" {
            for (key, value) in try loadArrays(url: file) {
                let key = key.hasPrefix("thinker.") ? String(key.dropFirst("thinker.".count)) : key
                guard !(config.thinkerConfig.textConfig.tieWordEmbeddings && key == "lm_head.weight") else { continue }
                weights[key] = value
            }
        }
        // PyTorch checkpoints carry OIHW conv kernels; MLX-converted ones are already OHWI.
        if weights.keys.contains(where: { $0.hasPrefix("thinker.") }) {
            for (key, value) in weights where key.contains("conv2d") && key.hasSuffix("weight") && value.ndim == 4 {
                weights[key] = value.transposed(0, 2, 3, 1)
            }
        }

        if let quantization = config.quantization {
            quantize(model: model) { path, _ in
                guard !path.hasPrefix("audio_tower"), weights["\(path).scales"] != nil else { return nil }
                return (quantization.groupSize, quantization.bits, quantization.mode ?? .affine)
            }
        }
        try model.update(parameters: ModuleParameters.unflattened(weights), verify: .all)
        eval(model)
        return model
    }

    /// `audio`: mono 16 kHz samples. `context` fills the system prompt (hotwords / domain hints).
    /// `language` forces the tag; `nil` lets the model detect it.
    func transcribe(_ audio: MLXArray, context: String = "", language: String? = nil, maxTokens: Int = 8192) -> Output {
        let forcedLanguage = language.flatMap(normalizeLanguage)
        let results = splitIntoChunks(audio).map { chunk in
            defer { Memory.clearCache() }
            return transcribeChunk(chunk, context: context, language: forcedLanguage, maxTokens: maxTokens)
        }
        var seen = Set<String>()
        let languages = results.compactMap(\.language).filter { seen.insert($0).inserted }
        return Output(
            text: results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines),
            language: languages.isEmpty ? nil : languages.joined(separator: ",")
        )
    }

    private func transcribeChunk(_ audio: MLXArray, context: String, language: String?, maxTokens: Int) -> Output {
        let mel = logMelSpectrogram(audio, nMels: config.thinkerConfig.audioConfig.numMelBins)  // [nMels, frames]
        // Encoder output length: 13 tokens per full 100-frame chunk, plus ⌈r/8⌉-style stride-2 halvings of the remainder.
        let frames = mel.dim(1)
        let numAudioTokens = frames / 100 * 13 + (0..<3).reduce(frames % 100) { length, _ in (length + 1) / 2 }

        let prompt = "<|im_start|>system\n\(context)<|im_end|>\n"
            + "<|im_start|>user\n<|audio_start|>"
            + String(repeating: "<|audio_pad|>", count: numAudioTokens)
            + "<|audio_end|><|im_end|>\n<|im_start|>assistant\n"
            + (language.map { "language \($0)<asr_text>" } ?? "")
        let ids = tokenizer.encode(prompt)

        let audioFeatures = audioTower(mel)
        eval(audioFeatures)

        // Splice encoder output over the contiguous run of <|audio_pad|> tokens.
        let embeddings = model.embedTokens(MLXArray(ids.map(Int32.init)).expandedDimensions(axis: 0))
        let audioStart = ids.firstIndex(of: config.thinkerConfig.audioTokenId)!
        let replaced = min(numAudioTokens, audioFeatures.dim(0))
        let merged = concatenated([
            embeddings[0, ..<audioStart],
            audioFeatures[..<replaced].asType(embeddings.dtype),
            embeddings[0, (audioStart + replaced)...],
        ], axis: 0).expandedDimensions(axis: 0)

        let caches = (0..<config.thinkerConfig.textConfig.numHiddenLayers).map { _ in KVCache() }
        let logits = { (embedded: MLXArray) -> MLXArray in
            let h = self.model(embedded, caches: caches)
            return self.lmHead.map { $0(h) } ?? self.model.embedTokens.asLinear(h)
        }

        // Chunked prefill keeps the lazy graph small and frees intermediates between steps.
        var processed = 0
        while ids.count - processed > 1 {
            let n = min(2048, ids.count - processed - 1)
            eval(logits(merged[0..., processed..<(processed + n), 0...]))
            Memory.clearCache()
            processed += n
        }
        var next = logits(merged[0..., processed..., 0...])[0, -1].argMax(axis: -1)
        asyncEval(next)

        // asyncEval pipelining: the GPU computes token N+1 while the CPU reads token N.
        let eos: Set<Int> = [151_645, 151_643]
        var generated: [Int] = []
        for step in 0..<maxTokens {
            let token = next.item(Int.self)
            guard !eos.contains(token) else { break }
            generated.append(token)
            // Degenerate-loop backstop: ≤3 distinct ids across the last 24 tokens.
            if generated.count >= 24 && Set(generated.suffix(24)).count <= 3 { break }
            guard step < maxTokens - 1 else { break }
            next = logits(model.embedTokens(MLXArray([Int32(token)]).expandedDimensions(axis: 0)))[0, -1].argMax(axis: -1)
            asyncEval(next)
            if step > 0 && step % 256 == 0 { Memory.clearCache() }
        }

        let decoded = tokenizer.decode(generated).trimmingCharacters(in: .whitespacesAndNewlines)
        if let language {
            return Output(text: decoded, language: language)
        }
        // Auto-detect output: "language <Name><asr_text><transcript>".
        guard decoded.hasPrefix("language "), let marker = decoded.range(of: "<asr_text>") else {
            return Output(text: decoded, language: nil)
        }
        return Output(
            text: decoded[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines),
            language: normalizeLanguage(String(decoded[decoded.index(decoded.startIndex, offsetBy: 9)..<marker.lowerBound]))
        )
    }

    private func normalizeLanguage(_ raw: String) -> String? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        let aliases = [
            "zh": "Chinese", "mandarin": "Chinese", "yue": "Cantonese", "en": "English", "de": "German",
            "es": "Spanish", "fr": "French", "it": "Italian", "pt": "Portuguese", "ru": "Russian",
            "ko": "Korean", "ja": "Japanese",
        ]
        let canonical = aliases[key] ?? key
        return config.supportLanguages.first { $0.lowercased() == canonical.lowercased() } ?? raw
    }

    // MARK: Audio front-end

    /// Splits audio longer than 20 min at the lowest-energy 100 ms window within ±5 s of each cut.
    private func splitIntoChunks(_ audio: MLXArray) -> [MLXArray] {
        let sr = Self.sampleRate
        let (maxChunk, search, window, minimum) = (1200 * sr, 5 * sr, sr / 10, sr)
        let total = audio.dim(0)
        let padToMinimum = { (chunk: MLXArray) in
            chunk.dim(0) < minimum ? padded(chunk, widths: [IntOrPair((0, minimum - chunk.dim(0)))]) : chunk
        }

        var chunks: [MLXArray] = []
        var start = 0
        while total - start > maxChunk {
            let end = start + maxChunk
            let (searchStart, searchEnd) = (max(start, end - search), min(total, end + search))
            let region = audio[searchStart..<searchEnd].asArray(Float.self)
            // Sliding-window energy; argmin locates the quietest cut point.
            var energy = region[..<window].reduce(0) { $0 + $1 * $1 }
            var (best, bestEnergy) = (0, energy)
            for i in 1...(region.count - window) {
                energy += region[i + window - 1] * region[i + window - 1] - region[i - 1] * region[i - 1]
                if energy < bestEnergy { (best, bestEnergy) = (i, energy) }
            }
            let cut = max(searchStart + best + window / 2, start + sr)
            chunks.append(padToMinimum(audio[start..<cut]))
            start = cut
        }
        chunks.append(padToMinimum(audio[start..<total]))
        return chunks
    }

    /// Whisper-style log-mel: periodic Hann, n_fft 400, hop 160, Slaney mel scale and norm, reflect padding.
    private func logMelSpectrogram(_ audio: MLXArray, nMels: Int) -> MLXArray {
        let (nFft, hop) = (400, 160)
        let sr = Float(Self.sampleRate)

        let window = MLXArray((0..<nFft).map { 0.5 * (1 - cos(2 * Float.pi * Float($0) / Float(nFft))) })
        let pad = nFft / 2
        let n = audio.dim(0)
        let reflectIndex = { (indices: [Int]) in MLXArray(indices.map(Int32.init)) }
        let paddedAudio = concatenated([
            audio[reflectIndex(Array((1...pad).reversed()))],
            audio,
            audio[reflectIndex(Array(((n - 1 - pad)..<(n - 1)).reversed()))],
        ])
        let frameCount = 1 + (paddedAudio.dim(0) - nFft) / hop
        let frames = asStrided(paddedAudio, [frameCount, nFft], strides: [hop, 1], offset: 0) * window
        let power = abs(rfft(frames, axis: 1)).square()  // [frames, nFft/2 + 1]

        // Slaney mel: linear below 1 kHz (200/3 Hz per mel), logarithmic above.
        let fSp: Float = 200 / 3
        let minLogMel: Float = 1000 / fSp
        let logStep = log(Float(6.4)) / 27
        let hzToMel = { (f: Float) in f < 1000 ? f / fSp : minLogMel + log(f / 1000) / logStep }
        let melToHz = { (m: Float) in m < minLogMel ? fSp * m : 1000 * exp(logStep * (m - minLogMel)) }
        let maxMel = hzToMel(sr / 2)
        let edges = (0..<(nMels + 2)).map { melToHz(Float($0) * maxMel / Float(nMels + 1)) }
        let nFreqs = nFft / 2 + 1
        var filters = [Float](repeating: 0, count: nFreqs * nMels)
        for i in 0..<nFreqs {
            let f = Float(i) * sr / Float(nFft)
            for j in 0..<nMels {
                let (low, center, high) = (edges[j], edges[j + 1], edges[j + 2])
                let weight = f >= low && f < center ? (f - low) / (center - low)
                    : f >= center && f <= high ? (high - f) / (high - center) : 0
                filters[i * nMels + j] = weight * 2 / (high - low)
            }
        }

        var mel = log10(maximum(matmul(power, MLXArray(filters).reshaped(nFreqs, nMels)), MLXArray(Float(1e-10))))
        mel = (maximum(mel, mel.max() - 8) + 4) / 4
        return mel.transposed(1, 0)
    }
}
