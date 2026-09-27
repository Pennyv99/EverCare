//
//  Extensions.swift
//  MemoryMate
//

import Foundation
import UIKit

enum Keyboard {
    static func dismiss() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }
}

extension Data {
    mutating func append(_ string: String) {
        if let d = string.data(using: .utf8) {
            append(d)
        }
    }
}

extension UIImage {
    /// Vision reads raw `cgImage` pixels; UIImage orientation is not applied unless we normalize.
    func cgImageForVision() -> CGImage? {
        if imageOrientation == .up, let cg = cgImage {
            return cg
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let drawn = renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
        return drawn.cgImage
    }
}
