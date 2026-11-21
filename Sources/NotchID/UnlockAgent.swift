import AppKit
import NotchIDCore

/// Watches the macOS lock screen. When the Mac is locked and the display is awake, it scans for the
/// enrolled face and, on a match, unlocks the real lock screen by typing the Keychain-stored password.
@MainActor
final class UnlockAgent {
    static let shared = UnlockAgent()

    private var attempt: Task<Void, Never>?
    private var lastAttemptEnd = Date.distantPast
    private var poll: Timer?
    private var displayAsleep = false
    private var submitting = false
    /// Set by the lock notification only. CGSSessionScreenIsLocked can still say "locked" for a while
    /// after an unlock, so it may clear this flag but never set it: a stale "locked" once started scans
    /// on the desktop and typed the password into the app in front.
    private(set) var locked = MacSession.isLocked
    /// Both signals agree that the lock screen is up.
    private var reallyLocked: Bool { locked && MacSession.isLocked }
    private var lastLoggedReadiness: Readiness?
    /// Set when a lock went by without a scan because setup is unfinished; told once on the lock
    /// screen and once more after the Mac is unlocked by hand, where the notch is always visible.
    private var skippedThisLock: Readiness?
    private var toldThisLock = false

    typealias Readiness = NotchIDCore.Readiness

    var readiness: Readiness {
        let store = Store.shared
        return .evaluate(enabled: store.unlockEnabled, enrolled: store.isEnrolled,
                         hasPassword: store.cachedPassword != nil,
                         cameraAuthorized: FaceEngine.cameraAuthorized, accessibilityGranted: Accessibility.granted)
    }

    func start() {
        Log.info("started — readiness: \(readiness), locked: \(locked)")
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            Task { @MainActor in
                let me = UnlockAgent.shared
                me.locked = true
                me.skippedThisLock = nil
                me.toldThisLock = false
                Log.info("screen locked (displayAsleep: \(me.displayAsleep))")
                try? await Task.sleep(for: .seconds(0.8))
                if me.locked && !me.displayAsleep { me.trigger() }
            }
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            Task { @MainActor in
                let me = UnlockAgent.shared
                me.locked = false
                Log.info("screen unlocked (by NotchID: \(me.submitting))")
                if !me.submitting { me.cancel() } // unlocked by hand → stop scanning
                if let text = me.skippedThisLock?.notice {
                    me.skippedThisLock = nil
                    try? await Task.sleep(for: .seconds(0.6))
                    await NotchController.shared.showNotice(text)
                }
            }
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                let me = UnlockAgent.shared
                me.displayAsleep = false
                if !MacSession.isLocked { me.locked = false }
                Log.info("display woke (locked: \(me.locked))")
                if me.locked { me.trigger() }
            }
        }
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in
                    let me = UnlockAgent.shared
                    me.displayAsleep = true
                    me.cancel()
                    Log.info("\(name.rawValue)")
                    // Lid closed / Mac sleeping → lock right away, so Face ID is what opens it again.
                    if Store.shared.lockOnSleep && !MacSession.isLocked {
                        Log.info("locking because the Mac is going to sleep")
                        MacSession.lockNow()
                    }
                }
            }
        }
        // Like raising an iPhone: any mouse/keyboard activity on the lock screen starts a new scan.
        poll = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { _ in
            Task { @MainActor in
                let me = UnlockAgent.shared
                if me.locked && !MacSession.isLocked { me.locked = false } // missed unlock notification
                guard me.reallyLocked, !me.displayAsleep, me.attempt == nil,
                      Date().timeIntervalSince(me.lastAttemptEnd) > 2.5,
                      MacSession.secondsSinceAnyInput < 1.0 else { return }
                me.trigger()
            }
        }
    }

    func cancel() {
        attempt?.cancel()
    }

    func trigger() {
        guard attempt == nil, !NotchController.shared.isRunning else { return }
        guard readiness == .ready, let password = Store.shared.cachedPassword else {
            let r = readiness
            if r != lastLoggedReadiness { Log.info("not scanning — readiness: \(r)") }
            lastLoggedReadiness = r
            skippedThisLock = r
            if let text = r.notice, !toldThisLock {
                toldThisLock = true
                Task { await NotchController.shared.showNotice(text) }
            }
            return
        }
        Log.info("scanning for face…")
        attempt = Task {
            await run(password: password)
            FaceEngine.shared.stop()
            attempt = nil
            lastAttemptEnd = Date()
        }
    }

    private func run(password: String) async {
        let store = Store.shared
        let prints = store.prints, threshold = Float(store.threshold), blink = store.requireBlink
        let mode = store.afterUnlock

        await NotchController.shared.run(verify: {
            let deadline = Date().addingTimeInterval(12)
            while !Task.isCancelled && Date() < deadline {
                let r = await FaceEngine.shared.verify(prints: prints, threshold: threshold,
                                                       requireBlink: blink, timeout: 4) { u in
                    if case .distance(let d) = u { Log.info(String(format: "  face difference %.3f (limit %.3f)", d, threshold)) }
                }
                Log.info("verify result: \(r)")
                switch r {
                case .matched: return true
                case .cancelled: return false
                case .noFace: continue
                case .noMatch: await NotchController.shared.flashFailure()
                }
            }
            return false
        }, afterRecognized: { [weak self] in
            guard let self else { return false }
            FaceEngine.shared.stop()
            guard self.locked else { return true } // already unlocked (e.g. demo while unlocked)

            if mode == .stayOnLockScreen {
                // Recognised: show the open padlock and wait — like iPhone — for a key press or swipe.
                NotchController.shared.model.phase = .unlocked
                let shownAt = Date()
                while true {
                    if Task.isCancelled || !self.locked { return false }
                    if Date().timeIntervalSince(shownAt) > 60 { return false }
                    let since = MacSession.secondsSinceIntentInput
                    if since < Date().timeIntervalSince(shownAt) - 0.3 { break } // input after padlock appeared
                    try? await Task.sleep(for: .milliseconds(80))
                }
            }

            // `locked` follows lock/unlock notifications, and one can be missed. Ask the session itself:
            // typing into an unlocked Mac would send the password to whatever app has focus.
            guard self.reallyLocked else {
                Log.info("not typing the password: the screen is not locked")
                return true
            }
            self.submitting = true
            defer { self.submitting = false }
            Log.info("typing password (accessibility: \(Accessibility.granted))")
            await KeyTyper.submitPassword(password, while: { self.reallyLocked })
            // Wait for macOS to confirm.
            for _ in 0..<30 where self.locked {
                try? await Task.sleep(for: .milliseconds(100))
            }
            Log.info(self.locked ? "still locked after typing password" : "unlocked ✓")
            return !self.locked
        }, replayAfterUnlock: !SkyLight.worksOnLockScreen)
    }
}

extension UnlockAgent.Readiness {
    /// What is missing, for the notch and the menu; nil when there is nothing to fix.
    var notice: String? {
        switch self {
        case .ready, .disabled: return nil
        case .notEnrolled: return "Set up Face ID in NotchID"
        case .noPassword: return "Save your Mac password in NotchID"
        case .noCamera: return "Allow the camera for NotchID"
        case .noAccessibility: return "Allow Accessibility for NotchID"
        }
    }
}
