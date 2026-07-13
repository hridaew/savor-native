import Darwin
import Foundation

struct TrainerProcessLease: Codable, Equatable {
    static let filename = "trainer-process.json"

    let processIdentifier: Int32
    let executablePath: String
    let startTimeSeconds: UInt64
    let startTimeMicroseconds: UInt64

    static func write(process: Process, to outputURL: URL) throws {
        let processIdentifier = process.processIdentifier
        guard let identity = TrainerProcessRecovery.processIdentity(
            for: processIdentifier
        ) else {
            throw TrainerProcessRecovery.Error.cannotReadProcessIdentity
        }
        let lease = TrainerProcessLease(
            processIdentifier: processIdentifier,
            executablePath: identity.executablePath,
            startTimeSeconds: identity.startTimeSeconds,
            startTimeMicroseconds: identity.startTimeMicroseconds
        )
        let data = try JSONEncoder().encode(lease)
        try data.write(
            to: outputURL.appendingPathComponent(filename),
            options: .atomic
        )
    }
}

enum TrainerProcessRecovery {
    enum Error: Swift.Error {
        case cannotReadProcessIdentity
    }

    enum Result: Equatable {
        case noLease
        case processNotRunning
        case identityMismatch
        case terminated
        case terminationFailed
    }

    static func terminateStaleProcess(in outputURL: URL) -> Result {
        let leaseURL = outputURL.appendingPathComponent(
            TrainerProcessLease.filename
        )
        guard
            let data = try? Data(contentsOf: leaseURL),
            let lease = try? JSONDecoder().decode(
                TrainerProcessLease.self,
                from: data
            )
        else {
            return .noLease
        }
        defer {
            try? FileManager.default.removeItem(at: leaseURL)
        }

        guard let currentIdentity = processIdentity(
            for: lease.processIdentifier
        ) else {
            return .processNotRunning
        }
        guard
            currentIdentity.executablePath == lease.executablePath,
            currentIdentity.startTimeSeconds == lease.startTimeSeconds,
            currentIdentity.startTimeMicroseconds
                == lease.startTimeMicroseconds
        else {
            return .identityMismatch
        }
        if kill(lease.processIdentifier, SIGTERM) == 0 {
            return .terminated
        }
        return errno == ESRCH ? .processNotRunning : .terminationFailed
    }

    static func removeLease(from outputURL: URL) {
        try? FileManager.default.removeItem(
            at: outputURL.appendingPathComponent(TrainerProcessLease.filename)
        )
    }

    fileprivate static func processIdentity(
        for processIdentifier: Int32
    ) -> TrainerProcessIdentity? {
        var buffer = [CChar](repeating: 0, count: 4_096)
        let count = proc_pidpath(
            processIdentifier,
            &buffer,
            UInt32(buffer.count)
        )
        guard count > 0 else {
            return nil
        }
        let bytes = buffer.prefix(Int(count)).map {
            UInt8(bitPattern: $0)
        }
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(
            processIdentifier,
            PROC_PIDTBSDINFO,
            0,
            &info,
            expectedSize
        ) == expectedSize else {
            return nil
        }
        return TrainerProcessIdentity(
            executablePath: String(decoding: bytes, as: UTF8.self),
            startTimeSeconds: info.pbi_start_tvsec,
            startTimeMicroseconds: info.pbi_start_tvusec
        )
    }
}

private struct TrainerProcessIdentity {
    let executablePath: String
    let startTimeSeconds: UInt64
    let startTimeMicroseconds: UInt64
}
