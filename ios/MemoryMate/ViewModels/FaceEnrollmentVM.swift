//
//  FaceEnrollmentVM.swift
//  MemoryMate
//

import Combine
import Foundation
import PhotosUI
import SwiftUI
import UIKit

@MainActor
final class FaceEnrollmentVM: ObservableObject {
    @Published var selectedItems: [PhotosPickerItem] = []

    @Published private(set) var galleryImages: [UIImage] = []
    @Published private(set) var cameraImages: [UIImage] = []

    @Published var name = ""
    @Published var relation = ""

    var images: [UIImage] { galleryImages + cameraImages }

    /// How many more faces can be picked from the library (total cap 5 including camera shots).
    var maxGallerySlots: Int { max(0, 5 - cameraImages.count) }

    var isReady: Bool {
        !images.isEmpty && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func syncPickerSelectionWithCap() async {
        let cap = maxGallerySlots
        if selectedItems.count > cap {
            selectedItems = Array(selectedItems.prefix(cap))
        }
        var loaded: [UIImage] = []
        for item in selectedItems {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                loaded.append(image)
            }
        }
        galleryImages = loaded
    }

    func appendCameraImage(_ image: UIImage) {
        guard images.count < 5 else { return }
        cameraImages.append(image)
    }

    func enroll() async throws {
        try await APIService.shared.enrollFace(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            relation: relation.trimmingCharacters(in: .whitespacesAndNewlines),
            images: images
        )
    }

    func reset() {
        selectedItems = []
        galleryImages = []
        cameraImages = []
        name = ""
        relation = ""
    }
}
