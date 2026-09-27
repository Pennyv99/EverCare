# MemoryMate Agent Voice API - iOS Integration Guide

## Quick Start

### Swift Implementation

#### 1. Basic Audio Playback

```swift
import AVFoundation

class MemoryMateVoiceAgent {
    let apiURL = "http://your-server:8000/agent-voice"
    var audioPlayer: AVAudioPlayer?
    
    func queryAgent(with text: String) async throws {
        // Create request
        var request = URLRequest(url: URL(string: apiURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Encode query
        let payload = ["query": text, "timeout": 30]
        request.httpBody = try JSONEncoder().encode(payload)
        
        // Make request
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw NSError(domain: "API Error", code: -1)
        }
        
        // Play audio
        try playAudio(data: data)
    }
    
    private func playAudio(data: Data) throws {
        audioPlayer = try AVAudioPlayer(data: data, fileTypeHint: AVFileType.mp3.rawValue)
        audioPlayer?.play()
    }
}
```

#### 2. With UI Feedback

```swift
@MainActor
class VoiceAgentViewController: UIViewController {
    @IBOutlet weak var queryTextField: UITextField!
    @IBOutlet weak var sendButton: UIButton!
    @IBOutlet weak var statusLabel: UILabel!
    @IBOutlet weak var activityIndicator: UIActivityIndicatorView!
    
    let agent = MemoryMateVoiceAgent()
    
    @IBAction func sendButtonTapped(_ sender: UIButton) {
        guard let query = queryTextField.text, !query.isEmpty else {
            showError("Please enter a query")
            return
        }
        
        Task {
            do {
                showLoading(true)
                statusLabel.text = "Processing..."
                
                try await agent.queryAgent(with: query)
                
                showLoading(false)
                statusLabel.text = "Playing response..."
                
            } catch {
                showLoading(false)
                showError("Error: \(error.localizedDescription)")
            }
        }
    }
    
    private func showLoading(_ isLoading: Bool) {
        sendButton.isEnabled = !isLoading
        isLoading ? activityIndicator.startAnimating() : activityIndicator.stopAnimating()
    }
    
    private func showError(_ message: String) {
        let alert = UIAlertController(title: "Error", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
```

#### 3. With Streaming and Progress

```swift
import AVFoundation
import Combine

class StreamingVoiceAgent: NSObject, AVAudioPlayerDelegate {
    let apiURL: URL
    var audioPlayer: AVAudioPlayer?
    var isPlaying: Bool = false
    
    @Published var isLoading = false
    @Published var statusMessage = ""
    @Published var audioProgress: Double = 0.0
    
    override init() {
        self.apiURL = URL(string: "http://your-server:8000/agent-voice")!
        super.init()
    }
    
    func queryAgent(with query: String) async throws {
        DispatchQueue.main.async {
            self.isLoading = true
            self.statusMessage = "Processing query..."
        }
        
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let payload = ["query": query, "timeout": 30]
        request.httpBody = try JSONEncoder().encode(payload)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw NSError(domain: "API", code: httpResponse.statusCode)
        }
        
        DispatchQueue.main.async {
            self.statusMessage = "Playing response..."
            do {
                self.audioPlayer = try AVAudioPlayer(data: data, fileTypeHint: AVFileType.mp3.rawValue)
                self.audioPlayer?.delegate = self
                self.audioPlayer?.play()
                self.isPlaying = true
            } catch {
                self.statusMessage = "Error playing audio: \(error)"
                self.isLoading = false
            }
        }
    }
    
    // MARK: - AVAudioPlayerDelegate
    
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.isPlaying = false
            self.isLoading = false
            self.statusMessage = flag ? "Finished" : "Playback error"
        }
    }
}
```

#### 4. SwiftUI Implementation

```swift
import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject var agent = StreamingVoiceAgent()
    @State var queryText: String = ""
    
    var body: some View {
        VStack(spacing: 20) {
            Text("MemoryMate Voice Assistant")
                .font(.title)
                .fontWeight(.bold)
            
            // Query Input
            HStack {
                TextField("Ask me anything...", text: $queryText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(agent.isLoading || agent.isPlaying)
                
                Button(action: sendQuery) {
                    Image(systemName: "paperplane.fill")
                }
                .disabled(queryText.isEmpty || agent.isLoading)
            }
            
            // Status
            if !agent.statusMessage.isEmpty {
                HStack(spacing: 10) {
                    if agent.isLoading {
                        ProgressView()
                    }
                    Text(agent.statusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            // Audio Player Info
            if agent.isPlaying {
                VStack(spacing: 10) {
                    HStack {
                        Image(systemName: "speaker.wave.2")
                        Text("Playing audio response...")
                    }
                    .font(.headline)
                    
                    ProgressView(value: agent.audioProgress)
                }
                .padding()
                .background(Color.blue.opacity(0.1))
                .cornerRadius(10)
            }
            
            Spacer()
        }
        .padding()
    }
    
    private func sendQuery() {
        Task {
            try await agent.queryAgent(with: queryText)
        }
    }
}

#Preview {
    ContentView()
}
```

## Configuration

### URL Configuration
Update the API URL in your code:
```swift
// Development
let apiURL = "http://192.168.1.100:8000/agent-voice"

// Production
let apiURL = "https://your-production-server.com/agent-voice"
```

### Audio Session Configuration

```swift
import AVFoundation

func setupAudioSession() {
    let audioSession = AVAudioSession.sharedInstance()
    do {
        // Set category and mode
        try audioSession.setCategory(
            .playback,
            mode: .default,
            options: [.duckOthers, .defaultToSpeaker]
        )
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
    } catch {
        print("Audio session setup error: \(error)")
    }
}
```

## Error Handling

```swift
enum VoiceAgentError: LocalizedError {
    case invalidResponse
    case networkError(Error)
    case audioError(Error)
    case timeout
    case serverError(Int)
    
    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Server returned invalid response"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .audioError(let error):
            return "Audio error: \(error.localizedDescription)"
        case .timeout:
            return "Request timed out"
        case .serverError(let code):
            return "Server error: HTTP \(code)"
        }
    }
}

// Usage in your code
do {
    try await agent.queryAgent(with: query)
} catch let error as VoiceAgentError {
    print(error.errorDescription ?? "Unknown error")
} catch {
    print("Unexpected error: \(error)")
}
```

## Best Practices

### 1. **Handle Interruptions**
```swift
func setupInterruptionHandling() {
    NotificationCenter.default.addObserver(
        forName: AVAudioSession.interruptionNotification,
        object: AVAudioSession.sharedInstance(),
        queue: .main
    ) { notification in
        guard let userInfo = notification.userInfo,
              let interruptionType = userInfo[AVAudioSessionInterruptionTypeKey] as? AVAudioSession.InterruptionType
        else { return }
        
        if interruptionType == .began {
            self.audioPlayer?.pause()
        } else {
            try? AVAudioSession.sharedInstance().setActive(true)
            self.audioPlayer?.play()
        }
    }
}
```

### 2. **Timeout Handling**
```swift
func queryWithTimeout(_ query: String, timeout: Int = 60) async throws {
    let task = Task {
        try await agent.queryAgent(with: query)
    }
    
    return try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            try await task.value
        }
        
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            throw VoiceAgentError.timeout
        }
        
        try await group.next()!
    }
}
```

### 3. **Memory Management**
```swift
class MemoryMateVoiceAgent {
    weak var delegate: AVAudioPlayerDelegate?
    
    deinit {
        audioPlayer?.stop()
        audioPlayer = nil
    }
}
```

## API Response Codes

| Status | Meaning | Action |
|--------|---------|--------|
| 200 | Success | Audio data received, play immediately |
| 400 | Bad Request | Check query format |
| 500 | Server Error | Show error message to user, retry |
| 503 | Service Unavailable | Server is down or ElevenLabs is unavailable |

## Testing Queries

Try these queries to test the endpoint:

```swift
// Reminder query
try await agent.queryAgent(with: "What reminders do I have?")

// Medication query
try await agent.queryAgent(with: "What's my next medication?")

// Combined query
try await agent.queryAgent(with: "Show me all my reminders and medications")
```

## Performance Tips

- **Cache audio responses** for frequently asked queries
- **Use URLSession background downloads** for large audio files
- **Implement audio buffering** for smoother playback
- **Set appropriate timeout values** (30-60 seconds)
- **Use `@StateObject`** to manage agent lifetime in SwiftUI

## Troubleshooting

### Audio Not Playing
```swift
// Check AVAudioSession
let session = AVAudioSession.sharedInstance()
print("Category: \(session.category)")
print("Is active: \(session.isOtherAudioPlaying)")
print("Category options: \(session.categoryOptions)")
```

### Network Issues
```swift
// Test endpoint connectivity
URLSession.shared.dataTask(with: URL(string: apiURL)!) { data, response, error in
    if let error = error {
        print("Connection error: \(error)")
    } else if let response = response as? HTTPURLResponse {
        print("Status: \(response.statusCode)")
    }
}.resume()
```

### Audio Format Issues
```swift
// Verify MP3 format support
let supportedFormats = AVAudioPlayer.availableAudioFileTypes()
print("Supported formats: \(supportedFormats)")  // Should include .mp3
```

## References

- [AVAudioPlayer Documentation](https://developer.apple.com/documentation/avfoundation/avaudioplayer)
- [URLSession Documentation](https://developer.apple.com/documentation/foundation/urlsession)
- [AVAudioSession Documentation](https://developer.apple.com/documentation/avfoundation/avaudiosession)
