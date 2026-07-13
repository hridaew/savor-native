public enum FrameSamplingPlan {
    public enum Error: Swift.Error, Equatable {
        case invalidDuration
        case invalidFrameCount
    }

    public static func sampleSeconds(
        duration: Double,
        targetCount: Int,
        estimatedFrameCount: Int
    ) throws -> [Double] {
        guard duration.isFinite, duration > 0 else {
            throw Error.invalidDuration
        }
        guard targetCount > 0, estimatedFrameCount > 0 else {
            throw Error.invalidFrameCount
        }
        let count = min(targetCount, estimatedFrameCount)
        let interval = duration / Double(count)
        return (0..<count).map { (Double($0) + 0.5) * interval }
    }
}
