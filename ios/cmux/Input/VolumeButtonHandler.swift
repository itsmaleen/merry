import AVFoundation
import MediaPlayer

final class VolumeButtonHandler: ObservableObject {
    var onSingleDown: (() -> Void)?
    var onDoubleDown: (() -> Void)?
    var onSingleUp: (() -> Void)?
    var onDoubleUp: (() -> Void)?

    // Added to window hierarchy in start() for HUD suppression + slider access
    let volumeView = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))

    private var observation: NSKeyValueObservation?
    private var interruptionObserver: Any?
    // Only read/written on main thread
    private var isAdjustingVolume = false

    // Volume-down double-tap
    private var lastDownTime: Date?
    private var pendingDownTimer: Timer?

    // Volume-up double-tap
    private var lastUpTime: Date?
    private var pendingUpTimer: Timer?

    private(set) var speechActive = false

    private var volumeSlider: UISlider? {
        volumeView.subviews.compactMap { $0 as? UISlider }.first
    }

    func start() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            // Clean up previous observer before re-attaching
            self.observation?.invalidate()
            self.observation = nil

            if let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows })
                .first(where: { $0.isKeyWindow }) {
                // Re-add in case it was detached
                self.volumeView.removeFromSuperview()
                window.addSubview(self.volumeView)
            }

            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.ambient)
            try? session.setActive(true)

            // Listen for audio session interruptions and restart
            if self.interruptionObserver == nil {
                self.interruptionObserver = NotificationCenter.default.addObserver(
                    forName: AVAudioSession.interruptionNotification,
                    object: session,
                    queue: .main
                ) { [weak self] notification in
                    guard let info = notification.userInfo,
                          let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                          let type = AVAudioSession.InterruptionType(rawValue: typeValue),
                          type == .ended else { return }
                    // Restart after interruption ends
                    print("[VolumeHandler] audio interruption ended, restarting")
                    self?.start()
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.setVolume(0.5)
                self?.startObserving(session: session)
            }
        }
    }

    func stop() {
        observation?.invalidate()
        observation = nil
        pendingDownTimer?.invalidate()
        pendingUpTimer?.invalidate()
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
        volumeView.removeFromSuperview()
    }

    func clearSpeechState() {
        speechActive = false
    }

    // MARK: - Private

    private func startObserving(session: AVAudioSession) {
        observation = session.observe(\.outputVolume, options: [.new, .old]) { [weak self] _, change in
            guard let self,
                  let newVal = change.newValue,
                  let oldVal = change.oldValue else { return }

            let delta = newVal - oldVal
            guard abs(delta) > 0.01 else { return }

            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isAdjustingVolume else { return }
                if delta < 0 {
                    guard !self.speechActive else { return }
                    self.handleVolumeDown()
                    // Delay reset so second press isn't swallowed
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                        self?.setVolume(0.5)
                    }
                } else {
                    self.handleVolumeUp()
                    // Delay reset so second press isn't swallowed
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                        self?.setVolume(0.5)
                    }
                }
            }
        }
    }

    private func handleVolumeDown() {
        let now = Date()
        if let last = lastDownTime, now.timeIntervalSince(last) < 0.5 {
            pendingDownTimer?.invalidate()
            pendingDownTimer = nil
            lastDownTime = nil
            onDoubleDown?()
        } else {
            lastDownTime = now
            pendingDownTimer?.invalidate()
            pendingDownTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: false) { [weak self] _ in
                self?.lastDownTime = nil
                self?.onSingleDown?()
            }
        }
    }

    private func handleVolumeUp() {
        let now = Date()
        if let last = lastUpTime, now.timeIntervalSince(last) < 0.5 {
            pendingUpTimer?.invalidate()
            pendingUpTimer = nil
            lastUpTime = nil
            onDoubleUp?()
        } else {
            lastUpTime = now
            pendingUpTimer?.invalidate()
            pendingUpTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: false) { [weak self] _ in
                self?.lastUpTime = nil
                self?.onSingleUp?()
            }
        }
    }

    private func setVolume(_ value: Float) {
        isAdjustingVolume = true
        volumeSlider?.value = value
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.isAdjustingVolume = false
        }
    }
}
