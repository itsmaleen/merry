import AVFoundation
import MediaPlayer

final class VolumeButtonHandler: ObservableObject {
    var onSingleDown: (() -> Void)?
    var onDoubleDown: (() -> Void)?
    var onSpeechBegan: (() -> Void)?
    var onSpeechEnded: (() -> Void)?

    // Added to window hierarchy in start() for HUD suppression + slider access
    let volumeView = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))

    private var observation: NSKeyValueObservation?
    // Only read/written on main thread
    private var isAdjustingVolume = false

    private var lastDownTime: Date?
    private var pendingSingleTimer: Timer?

    private(set) var speechActive = false

    private var volumeSlider: UISlider? {
        volumeView.subviews.compactMap { $0 as? UISlider }.first
    }

    func start() {
        // Must be in the window hierarchy for slider subview to exist and for HUD suppression
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows })
                .first(where: { $0.isKeyWindow }) {
                window.addSubview(self.volumeView)
            }

            let session = AVAudioSession.sharedInstance()
            try? session.setActive(true)

            // Allow MPVolumeView to populate its slider subview before use
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.setVolume(0.5)
                self?.startObserving(session: session)
            }
        }
    }

    func stop() {
        observation?.invalidate()
        observation = nil
        pendingSingleTimer?.invalidate()
        volumeView.removeFromSuperview()
    }

    // MARK: - Private

    private func startObserving(session: AVAudioSession) {
        observation = session.observe(\.outputVolume, options: [.new, .old]) { [weak self] _, change in
            guard let self,
                  let newVal = change.newValue,
                  let oldVal = change.oldValue else { return }

            let delta = newVal - oldVal
            guard abs(delta) > 0.01 else { return }

            // Move all logic to main thread so isAdjustingVolume is safe
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isAdjustingVolume else { return }
                if delta < 0 {
                    // Ignore volume-down during speech — audio session route
                    // changes cause spurious negative-delta KVO events
                    guard !self.speechActive else { return }
                    self.handleVolumeDown()
                    // Delay volume reset so the second press of a double-click
                    // isn't swallowed by the isAdjustingVolume guard
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                        self?.setVolume(0.5)
                    }
                } else {
                    self.handleVolumeUp()
                }
            }
        }
    }

    private func handleVolumeDown() {
        let now = Date()
        if let last = lastDownTime, now.timeIntervalSince(last) < 0.5 {
            pendingSingleTimer?.invalidate()
            pendingSingleTimer = nil
            lastDownTime = nil
            onDoubleDown?()
        } else {
            lastDownTime = now
            pendingSingleTimer?.invalidate()
            pendingSingleTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: false) { [weak self] _ in
                self?.lastDownTime = nil
                self?.onSingleDown?()
            }
        }
    }

    private func handleVolumeUp() {
        if speechActive {
            speechActive = false
            onSpeechEnded?()
        } else {
            speechActive = true
            onSpeechBegan?()
        }
        setVolume(0.5)
    }

    private func setVolume(_ value: Float) {
        isAdjustingVolume = true
        volumeSlider?.value = value
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.isAdjustingVolume = false
        }
    }
}
