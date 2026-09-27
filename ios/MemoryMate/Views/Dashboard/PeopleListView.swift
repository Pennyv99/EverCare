//
//  PeopleListView.swift
//  MemoryMate
//

import SwiftUI

struct PeopleListView: View {
    let people: [Person]
    let reload: () async -> Void

    @EnvironmentObject private var appError: AppErrorState

    var body: some View {
        List {
            ForEach(people) { person in
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(person.relation)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        if let enrolled = person.enrolledAtRaw, !enrolled.isEmpty {
                            LabeledContent("Enrolled") {
                                Text(enrolled)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                            }
                        }

                        let thumbs = Base64ImageDecode.uiImages(fromBase64Strings: person.imageData)
                        if !thumbs.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Photos")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 10) {
                                        ForEach(Array(thumbs.enumerated()), id: \.offset) { _, img in
                                            Image(uiImage: img)
                                                .resizable()
                                                .scaledToFill()
                                                .frame(width: 120, height: 120)
                                                .clipped()
                                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text(person.name)
                        .font(.headline)
                }
            }
            .onDelete { offsets in
                Task {
                    for index in offsets {
                        let person = people[index]
                        do {
                            try await APIService.shared.delete("/face/\(person.id)")
                            await reload()
                        } catch {
                            appError.present(error)
                        }
                    }
                }
            }
        }
        .overlay {
            if people.isEmpty {
                ContentUnavailableView(
                    "No people yet",
                    systemImage: "person.crop.circle.badge.plus",
                    description: Text("Enroll someone from the People tab.")
                )
            }
        }
        .refreshable { await reload() }
    }
}
