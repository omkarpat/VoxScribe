@preconcurrency import AVFoundation
import Foundation

enum AudioCaptureError: Error {
    case permissionDenied
    case invalidInputFormat
    case converterUnavailable
    case outputBufferAllocationFailed
    case engineStartFailed(Error)
}

struct AudioStreams {
    let pcm: AsyncStream<Data>
    let buffers: AsyncStream<AVAudioPCMBuffer>
}

@MainActor
final class AudioCapture {
    private let engine = AVAudioEngine()
    private let outputFormat: AVAudioFormat
    private var continuation: AsyncStream<Data>.Continuation?
    private var bufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var isRunning = false

    init() {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ) else {
            fatalError("Unable to create 16 kHz mono Int16 AVAudioFormat")
        }
        self.outputFormat = format
    }

    func start() async throws -> AudioStreams {
        precondition(!isRunning, "AudioCapture.start() called while already running")

        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else { throw AudioCaptureError.permissionDenied }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setActive(true, options: [])

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioCaptureError.invalidInputFormat
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioCaptureError.converterUnavailable
        }

        let (stream, cont) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = cont
        let (bufferStream, bufCont) = AsyncStream<AVAudioPCMBuffer>.makeStream(bufferingPolicy: .unbounded)
        self.bufferContinuation = bufCont

        let capturedOutputFormat = outputFormat
        let tapBufferSize = AVAudioFrameCount(inputFormat.sampleRate * 0.05) // ~50 ms of input audio

        inputNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: inputFormat) { buffer, _ in
            bufCont.yield(buffer)
            if let data = Self.convert(buffer, converter: converter, outputFormat: capturedOutputFormat) {
                cont.yield(data)
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            continuation = nil
            bufferContinuation = nil
            cont.finish()
            bufCont.finish()
            throw AudioCaptureError.engineStartFailed(error)
        }

        isRunning = true
        return AudioStreams(pcm: stream, buffers: bufferStream)
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
        bufferContinuation?.finish()
        bufferContinuation = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        isRunning = false
    }

    private static func convert(
        _ inputBuffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        outputFormat: AVAudioFormat
    ) -> Data? {
        let ratio = outputFormat.sampleRate / inputBuffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 64
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outCapacity) else {
            return nil
        }

        var delivered = false
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if delivered {
                outStatus.pointee = .noDataNow
                return nil
            }
            delivered = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if status == .error || error != nil { return nil }

        let frames = Int(outBuffer.frameLength)
        guard frames > 0, let ptr = outBuffer.int16ChannelData?[0] else { return nil }
        return Data(bytes: ptr, count: frames * MemoryLayout<Int16>.size)
    }
}
