//
//  TexTellerPixelPreprocessor.swift
//  MemoryMate
//

import CoreGraphics
import UIKit
import ZeticMLange

/// Builds the `pixel_values` tensor for TexTeller-style ViT encoders (see e.g. [TexTeller ONNX notes](https://huggingface.co/Ji-Ha/TexTeller3-ONNX-dynamic)):
/// grayscale, resize to H×W, normalize `(x/255 - mean) / std`, shape **NCHW** `[1, 1, height, width]`, `float32`.
enum TexTellerPreprocessorError: LocalizedError {
    case couldNotCreateBitmap
    case couldNotGetPixels

    var errorDescription: String? {
        switch self {
        case .couldNotCreateBitmap:
            return "Could not prepare the image for TexTeller (bitmap creation failed)."
        case .couldNotGetPixels:
            return "Could not read grayscale pixels for TexTeller."
        }
    }
}

enum TexTellerPixelPreprocessor {
    static func makeEncoderInputTensor(from image: UIImage) throws -> Tensor {
        let w = MelangeConfiguration.texTellerInputWidth
        let h = MelangeConfiguration.texTellerInputHeight
        let mean = Float(MelangeConfiguration.texTellerImageMean)
        let std = Float(MelangeConfiguration.texTellerImageStd)

        guard let cgImage = image.cgImageForVision() else {
            throw TexTellerPreprocessorError.couldNotGetPixels
        }

        let bytesPerRow = w
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var pixelBytes = [UInt8](repeating: 0, count: w * h)

        guard let ctx = CGContext(
            data: &pixelBytes,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            throw TexTellerPreprocessorError.couldNotCreateBitmap
        }

        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        var floats = [Float](repeating: 0, count: 1 * 1 * h * w)
        let inv255: Float = 1 / 255
        for y in 0..<h {
            for x in 0..<w {
                let u = Float(pixelBytes[y * bytesPerRow + x])
                let v = (u * inv255 - mean) / std
                let idx = y * w + x
                floats[idx] = v
            }
        }

        let byteCount = floats.count * MemoryLayout<Float>.size
        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        precondition(data.count == byteCount)

        return Tensor(
            data: data,
            dataType: BuiltinDataType.float32,
            shape: [1, 1, h, w]
        )
    }
}
