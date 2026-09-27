//
//  TexTellerMelangePipeline.swift
//  MemoryMate
//

import Foundation
import Tokenizers
import UIKit
import ZeticMLange

enum TexTellerPipelineError: LocalizedError {
    case missingPersonalKey
    case encoderProducedNoOutputs
    case decoderOutputNotUTF8(String)

    var errorDescription: String? {
        switch self {
        case .missingPersonalKey:
            return "Set MelangePersonalKey in Info.plist to run TexTeller on Melange."
        case .encoderProducedNoOutputs:
            return "TexTeller encoder returned no output tensors."
        case .decoderOutputNotUTF8(let detail):
            return "TexTeller decoder output could not be turned into text. \(detail)"
        }
    }
}

/// Same flow as the Melange **Deployment Guide** for encoder/decoder: load → **non-empty** `inputs` → `run`.
/// Guide `let inputs: [Tensor] = []` is a placeholder only; CoreML needs real tensors.
struct TexTellerMelangePipeline: Sendable {
    func transcribeToRawText(from image: UIImage) async throws -> String {
        guard let key = MelangeConfiguration.personalKey else {
            throw TexTellerPipelineError.missingPersonalKey
        }

        let pixelTensor = try TexTellerPixelPreprocessor.makeEncoderInputTensor(from: image)

        return try await Task.detached(priority: .userInitiated) {
            // ——— Encoder (dashboard snippet shape) ———
            // (1) Load ZeticMLange model
            let encoder = try ZeticMLangeModel(
                personalKey: key,
                name: MelangeConfiguration.texTellerEncoderName,
                version: MelangeConfiguration.texTellerEncoderVersion,
                modelMode: .RUN_AUTO,
                onDownload: nil
            )
            // (2) Prepare model inputs
            let encoderInputs: [Tensor] = [pixelTensor]
            // (3) Run and get output tensors of the model
            let encoderOutputs = try encoder.run(inputs: encoderInputs)
            guard let encoderHidden = encoderOutputs.first else {
                throw TexTellerPipelineError.encoderProducedNoOutputs
            }

            let decoderIds = Self.decoderIdsTensor(
                start: MelangeConfiguration.texTellerDecoderStartTokenId,
                pad: MelangeConfiguration.texTellerDecoderPadTokenId,
                length: MelangeConfiguration.texTellerDecoderInputSequenceLength
            )
            let decoderInputs: [Tensor] = MelangeConfiguration.texTellerDecoderInputIdsBeforeEncoderStates
                ? [decoderIds, encoderHidden]
                : [encoderHidden, decoderIds]

            // ——— Decoder ———
            // (1) Load ZeticMLange model
            let decoder = try ZeticMLangeModel(
                personalKey: key,
                name: MelangeConfiguration.texTellerDecoderName,
                version: MelangeConfiguration.texTellerDecoderVersion,
                modelMode: .RUN_AUTO,
                onDownload: nil
            )
            // (2) Prepare model inputs  (two tensors: ids + encoder states, order from plist)
            // (3) Run and get output tensors of the model
            let decoderOutputs = try decoder.run(inputs: decoderInputs)

            return try await Self.textFromDecoderOutputs(decoderOutputs)
        }.value
    }

    // MARK: - Decoder output → string

    private static func textFromDecoderOutputs(_ tensors: [Tensor]) async throws -> String {
        for t in tensors {
            if let s = utf8String(t.data), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let vocab = MelangeConfiguration.texTellerVocabSize
        let seq = MelangeConfiguration.texTellerDecoderInputSequenceLength
        let logitsBytes = seq * vocab * MemoryLayout<Float>.size
        guard let logits = tensors.first(where: { isFloat32($0.dataType) && $0.data.count == logitsBytes }) else {
            throw TexTellerPipelineError.decoderOutputNotUTF8(Self.briefTensorDump(tensors))
        }

        let ids = greedyArgmax(logits: logits, seq: seq, vocab: vocab)
        let tok = try await TexTellerTokenizerCache.shared.tokenizer(
            hubId: MelangeConfiguration.texTellerTokenizerHubModelId
        )
        let s = tok.decode(tokens: ids, skipSpecialTokens: true).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else {
            throw TexTellerPipelineError.decoderOutputNotUTF8(Self.briefTensorDump(tensors))
        }
        return s
    }

    private static func decoderIdsTensor(start: Int32, pad: Int32, length: Int) -> Tensor {
        var row = [Int32](repeating: pad, count: length)
        row[0] = start
        let data = row.withUnsafeBufferPointer { Data(buffer: $0) }
        return Tensor(data: data, dataType: BuiltinDataType.int32, shape: [1, length])
    }

    private static func greedyArgmax(logits: Tensor, seq: Int, vocab: Int) -> [Int] {
        let floats: [Float] = logits.data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Float.self)
            return Array(UnsafeBufferPointer(start: p.baseAddress, count: seq * vocab))
        }
        var out: [Int] = []
        out.reserveCapacity(seq)
        for t in 0..<seq {
            let base = t * vocab
            var best = 0
            var bestV = -Float.infinity
            for v in 0..<vocab {
                let x = floats[base + v]
                if x > bestV { bestV = x; best = v }
            }
            out.append(best)
        }
        return out
    }

    private static func isFloat32(_ dt: any DataType) -> Bool {
        (dt as? BuiltinDataType) == BuiltinDataType.float32
    }

    private static func utf8String(_ data: Data) -> String? {
        let end = data.firstIndex(of: 0) ?? data.endIndex
        let slice = data[..<end]
        return slice.isEmpty ? nil : String(bytes: slice, encoding: .utf8)
    }

    private static func briefTensorDump(_ tensors: [Tensor]) -> String {
        tensors.prefix(6).enumerated().map { i, t in
            "#\(i) shape=\(t.shape.map(String.init).joined(separator: ",")) bytes=\(t.data.count)"
        }.joined(separator: "; ")
            + (tensors.count > 6 ? " …+\(tensors.count - 6)" : "")
    }
}

private actor TexTellerTokenizerCache {
    static let shared = TexTellerTokenizerCache()
    private var tokenizer: Tokenizer?
    private var hubId: String?

    func tokenizer(hubId: String) async throws -> Tokenizer {
        if self.hubId == hubId, let tokenizer { return tokenizer }
        let t = try await AutoTokenizer.from(pretrained: hubId)
        tokenizer = t
        self.hubId = hubId
        return t
    }
}
