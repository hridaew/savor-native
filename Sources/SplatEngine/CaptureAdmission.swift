public struct CaptureAdmission: Sendable {
    public private(set) var isReserved = false

    public init() {}

    public mutating func reserve() -> Bool {
        guard !isReserved else {
            return false
        }
        isReserved = true
        return true
    }

    public mutating func release() {
        isReserved = false
    }
}
