import AVFoundation
import Speech

/// Records a spoken note and transcribes it on the phone. Separate from the
/// terminal's `SpeechInputManager`, which is built for one short phrase: a
/// day note runs for minutes, so recognition is restarted whenever the
/// recogniser ends a phrase, and `TranscriptAccumulator` keeps what was said.
@MainActor
final class VoiceNoteRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    /// What has been said in this recording so far.
    @Published private(set) var text = ""
    /// Input loudness from 0 to 1, for the ring around the button.
    @Published private(set) var level: CGFloat = 0
    @Published private(set) var startedAt: Date?
    @Published var problem: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) ?? SFSpeechRecognizer()
    private let engine = AVAudioEngine()
    private var task: SFSpeechRecognitionTask?
    private var transcript = TranscriptAccumulator()
    /// The audio tap runs off the main thread and feeds whichever request is current.
    private let feed = RequestFeed()

    func start() async {
        guard !isRecording else { return }
        problem = nil
        guard await Self.allowed() else {
            problem = "Merry needs the microphone and speech recognition. Turn them on in Settings, or type the note."
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            problem = "Speech recognition isn't available right now. You can type the note."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else { throw NSError(domain: "merry.voice", code: 1, userInfo: [NSLocalizedDescriptionKey: "the microphone gave no audio format"]) }
            transcript = TranscriptAccumulator()
            text = ""
            beginPhrase(recognizer)
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { [feed, weak self] buffer, _ in
                feed.append(buffer)
                let loud = Self.loudness(buffer)
                Task { @MainActor [weak self] in self?.level = loud }
            }
            engine.prepare()
            try engine.start()
            isRecording = true
            startedAt = Date()
        } catch {
            problem = "Recording didn't start: \(error.localizedDescription)"
            teardown()
        }
    }

    /// Stops and returns what was said.
    @discardableResult
    func stop() -> String {
        let said = transcript.text
        teardown()
        return said
    }

    private func beginPhrase(_ recognizer: SFSpeechRecognizer) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        // On the phone there is no one-minute limit, and nothing leaves it.
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        feed.set(request)
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let partial = result?.bestTranscription.formattedString
            let ended = result?.isFinal == true || error != nil
            Task { @MainActor [weak self] in
                guard let self, self.feed.isCurrent(request) else { return }
                if let partial { self.transcript.update(partial) }
                if ended {
                    // The recogniser closed this phrase (a pause, or its time
                    // limit). Keep it and listen for the next one.
                    self.transcript.commit()
                    if self.isRecording { self.beginPhrase(recognizer) }
                }
                self.text = self.transcript.text
            }
        }
    }

    private func teardown() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        feed.set(nil)
        task?.cancel()
        task = nil
        isRecording = false
        startedAt = nil
        level = 0
        // Back to what the rest of the app expects (see SpeechInputManager).
        try? AVAudioSession.sharedInstance().setCategory(.ambient)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private static func allowed() async -> Bool {
        let speech = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    /// Root mean square of the buffer, mapped so normal speech sits around the middle.
    nonisolated private static func loudness(_ buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        let db = 20 * log10(max(rms, 0.000_01))
        return CGFloat(min(1, max(0, (db + 50) / 40)))
    }
}

/// Holds the recognition request the microphone is feeding.
private final class RequestFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ next: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        let old = request
        request = next
        lock.unlock()
        old?.endAudio()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let r = request
        lock.unlock()
        r?.append(buffer)
    }

    func isCurrent(_ r: SFSpeechAudioBufferRecognitionRequest) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return request === r
    }
}
