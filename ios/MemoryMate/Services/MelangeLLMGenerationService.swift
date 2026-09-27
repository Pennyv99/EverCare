//
//  MelangeLLMGenerationService.swift
//  MemoryMate
//

import Foundation
import ZeticMLange

enum MelangeLLMError: LocalizedError {
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Melange is not configured. Set MelangePersonalKey in the target Info.plist (or build settings)."
        }
    }
}

/// Melange **Deployment Guide** pattern: `ZeticMLangeLLMModel` → `run(prompt)` → `waitForNextToken()` until `generatedTokens == 0`.
/// **Caches one model instance** per `(personalKey, name, version, modelMode)` so only the first run pays download/init; later calls are inference only.
/// Generation stops when EOS is reported (`generatedTokens == 0`) or **`maxGeneratedTokens`** is hit.
/// Do **not** stop on a bare `]` suffix — CoT / channel text often contains `]` and would truncate the stream early.
actor MelangeLLMGenerationService {
    static let shared = MelangeLLMGenerationService()

    private struct CacheKey: Equatable {
        let personalKey: String
        let name: String
        let version: Int?
        let mode: LLMModelMode
        let nCtx: Int
    }

    private var cachedModel: ZeticMLangeLLMModel?
    private var cacheKey: CacheKey?

    private init() {}

    func generate(
        prompt: String,
        modelName: String,
        modelVersion: Int?,
        modelMode: LLMModelMode? = nil,
        nCtx: Int = 4096,
        maxGeneratedTokens: Int = 8192,
        onDownloadProgress: (@Sendable (Float) -> Void)? = nil
    ) async throws -> String {
        let personalKey: String
        do {
            personalKey = try MelangeConfiguration.requirePersonalKey()
        } catch {
            throw MelangeLLMError.notConfigured
        }

        let resolvedMode = modelMode ?? MelangeConfiguration.structuredLLMModelMode
        let ctx = max(2048, nCtx)
        let key = CacheKey(personalKey: personalKey, name: modelName, version: modelVersion, mode: resolvedMode, nCtx: ctx)

        if cacheKey != key {
            if let old = cachedModel {
                try? old.cleanUp()
                old.forceDeinit()
                cachedModel = nil
                cacheKey = nil
            }
            cachedModel = try ZeticMLangeLLMModel(
                personalKey: personalKey,
                name: modelName,
                version: modelVersion,
                modelMode: resolvedMode,
                initOption: LLMInitOption(
                    kvCacheCleanupPolicy: .CLEAN_UP_ON_FULL,
                    nCtx: ctx
                ),
                onDownload: onDownloadProgress
            )
            cacheKey = key
        }

        guard let model = cachedModel else {
            throw MelangeLLMError.notConfigured
        }

        try? model.cleanUp()
        try model.run(prompt)

        var buffer = ""
        var tokenCount = 0
        let cap = max(32, maxGeneratedTokens)
        while true {
            let waitResult = model.waitForNextToken()
            if waitResult.generatedTokens == 0 { break }
            buffer.append(waitResult.token)
            tokenCount += 1
            if tokenCount >= cap { break }
        }

        let stoppedEarly = tokenCount >= cap
        print("[MemoryMate][StructuredLLM] model=\(modelName) version=\(String(describing: modelVersion)) characters=\(buffer.count) tokens=\(tokenCount) stoppedEarly=\(stoppedEarly)")
        print("[MemoryMate][StructuredLLM][raw] full model output follows (\(buffer.count) chars):")
        print(buffer)

        return buffer
    }
}
