import Foundation
@testable import SplatEngine
import Testing

@Suite("Sharpest frame selection")
struct FrameSharpnessTests {
    @Test("Picks the sharpest frame inside each window")
    func picksSharpestPerWindow() {
        let scored = [
            FrameSharpnessScorer.ScoredFrame(seconds: 0.1, score: 5),
            FrameSharpnessScorer.ScoredFrame(seconds: 0.4, score: 9),
            FrameSharpnessScorer.ScoredFrame(seconds: 0.8, score: 2),
            FrameSharpnessScorer.ScoredFrame(seconds: 1.2, score: 3),
            FrameSharpnessScorer.ScoredFrame(seconds: 1.7, score: 8),
        ]
        let times = SharpestFrameSelector.times(
            windowCount: 2,
            duration: 2,
            scored: scored
        )
        #expect(times == [0.4, 1.7])
    }

    @Test("Empty windows fall back to their midpoint")
    func emptyWindowFallsBackToMidpoint() {
        let scored = [
            FrameSharpnessScorer.ScoredFrame(seconds: 0.2, score: 1),
        ]
        let times = SharpestFrameSelector.times(
            windowCount: 4,
            duration: 4,
            scored: scored
        )
        #expect(times == [0.2, 1.5, 2.5, 3.5])
    }

    @Test("No scored frames yields all midpoints")
    func noScoresYieldsMidpoints() {
        let times = SharpestFrameSelector.times(
            windowCount: 3,
            duration: 3,
            scored: []
        )
        #expect(times == [0.5, 1.5, 2.5])
    }

    @Test("Out-of-range timestamps are ignored")
    func outOfRangeIgnored() {
        let scored = [
            FrameSharpnessScorer.ScoredFrame(seconds: -0.5, score: 99),
            FrameSharpnessScorer.ScoredFrame(seconds: 5.0, score: 99),
            FrameSharpnessScorer.ScoredFrame(seconds: 0.9, score: 1),
        ]
        let times = SharpestFrameSelector.times(
            windowCount: 1,
            duration: 1,
            scored: scored
        )
        #expect(times == [0.9])
    }

    @Test("Ties keep the earlier frame")
    func tiesKeepEarlierFrame() {
        let scored = [
            FrameSharpnessScorer.ScoredFrame(seconds: 0.2, score: 4),
            FrameSharpnessScorer.ScoredFrame(seconds: 0.6, score: 4),
        ]
        let times = SharpestFrameSelector.times(
            windowCount: 1,
            duration: 1,
            scored: scored
        )
        #expect(times == [0.2])
    }
}
