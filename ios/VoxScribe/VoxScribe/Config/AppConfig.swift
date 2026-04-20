import Foundation

enum AppConfig {
    #if targetEnvironment(simulator)
    static let serverBaseURL = URL(string: "http://127.0.0.1:8000")!
    #else
    static let serverBaseURL = URL(string: "http://192.168.1.100:8000")!
    #endif

    // Local SFSR is an experiment to mask AAI's pause-gated partials with a
    // snappier on-device stream. Off by default; flip to test on a physical
    // device. If it doesn't noticeably improve the UX, the whole
    // `Speech/` path gets ripped out.
    static let localPartialStreamingEnabled = false
}
