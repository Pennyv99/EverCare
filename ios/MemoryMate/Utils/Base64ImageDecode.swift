//
//  Base64ImageDecode.swift
//  MemoryMate
//

import Foundation
import UIKit

enum Base64ImageDecode {
    static func uiImages(fromBase64Strings strings: [String]) -> [UIImage] {
        strings.compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard let data = Data(base64Encoded: trimmed, options: [.ignoreUnknownCharacters]) else { return nil }
            return UIImage(data: data)
        }
    }
}
