import AVFoundation
import NotchIDCore
import SwiftUI
import Vision

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> NSView {
        FaceEngine.shared.prepare()
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        if let c = layer.connection, c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = true
        }
        view.layer = layer
        view.wantsLayer = true
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Model

@MainActor
final class EnrollModel: ObservableObject {
    enum Step: Equatable { case intro, scanning(pass: Int), between, done, failed }

    static let tickCount = 90
    static let poseThreshold: CGFloat = 0.045

    @Published var step: Step = .intro
    @Published var ticks = [Bool](repeating: false, count: tickCount)
    @Published var status = ""
    @Published var faceFound = false

    private var frontal: [VNFeaturePrintObservation] = []
    private var angled: [VNFeaturePrintObservation] = []
    private var best: (img: CGImage, mag: CGFloat)?
    private var neutralSamples: [CGPoint] = []
    private var neutral: CGPoint?
    private var frame = 0
    private var passStart = Date()
    var onFinish: (() -> Void)?

    var litFraction: Double { Double(ticks.filter { $0 }.count) / Double(Self.tickCount) }

    func start(pass: Int) {
        if pass == 1 { frontal = []; angled = []; best = nil }
        ticks = .init(repeating: false, count: Self.tickCount)
        neutral = nil; neutralSamples = []; frame = 0; passStart = Date()
        status = "Position your face within the frame."
        step = .scanning(pass: pass)
        Task {
            guard await FaceEngine.authorize() else {
                status = "NotchID needs camera access. Allow it in System Settings → Privacy & Security → Camera."
                step = .failed
                return
            }
            FaceEngine.shared.stream(wantAvatar: true) { [weak self] s in self?.handle(s) }
        }
    }

    func cancel() { FaceEngine.shared.stop() }

    private func handle(_ s: FaceSample?) {
        guard case .scanning(let pass) = step else { return }
        frame += 1
        guard let s, s.eyeOpenness > FaceEngine.eyesOpenThreshold else {
            faceFound = false
            status = "Position your face within the frame."
            return
        }
        faceFound = true

        // First few frames: learn the "looking straight" pose.
        guard let n = neutral else {
            neutralSamples.append(s.pose)
            addFrontal(s, mag: 0)
            if neutralSamples.count >= 5 {
                neutral = CGPoint(x: neutralSamples.map(\.x).reduce(0, +) / 5, y: neutralSamples.map(\.y).reduce(0, +) / 5)
            }
            return
        }
        status = "Move your head slowly to complete the circle."

        // Mirror x so the bars light on the side you turn toward in the (mirrored) preview.
        let v = CGPoint(x: -(s.pose.x - n.x), y: (s.pose.y - n.y) * 1.6)
        let mag = hypot(v.x, v.y)
        if mag < Self.poseThreshold * 0.6 {
            if frame % 2 == 0 { addFrontal(s, mag: mag) }
        } else if mag > Self.poseThreshold {
            if frame % 4 == 0, angled.count < 24 { angled.append(s.print) }
            // Screen angle (y down) measured clockwise from 12 o'clock.
            let screenAngle = atan2(-v.y, v.x) + .pi / 2
            var a = screenAngle.truncatingRemainder(dividingBy: 2 * .pi)
            if a < 0 { a += 2 * .pi }
            let center = Int((a / (2 * .pi) * CGFloat(Self.tickCount)).rounded()) % Self.tickCount
            withAnimation(.easeOut(duration: 0.2)) {
                for d in -4...4 { ticks[(center + d + Self.tickCount) % Self.tickCount] = true }
            }
        }

        let slow = Date().timeIntervalSince(passStart) > 30 && litFraction > 0.6
        if litFraction > 0.93 || slow { finishPass(pass) }
    }

    private func addFrontal(_ s: FaceSample, mag: CGFloat) {
        if frontal.count < 30 { frontal.append(s.print) }
        if let a = s.avatar, best == nil || mag < best!.mag { best = (a, mag) }
    }

    private func finishPass(_ pass: Int) {
        FaceEngine.shared.stopStream()
        withAnimation(.easeOut(duration: 0.35)) { ticks = .init(repeating: true, count: Self.tickCount) }
        if pass == 1 {
            step = .between
        } else {
            FaceEngine.shared.stop()
            save()
            step = .done
        }
    }

    private func save() {
        // Calibrate: allow a margin above how much your own straight-on samples differ from each other.
        var dists: [Float] = []
        for i in frontal.indices { for j in frontal.indices where j > i {
            dists.append(FaceEngine.distance(frontal[i], frontal[j]))
        } }
        let threshold = Calibration.threshold(pairwiseDistances: dists)
        Store.shared.saveEnrollment(prints: frontal + angled, threshold: threshold, avatar: best?.img)
    }
}

// MARK: - Views

struct ScanRing: View {
    let ticks: [Bool]
    let dimmed: Bool
    var diameter: CGFloat = 250

    var body: some View {
        ZStack {
            CameraPreview(session: FaceEngine.shared.session)
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
                .overlay(Circle().fill(.black.opacity(dimmed ? 0.45 : 0)))
                .animation(.easeInOut(duration: 0.3), value: dimmed)
            ForEach(0..<ticks.count, id: \.self) { i in
                let lit = ticks[i]
                Capsule()
                    .fill(lit ? Palette.green : Color.white.opacity(0.32))
                    .frame(width: 3, height: lit ? 22 : 13)
                    .offset(y: -(diameter / 2 + 14 + (lit ? 11 : 6.5)))
                    .rotationEffect(.degrees(Double(i) * 360 / Double(ticks.count)))
            }
        }
        .frame(width: diameter + 90, height: diameter + 90)
    }
}

struct EnrollView: View {
    @StateObject private var m = EnrollModel()
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            switch m.step {
            case .intro: intro
            case .scanning, .between: scanning
            case .done: done
            case .failed: failed
            }
        }
        .padding(.horizontal, 44)
        .padding(.top, 36)
        .padding(.bottom, 32)
        .frame(width: 460, height: 620)
        .background(Color.black)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.35), value: m.step)
        .onDisappear { m.cancel() }
    }

    private var intro: some View {
        VStack(spacing: 20) {
            Spacer()
            FaceIDGlyph(color: .white).frame(width: 110, height: 110)
            Text("How to Set Up Face ID").font(.system(size: 28, weight: .bold))
            Text("First, position your face in the camera frame. Then move your head in a circle to show all the angles of your face.")
                .font(.system(size: 15)).foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Spacer()
            PrimaryButton("Get Started") { m.start(pass: 1) }
        }
        .transition(.opacity)
    }

    private var scanning: some View {
        VStack(spacing: 18) {
            if m.step == .between {
                Text("First Face ID scan complete.").font(.system(size: 22, weight: .bold))
            } else {
                Text("Face ID").font(.system(size: 22, weight: .bold))
            }
            ScanRing(ticks: m.ticks, dimmed: !m.faceFound && m.step != .between)
            Text(m.step == .between
                 ? "Now move your head slowly to complete the circle a second time."
                 : m.status)
                .font(.system(size: 15)).foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center).frame(height: 44)
            Spacer(minLength: 0)
            if m.step == .between {
                PrimaryButton("Continue") { m.start(pass: 2) }
            } else {
                Button("Cancel") { m.cancel(); onClose() }.buttonStyle(.plain).foregroundStyle(Palette.blue)
                    .frame(height: 44)
            }
        }
    }

    private var done: some View {
        VStack(spacing: 22) {
            Spacer()
            CheckGlyph().frame(width: 110, height: 110)
            Text("Face ID is now set up.").font(.system(size: 26, weight: .bold))
            Text("Lock your Mac and look at it to unlock.")
                .font(.system(size: 15)).foregroundStyle(.white.opacity(0.7))
            Spacer()
            PrimaryButton("Done") { onClose() }
        }
    }

    private var failed: some View {
        VStack(spacing: 20) {
            Spacer()
            FaceIDGlyph(color: Palette.red, animate: false).frame(width: 100, height: 100)
            Text("Face ID Couldn't Be Set Up").font(.system(size: 24, weight: .bold))
            Text(m.status).font(.system(size: 15)).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
            Spacer()
            PrimaryButton("Try Again") { m.start(pass: 1) }
        }
    }
}

struct PrimaryButton: View {
    let title: String
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(Palette.blue.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
    }
}
