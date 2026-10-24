import Foundation

/// Qwen2/3 byte-level BPE: NFC → special-token split → regex pre-tokenization → GPT-2 byte↔unicode map → ranked merges.
final class BPETokenizer: @unchecked Sendable {
    private let encoder: [String: Int]
    private let decoder: [Int: [UInt8]]
    private let mergeRanks: [String: Int]
    private let specialTokens: [String: Int]
    private let specialPattern: NSRegularExpression
    private let byteToScalar: [Character]
    private let pattern = try! NSRegularExpression(
        pattern: #"(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+"#
    )
    private var cache: [String: [Int]] = [:]

    init(directory: URL) throws {
        // GPT-2 byte map: printable bytes map to themselves, the remaining 68 to U+0100….
        let printable = Array(33...126) + Array(161...172) + Array(174...255)
        var scalars = [UInt32](repeating: 0, count: 256)
        var extra: UInt32 = 256
        for byte in 0..<256 {
            if printable.contains(byte) {
                scalars[byte] = UInt32(byte)
            } else {
                scalars[byte] = extra
                extra += 1
            }
        }
        byteToScalar = scalars.map { Character(Unicode.Scalar($0)!) }
        let scalarToByte = Dictionary(uniqueKeysWithValues: byteToScalar.enumerated().map { ($1, UInt8($0)) })

        encoder = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: directory.appending(path: "vocab.json")))

        struct AddedToken: Decodable { let content: String }
        struct TokenizerConfig: Decodable { let added_tokens_decoder: [String: AddedToken] }
        let added = try JSONDecoder().decode(
            TokenizerConfig.self, from: Data(contentsOf: directory.appending(path: "tokenizer_config.json"))
        ).added_tokens_decoder
        specialTokens = Dictionary(uniqueKeysWithValues: added.map { ($1.content, Int($0)!) })

        decoder = Dictionary(uniqueKeysWithValues:
            encoder.map { token, id in (id, token.map { scalarToByte[$0]! }) }
            + specialTokens.map { content, id in (id, Array(content.utf8)) }
        )

        let merges = try String(contentsOf: directory.appending(path: "merges.txt"), encoding: .utf8)
            .split(separator: "\n")
            .filter { !$0.hasPrefix("#version") }
        mergeRanks = Dictionary(merges.enumerated().map { (String($1), $0) }, uniquingKeysWith: min)

        specialPattern = try NSRegularExpression(
            pattern: specialTokens.keys.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern).joined(separator: "|")
        )
    }

    func encode(_ text: String) -> [Int] {
        var ids: [Int] = []
        let ns = text as NSString
        var cursor = 0
        for match in specialPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            encodeOrdinary(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), into: &ids)
            ids.append(specialTokens[ns.substring(with: match.range)]!)
            cursor = match.range.upperBound
        }
        encodeOrdinary(ns.substring(from: cursor), into: &ids)
        return ids
    }

    func decode(_ ids: [Int]) -> String {
        String(decoding: ids.flatMap { decoder[$0] ?? [] }, as: UTF8.self)
    }

    private func encodeOrdinary(_ text: String, into ids: inout [Int]) {
        let normalized = text.precomposedStringWithCanonicalMapping
        let ns = normalized as NSString
        for match in pattern.matches(in: normalized, range: NSRange(location: 0, length: ns.length)) {
            let piece = String(ns.substring(with: match.range).utf8.map { byteToScalar[Int($0)] })
            if let cached = cache[piece] {
                ids += cached
                continue
            }
            let encoded = bpe(piece).map { encoder[$0]! }
            cache[piece] = encoded
            ids += encoded
        }
    }

    /// Repeatedly merges the adjacent pair with the lowest rank until no ranked pair remains.
    private func bpe(_ word: String) -> [String] {
        var parts = word.map(String.init)
        while parts.count > 1 {
            var best: (rank: Int, index: Int)?
            for i in 0..<(parts.count - 1) {
                if let rank = mergeRanks["\(parts[i]) \(parts[i + 1])"], rank < best?.rank ?? .max {
                    best = (rank, i)
                }
            }
            guard let best else { break }
            let (left, right) = (parts[best.index], parts[best.index + 1])
            var merged: [String] = []
            var i = 0
            while i < parts.count {
                if i < parts.count - 1 && parts[i] == left && parts[i + 1] == right {
                    merged.append(left + right)
                    i += 2
                } else {
                    merged.append(parts[i])
                    i += 1
                }
            }
            parts = merged
        }
        return parts
    }
}
