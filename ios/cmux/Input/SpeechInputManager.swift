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
        SFSpeechRecognizer.requestAuthorization { _ in }
        AVAudioSession.sharedInstance().requestRecordPermission { _ in }
    }

    func start() {
        guard !isRecording else { return }
        transcript = ""

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let request = recognitionRequest else { return }
            request.shouldReportPartialResults = true

            let inputNode = audioEngine.inputNode
            let fmt = inputNode.outputFormat(forBus: 0)

            recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, _ in
                if let result {
                    Task { @MainActor [weak self] in
                        self?.transcript = result.bestTranscription.formattedString
                    }
                }
            }

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
        } catch {
            cleanupAudio()
        }
    }

    func stop() -> String {
        let result = transcript
        cleanupAudio()
        return result
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
