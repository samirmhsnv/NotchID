import AVFoundation
import CoreImage
import NotchIDCore
import Vision

/// One analysed camera frame.
struct FaceSample {
    let print: VNFeaturePrintObservation
    let avatar: CGImage?
    /// Head direction estimate: nose position inside the face box (centre = 0,0; Vision coords, y up).
    let pose: CGPoint
    /// Eye openness (height / width of eye contour). Open ≈ 0.25+, closed ≈ < 0.12.
    let eyeOpenness: Double
}

enum VerifyResult { case matched, noMatch, noFace, cancelled }

enum VerifyUpdate {
    case noFace
    case eyesClosed
    case distance(Float)
}

/// Camera + Vision pipeline. All camera/vision work runs on `queue`.
final class FaceEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    static let shared = FaceEngine()

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "notchid.camera", qos: .userInitiated)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var configured = false
    private var handler: ((CVPixelBuffer) -> Void)?
    private var tick = 0

    static let eyesOpenThreshold = EyeOpenness.closedAtOrBelow

    // MARK: Permissions / lifecycle

    static var cameraAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }

    static func authorize() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    /// Must run on `queue`.
    private func configureIfNeeded() -> Bool {
        if configured { return true }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video, position: .unspecified)
        guard let device = discovery.devices.first ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }

        session.beginConfiguration()
        session.sessionPreset = .high
        guard session.canAddInput(input) else { session.commitConfiguration(); return false }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { session.commitConfiguration(); return false }
        session.addOutput(output)
        session.commitConfiguration()
        configured = true
        return true
    }

    /// Configures the session synchronously (so a preview layer can be attached with a valid connection).
    @discardableResult
    func prepare() -> Bool { queue.sync { configureIfNeeded() } }

    func startPreview() {
        queue.async {
            guard self.configureIfNeeded() else { return }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stop() {
        queue.async {
            self.handler = nil
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    /// Streams analysed frames (nil = no usable face) to `onSample` on the main thread until `stopStream()`.
    func stream(wantAvatar: Bool, _ onSample: @escaping (FaceSample?) -> Void) {
        queue.async {
            guard self.configureIfNeeded() else { return }
            self.handler = { pb in
                let s = self.analyze(pb, wantAvatar: wantAvatar)
                DispatchQueue.main.async { onSample(s) }
            }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stopStream() { queue.async { self.handler = nil } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        tick &+= 1
        guard tick % 3 == 0, let handler, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        handler(pb)
    }

    // MARK: Analysis

    /// Runs on `queue`.
    func analyze(_ pb: CVPixelBuffer, wantAvatar: Bool = false) -> FaceSample? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up)
        let lmReq = VNDetectFaceLandmarksRequest()
        try? handler.perform([lmReq])
        guard let face = lmReq.results?.max(by: {
            $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
        }) else { return nil }
        let bb = face.boundingBox
        guard bb.width * bb.height > 0.012 else { return nil } // too far away

        let lm = face.landmarks
        let openness = min(Self.openness(lm?.leftEye), Self.openness(lm?.rightEye))
        var pose = CGPoint.zero
        if let nose = (lm?.nose ?? lm?.noseCrest)?.normalizedPoints, !nose.isEmpty {
            let cx = nose.map(\.x).reduce(0, +) / CGFloat(nose.count)
            let cy = nose.map(\.y).reduce(0, +) / CGFloat(nose.count)
            pose = CGPoint(x: cx - 0.5, y: cy - 0.5)
        }

        let image = CIImage(cvPixelBuffer: pb)
        let ext = image.extent
        let rect = VNImageRectForNormalizedRect(bb, Int(ext.width), Int(ext.height))
        let faceRect = rect.insetBy(dx: -rect.width * 0.08, dy: -rect.height * 0.08).intersection(ext)

        // Grayscale + slight contrast boost reduces sensitivity to lighting colour.
        let normalized = image.applyingFilter("CIColorControls",
                                              parameters: [kCIInputSaturationKey: 0, kCIInputContrastKey: 1.1])
        guard let crop = ciContext.createCGImage(normalized, from: faceRect) else { return nil }

        let fpReq = VNGenerateImageFeaturePrintRequest()
        fpReq.imageCropAndScaleOption = .scaleFill
        try? VNImageRequestHandler(cgImage: crop, orientation: .up).perform([fpReq])
        guard let print = fpReq.results?.first else { return nil }

        var avatar: CGImage?
        if wantAvatar {
            let side = max(rect.width, rect.height) * 1.9
            var sq = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2 + rect.height * 0.05,
                            width: side, height: side).intersection(ext)
            let s = min(sq.width, sq.height)
            sq = CGRect(x: sq.midX - s / 2, y: sq.midY - s / 2, width: s, height: s)
            let mirrored = image.cropped(to: sq).transformed(
                by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -(sq.minX + sq.maxX), y: 0))
            avatar = ciContext.createCGImage(mirrored, from: sq)
        }

        return FaceSample(print: print, avatar: avatar, pose: pose, eyeOpenness: openness)
    }

    private static func openness(_ region: VNFaceLandmarkRegion2D?) -> Double {
        let pts = region?.normalizedPoints ?? []
        return EyeOpenness.ratio(xs: pts.map { Double($0.x) }, ys: pts.map { Double($0.y) })
    }

    static func distance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Float {
        var d: Float = .infinity
        try? a.computeDistance(&d, to: b)
        return d
    }

    // MARK: Verification

    /// Looks for an enrolled face. Requires eyes open (attention) and optionally a blink (liveness).
    /// Does not stop the camera — callers call `stop()` when done.
    func verify(prints: [VNFeaturePrintObservation], threshold: Float, requireBlink: Bool,
                timeout: TimeInterval, onUpdate: ((VerifyUpdate) -> Void)? = nil) async -> VerifyResult {
        final class State { var done = false; var cont: CheckedContinuation<VerifyResult, Never>?
            var match: MatchState
            init(_ match: MatchState) { self.match = match } }
        let st = State(MatchState(threshold: threshold, requireBlink: requireBlink))
        let finish: (VerifyResult) -> Void = { r in // on queue
            guard !st.done else { return }
            st.done = true
            self.handler = nil
            st.cont?.resume(returning: r)
            st.cont = nil
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                queue.async {
                    if st.done { cont.resume(returning: .cancelled); return }
                    st.cont = cont
                    guard self.configureIfNeeded(), !prints.isEmpty else { finish(.noFace); return }
                    self.handler = { pb in
                        guard let s = self.analyze(pb) else {
                            _ = st.match.observe(.noFace); onUpdate?(.noFace); return
                        }
                        if s.eyeOpenness <= Self.eyesOpenThreshold {
                            _ = st.match.observe(.eyesClosed); onUpdate?(.eyesClosed); return
                        }
                        let d = prints.map { Self.distance(s.print, $0) }.min() ?? .infinity
                        onUpdate?(.distance(d))
                        if st.match.observe(.distance(d)) { finish(.matched) }
                    }
                    if !self.session.isRunning { self.session.startRunning() }
                    self.queue.asyncAfter(deadline: .now() + timeout) {
                        finish(st.match.sawFace ? .noMatch : .noFace)
                    }
                }
            }
        } onCancel: {
            queue.async { finish(.cancelled) }
        }
    }
}
