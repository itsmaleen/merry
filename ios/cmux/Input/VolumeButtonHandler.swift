import AVFoundation
import MediaPlayer

final class VolumeButtonHandler: ObservableObject {
    var onSingleDown: (() -> Void)?
    var onDoubleDown: (() -> Void)?
    var onSpeechBegan: (() -> Void)?
    var onSpeechEnded: (() -> Void)?

    // Embed this view in the hierarchy to suppress the system volume HUD
    let volumeView: MPVolumeView = {
        let v = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))
        v.isUserInteractionEnabled = false
        return v
    }()

    private var observation: NSKeyValueObservation?
    private var isAdjustingVolume = false

    // Volume down double-press tracking
    private var lastDownTime: Date?
    private var pendingSingleTimer: Timer?

    // Volume up hold tracking
    private var speechActive = false
    private var speechReleaseTimer: Timer?

    private var volumeSlider: UISlider? {
        volumeView.subviews.compactMap { $0 as? UISlider }.first
    }

    func start() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(true)

        setVolume(0.5)

        observation = session.observe(\.outputVolume, options: [.new, .old]) { [weak self] _, change in
            guard let self,
                  let newVal = change.newValue,
                  let oldVal = change.oldValue,
                  !self.isAdjustingVolume else { return }

            let delta = newVal - oldVal
            if delta < -0.01 {
                DispatchQueue.main.async { self.handleVolumeDown() }
            } else if delta > 0.01 {
                DispatchQueue.main.async { self.handleVolumeUp() }
            }

            // Reset to middle so future presses are detectable
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.setVolume(0.5)
            }
        }
    }

    func stop() {
        observation?.invalidate()
        observation = nil
        pendingSingleTimer?.invalidate()
        speechReleaseTimer?.invalidate()
    }

    // MARK: - Private

    private func handleVolumeDown() {
        let now = Date()
        if let last = lastDownTime, now.timeIntervalSince(last) < 0.3 {
            // Double press
            pendingSingleTimer?.invalidate()
            pendingSingleTimer = nil
            lastDownTime = nil
            onDoubleDown?()
        } else {
            lastDownTime = now
            pendingSingleTimer?.invalidate()
            pendingSingleTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
                self?.lastDownTime = nil
                self?.onSingleDown?()
            }
        }
    }

    private func handleVolumeUp() {
        speechReleaseTimer?.invalidate()

        if !speechActive {
            speechActive = true
            onSpeechBegan?()
        }

        // If no more vol-up events arrive within 0.6s, treat as released
        speechReleaseTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            guard let self, self.speechActive else { return }
            self.speechActive = false
            self.onSpeechEnded?()
        }
    }

    private func setVolume(_ value: Float) {
        isAdjustingVolume = true
        volumeSlider?.value = value
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.isAdjustingVolume = false
        }
    }
}
