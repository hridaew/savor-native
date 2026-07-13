enum ViewerStatus: Equatable {
    case idle
    case loading
    case ready(pointCount: Int)
    case failed(message: String)
}
