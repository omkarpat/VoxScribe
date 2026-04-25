import Foundation

nonisolated struct FinalizedTranscript: Codable, Equatable, Sendable {
    let sessionId: String?
    let startedAt: Date
    let endedAt: Date
    let mode: CorrectionMode
    let transcriber: Transcriber
    let segments: [TranscriptSegment]
    let renderedText: String
}
