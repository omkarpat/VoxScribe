import Foundation

enum AppConfig {
    #if targetEnvironment(simulator)
    static let serverBaseURL = URL(string: "http://127.0.0.1:8000")!
    #else
    static let serverBaseURL = URL(string: "http://192.168.1.100:8000")!
    #endif
}
