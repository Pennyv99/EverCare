//
//  MemoryMateApp.swift
//  MemoryMate
//

import AVFoundation
import Speech
import SwiftUI

private enum LaunchPermissions {
    static func run() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            SFSpeechRecognizer.requestAuthorization { _ in cont.resume() }
        }
        _ = await AVAudioApplication.requestRecordPermission()
    }
}

@main
struct MemoryMateApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .task { await LaunchPermissions.run() }
        }
    }
}
