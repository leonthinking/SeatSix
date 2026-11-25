import Darwin
import Foundation

enum PrivateReportWriter {
    /// The temporary inode is private before the first byte is written. Atomic replacement
    /// must not inherit permissions from an old, more broadly readable report.
    static func write(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".seatsix-report-\(UUID().uuidString)")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw failure() }
        var isOpen = true
        defer {
            if isOpen { Darwin.close(descriptor) }
            Darwin.unlink(temporary.path)
        }
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else { throw failure() }
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw failure() }
                written += count
            }
        }
        guard Darwin.fsync(descriptor) == 0 else { throw failure() }
        let closeResult = Darwin.close(descriptor)
        isOpen = false
        guard closeResult == 0 else { throw failure() }
        guard Darwin.rename(temporary.path, destination.path) == 0 else { throw failure() }
    }

    private static func failure() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
