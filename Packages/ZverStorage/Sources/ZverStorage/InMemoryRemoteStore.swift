import Foundation
import ZverTransport

/// Тестовый дубль `RemoteStore` поверх словаря в памяти — без сети.
///
/// Хранит для каждого пути сырые байты и предвычисленный SHA-256
/// (`ZverTransport.Sha256`). На нём ведётся TDD очереди бэкапа (S4-4) и логики
/// `BackupService`: upload пишет байты, download читает (учитывая `resumeFrom`),
/// exists/list/delete/ensureFolder работают над словарём. Потокобезопасен через
/// `NSLock` (`@unchecked Sendable`) — методы протокола асинхронны и могут
/// вызываться с разных задач параллельно. Критические секции вынесены в
/// синхронные хелперы: Swift 6 запрещает держать `NSLock` через `await`.
public final class InMemoryRemoteStore: RemoteStore, @unchecked Sendable {
    /// Одна запись хранилища: контент файла и его контрольная сумма.
    private struct Entry {
        var data: Data
        var sha256: String
    }

    private let lock = NSLock()
    private var files: [String: Entry] = [:]
    /// Явно созданные папки. Для `list`/`exists` папка считается существующей и
    /// если под ней есть файлы; этот набор покрывает пустые папки из `ensureFolder`.
    private var folders: Set<String> = []

    public init() {}

    /// Размер чанка, которым эмулируется прогресс отправки/приёма.
    private static let progressChunk: Int64 = 64 * 1024

    /// Выполняет тело под локом синхронно — без удержания `NSLock` через `await`.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - RemoteStore

    public func exists(path: String) async throws -> RemoteResource? {
        withLock {
            if let entry = files[path] {
                return resource(path: path, entry: entry)
            }
            if folders.contains(path) || hasChildrenLocked(folder: path) {
                return directoryResource(path: path)
            }
            return nil
        }
    }

    public func list(folder: String) async throws -> [RemoteResource] {
        withLock {
            let prefix = folder.hasSuffix("/") ? folder : folder + "/"
            return files
                .filter { key, _ in isDirectChild(key, prefix: prefix) }
                .map { key, entry in resource(path: key, entry: entry) }
                .sorted { $0.path < $1.path }
        }
    }

    public func ensureFolder(path: String) async throws {
        withLock { _ = folders.insert(path) }
    }

    public func upload(
        localFile: URL,
        to path: String,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> RemoteResource {
        let data: Data
        do {
            data = try Data(contentsOf: localFile)
        } catch {
            throw RemoteError.transport(underlying: error)
        }
        let sha = Sha256.hash(data)

        emitProgress(total: Int64(data.count), progress: progress)

        return withLock {
            let entry = Entry(data: data, sha256: sha)
            files[path] = entry
            return resource(path: path, entry: entry)
        }
    }

    public func download(
        path: String,
        to localFile: URL,
        resumeFrom: Int64,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> RemoteResource {
        let entry = withLock { files[path] }
        guard let entry else {
            throw RemoteError.notFound
        }
        let data = entry.data
        let sha = entry.sha256

        let offset = max(0, min(resumeFrom, Int64(data.count)))
        let tail = data.suffix(from: Int(offset))

        do {
            if offset == 0 {
                try data.write(to: localFile)
            } else {
                // Дозапись хвоста в конец уже существующего префикса.
                let handle = try FileHandle(forWritingTo: localFile)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: tail)
            }
        } catch {
            throw RemoteError.transport(underlying: error)
        }

        emitProgress(from: offset, total: Int64(data.count), progress: progress)

        return RemoteResource(
            path: path,
            name: lastComponent(path),
            size: Int64(data.count),
            sha256: sha,
            isDir: false
        )
    }

    public func delete(path: String) async throws {
        withLock {
            files[path] = nil
            folders.remove(path)
        }
    }

    // MARK: - Helpers

    private func resource(path: String, entry: Entry) -> RemoteResource {
        RemoteResource(
            path: path,
            name: lastComponent(path),
            size: Int64(entry.data.count),
            sha256: entry.sha256,
            isDir: false
        )
    }

    private func directoryResource(path: String) -> RemoteResource {
        RemoteResource(path: path, name: lastComponent(path), size: 0, sha256: nil, isDir: true)
    }

    private func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// `true`, если `key` лежит НЕПОСРЕДСТВЕННО в папке с данным `prefix`
    /// (без вложенных подпапок).
    private func isDirectChild(_ key: String, prefix: String) -> Bool {
        guard key.hasPrefix(prefix) else { return false }
        let rest = key.dropFirst(prefix.count)
        return !rest.isEmpty && !rest.contains("/")
    }

    /// `true`, если под папкой есть хотя бы один файл (на любой глубине).
    private func hasChildrenLocked(folder: String) -> Bool {
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        return files.keys.contains { $0.hasPrefix(prefix) }
    }

    private func emitProgress(
        from start: Int64 = 0,
        total: Int64,
        progress: @escaping @Sendable (Int64) -> Void
    ) {
        var sent = start
        if sent < total {
            while sent < total {
                sent = min(total, sent + Self.progressChunk)
                progress(sent)
            }
        } else {
            progress(total)
        }
    }
}
