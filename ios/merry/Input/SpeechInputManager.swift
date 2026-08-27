import Speech
import AVFoundation

@MainActor
final class SpeechInputManager: ObservableObject {
    @Published var transcript = ""
    @Published var isRecording = false

    private let speechRecognizer = SFSpeechRecognizer(locale: .current)
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { status in
            print("[Speech] authorization: \(status.rawValue)")
        }
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            print("[Speech] microphone permission: \(granted)")
        }
    }

    func start() {
        guard !isRecording else { return }
        transcript = ""

        guard let speechRecognizer, speechRecognizer.isAvailable else {
            print("[Speech] recognizer unavailable")
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let request = recognitionRequest else { return }
            request.shouldReportPartialResults = true

            recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
                if let error {
                    print("[Speech] recognition error: \(error.localizedDescription)")
                }
                if let result {
                    Task { @MainActor [weak self] in
                        self?.transcript = result.bestTranscription.formattedString
                        print("[Speech] transcript: \(result.bestTranscription.formattedString)")
                    }
                }
            }

            let inputNode = audioEngine.inputNode
            let fmt = inputNode.outputFormat(forBus: 0)

            // Guard against zero-sample-rate format which causes silent failure
            guard fmt.sampleRate > 0 else {
                print("[Speech] inputNode format has zero sample rate: \(fmt)")
                cleanupAudio()
                return
            }

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
            print("[Speech] started recording")
        } catch {
            print("[Speech] start failed: \(error.localizedDescription)")
            cleanupAudio()
        }
    }

    func stop() -> String {
        print("[Speech] stopping, transcript: \(transcript)")
        let result = transcript
        cleanupAudio()
        return result
    }

    func cancel() {
        print("[Speech] cancelled")
        cleanupAudio()
    }

    private func cleanupAudio() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.finish()
        recognitionTask = nil
        recognitionRequest = nil
        isRecording = false
        transcript = ""

        // Restore session for volume KVO
        try? AVAudioSession.sharedInstance().setCategory(.ambient)
        try? AVAudioSession.sharedInstance().setActive(true)
    }
}
