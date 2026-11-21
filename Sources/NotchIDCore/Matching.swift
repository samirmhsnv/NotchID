/// The decisions behind a scan, without the camera or Vision, so they can be tested.

/// Frame by frame: a face counts as recognised after two matching frames in a row with the eyes
/// open, and, when a blink is required, only once the eyes have been seen closed.
public struct MatchState {
    public enum Frame {
        case noFace
        case eyesClosed
        /// Distance from the closest enrolled print.
        case distance(Float)
    }

    public static let framesNeeded = 2

    public let threshold: Float
    public let requireBlink: Bool
    public private(set) var hits = 0
    public private(set) var sawFace = false
    public private(set) var sawClosed = false

    public init(threshold: Float, requireBlink: Bool) {
        self.threshold = threshold
        self.requireBlink = requireBlink
    }

    /// Returns true when this frame completes a match.
    public mutating func observe(_ frame: Frame) -> Bool {
        switch frame {
        case .noFace:
            hits = 0
            return false
        case .eyesClosed:
            sawFace = true
            sawClosed = true
            hits = 0
            return false
        case .distance(let d):
            sawFace = true
            guard d < threshold else {
                hits = 0
                return false
            }
            hits += 1
            return hits >= Self.framesNeeded && (!requireBlink || sawClosed)
        }
    }
}

/// The match threshold set at enrolment.
public enum Calibration {
    /// The 90th percentile of the distances between your own straight-on prints, with a 60% margin,
    /// kept between 0.3 and 0.7. Without any pairs the percentile is taken as 0.25.
    public static func threshold(pairwiseDistances: [Float]) -> Double {
        let sorted = pairwiseDistances.sorted()
        let p90 = sorted.isEmpty ? 0.25 : sorted[Int(Double(sorted.count - 1) * 0.9)]
        return min(max(Double(p90) * 1.6, 0.3), 0.7)
    }
}

/// How open an eye is, from the outline Vision finds around it.
public enum EyeOpenness {
    /// At or below this the eye counts as closed.
    public static let closedAtOrBelow = 0.16

    /// Height over width of the outline; 1 when it cannot be measured.
    public static func ratio(xs: [Double], ys: [Double]) -> Double {
        guard xs.count > 2, let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max()
        else { return 1 }
        let width = maxX - minX
        return width > 0 ? (maxY - minY) / width : 1
    }
}

/// Whether NotchID can unlock, and if not, the first thing missing.
public enum Readiness: Equatable {
    case ready, notEnrolled, noPassword, noCamera, noAccessibility, disabled

    public static func evaluate(enabled: Bool, enrolled: Bool, hasPassword: Bool,
                                cameraAuthorized: Bool, accessibilityGranted: Bool) -> Readiness {
        if !enabled { return .disabled }
        if !enrolled { return .notEnrolled }
        if !hasPassword { return .noPassword }
        if !cameraAuthorized { return .noCamera }
        if !accessibilityGranted { return .noAccessibility }
        return .ready
    }
}
