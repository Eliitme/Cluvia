import Foundation

/// Writes kubeconfig files the way kubectl does, plus safeguards for files that hold credentials:
/// takes `<file>.lock` like client-go, never exposes the content with wider permissions than the target,
/// and keeps timestamped backups of what it replaces.
enum KubeConfigFileWriter {
    static let backupsKept = 5

    /// Runs `body` while holding `<file>.lock` for every file, both as listed (what kubectl locks) and with symlinks
    /// resolved. Locks are created exclusively and removed afterwards; nothing runs unless all are taken.
    static func withLocks<T>(_ files: [URL], _ body: () throws -> T) throws -> T {
        var paths: [String] = []
        for file in files {
            for path in [file.standardizedFileURL.path, file.resolvingSymlinksInPath().path] where !paths.contains(path) {
                paths.append(path)
            }
        }
        var held: [String] = []
        defer { held.forEach { unlink($0) } }
        for path in paths.sorted() {
            let lock = path + ".lock"
            let descriptor = open(lock, O_CREAT | O_EXCL | O_WRONLY, 0o600)
            guard descriptor >= 0 else {
                if errno == EEXIST { throw KubeConfigEditError.locked(path: lock) }
                throw KubeConfigEditError.writeFailed(path: path, reason: String(cString: strerror(errno)))
            }
            close(descriptor)
            held.append(lock)
        }
        return try body()
    }

    /// Replaces `target` atomically. The temporary file is created with `mode` from the start, so the content is
    /// never readable by more users than the final file.
    static func write(_ data: Data, to target: URL, mode: mode_t) throws {
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY, mode & 0o600)
        guard descriptor >= 0 else { throw failure(target) }
        var ok = fchmod(descriptor, mode) == 0
        ok = ok && data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
        ok = ok && fsync(descriptor) == 0
        close(descriptor)
        guard ok, rename(temporary.path, target.path) == 0 else {
            let error = failure(target)
            unlink(temporary.path)
            throw error
        }
    }

    /// Saves the current content as `<file>.cluvia-backup-<timestamp>`, keeping the oldest one (the file as it was
    /// before the first edit) and the newest few.
    static func backUp(_ data: Data, of target: URL) throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let prefix = target.lastPathComponent + ".cluvia-backup-"
        let directory = target.deletingLastPathComponent()
        try write(data, to: directory.appendingPathComponent(prefix + formatter.string(from: Date())), mode: 0o600)
        let backups = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix(prefix) }
            .sorted()
        for old in backups.dropFirst().dropLast(backupsKept - 1) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(old))
        }
    }

    private static func failure(_ target: URL) -> KubeConfigEditError {
        .writeFailed(path: target.path, reason: String(cString: strerror(errno)))
    }
}
