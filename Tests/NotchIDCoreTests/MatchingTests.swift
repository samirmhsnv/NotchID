import Testing
@testable import NotchIDCore

/// Feeds the frames in order and returns, for each, whether it completed a match.
private func run(_ frames: [MatchState.Frame], requireBlink: Bool = false) -> (results: [Bool], state: MatchState) {
    var state = MatchState(threshold: 0.5, requireBlink: requireBlink)
    let results = frames.map { state.observe($0) }
    return (results, state)
}

@Suite("Matching")
struct MatchingTests {
    @Test func twoMatchingFramesInARowRecognise() {
        #expect(run([.distance(0.3), .distance(0.4)]).results == [false, true])
    }

    @Test func aMissOrALostFaceStartsOver() {
        let frames: [MatchState.Frame] = [.distance(0.3), .distance(0.5), .distance(0.3), .noFace, .distance(0.3), .distance(0.3)]
        #expect(run(frames).results == [false, false, false, false, false, true])
    }

    @Test func closedEyesNeverCountAndResetTheRun() {
        let frames: [MatchState.Frame] = [.distance(0.1), .eyesClosed, .distance(0.1), .distance(0.1)]
        #expect(run(frames).results == [false, false, false, true])
    }

    @Test func aRequiredBlinkHasToComeFirst() {
        let frames: [MatchState.Frame] = [.distance(0.1), .distance(0.1), .distance(0.1), .eyesClosed, .distance(0.1), .distance(0.1)]
        #expect(run(frames, requireBlink: true).results == [false, false, false, false, false, true])
    }

    @Test func aFaceIsSeenOnlyWhenOneIsFound() {
        #expect(!run([.noFace]).state.sawFace)
        #expect(run([.noFace, .distance(0.9)]).state.sawFace)
    }
}

@Suite("Calibration")
struct CalibrationTests {
    @Test func thresholdIsTheNinetiethPercentileWithAMargin() {
        let t = Calibration.threshold(pairwiseDistances: [0.3, 0.2, 0.25])
        #expect(abs(t - 0.4) < 0.0001)
    }

    @Test func thresholdStaysWithinBounds() {
        #expect(Calibration.threshold(pairwiseDistances: [0.01, 0.02, 0.03]) == 0.3)
        #expect(Calibration.threshold(pairwiseDistances: [0.9, 1.0, 1.1]) == 0.7)
        #expect(abs(Calibration.threshold(pairwiseDistances: []) - 0.4) < 0.0001)
    }
}

@Suite("Eye openness")
struct EyeOpennessTests {
    @Test func ratioIsHeightOverWidth() {
        #expect(EyeOpenness.ratio(xs: [0, 4, 2], ys: [0, 0, 1]) == 0.25)
    }

    @Test func unmeasurableOutlinesCountAsOpen() {
        #expect(EyeOpenness.ratio(xs: [0, 1], ys: [0, 1]) == 1)
        #expect(EyeOpenness.ratio(xs: [2, 2, 2], ys: [0, 1, 2]) == 1)
    }
}

@Suite("Readiness")
struct ReadinessTests {
    @Test func reportsTheFirstMissingPiece() {
        func r(_ e: Bool = true, _ f: Bool = true, _ p: Bool = true, _ c: Bool = true, _ a: Bool = true) -> Readiness {
            .evaluate(enabled: e, enrolled: f, hasPassword: p, cameraAuthorized: c, accessibilityGranted: a)
        }
        #expect(r() == .ready)
        #expect(r(false, false, false, false, false) == .disabled)
        #expect(r(true, false, false, false, false) == .notEnrolled)
        #expect(r(true, true, false, false, false) == .noPassword)
        #expect(r(true, true, true, false, false) == .noCamera)
        #expect(r(true, true, true, true, false) == .noAccessibility)
    }
}
