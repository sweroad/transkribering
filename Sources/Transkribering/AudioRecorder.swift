import AVFoundation

/// Spelar in från mikrofonen och konverterar till 16 kHz mono Float32, vilket är vad
/// transkriberingsmodellerna förväntar sig.
final class AudioRecorder {
    static let sampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate,
                                             channels: 1, interleaved: false)!
    private(set) var isRecording = false

    /// Aktuell ljudnivå (0–1), uppdateras under inspelning.
    private(set) var level: Float = 0

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    static var hasPermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func start() throws {
        guard !isRecording else { return }
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "Transkribering", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Ingen mikrofon hittades"])
        }
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        isRecording = true
    }

    /// Antal inspelade sampel hittills (för löpande transkribering).
    var sampleCount: Int {
        lock.lock(); defer { lock.unlock() }
        return samples.count
    }

    /// Sampel i ett intervall av den pågående inspelningen.
    func samples(in range: Range<Int>) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let clamped = range.clamped(to: 0..<samples.count)
        return Array(samples[clamped])
    }

    /// Stoppar inspelningen och returnerar ljudet (16 kHz mono).
    func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        level = 0
        lock.lock(); defer { lock.unlock() }
        let result = samples
        samples.removeAll()
        return result
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData?[0] else { return }
        let chunk = UnsafeBufferPointer(start: data, count: Int(out.frameLength))

        var peak: Float = 0
        for s in chunk { peak = max(peak, abs(s)) }

        lock.lock()
        samples.append(contentsOf: chunk)
        level = peak
        lock.unlock()
    }
}
