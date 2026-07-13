import Darwin
import Foundation

public final class CaptureRootLock: @unchecked Sendable {
    public enum Error: Swift.Error, Equatable {
        case alreadyLocked
        case cannotOpen
        case cannotLock
    }

    private let descriptor: Int32

    public init(rootURL: URL) throws {
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let lockURL = rootURL.appendingPathComponent(".capture-root.lock")
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw Error.cannotOpen
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            Darwin.close(descriptor)
            if lockError == EWOULDBLOCK {
                throw Error.alreadyLocked
            }
            throw Error.cannotLock
        }
        self.descriptor = descriptor
    }

    deinit {
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}
