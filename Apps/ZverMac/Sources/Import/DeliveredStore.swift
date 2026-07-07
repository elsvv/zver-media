import Foundation

/// Персистентная память о том, какие альбомы телефон УЖЕ подтвердил доставленными
/// (`POST /confirm`). Нужна, чтобы стартовая автоочередь (`~/.zver-autoqueue`) не
/// ставила заново уже синкнутые альбомы на КАЖДОМ запуске приложения.
///
/// Ключ — папка-источник (канонический путь), значение — дешёвый отпечаток
/// содержимого папки (кол-во файлов + суммарный размер + макс. mtime, только `stat`,
/// без хеширования). Пока содержимое не менялось — альбом считается доставленным и
/// в очередь не попадает; поменяли исходники → отпечаток другой → авто-ресинк.
///
/// Наполняется на `confirm` (см. `ServerCoordinator`). Телефон шлёт `confirm` для
/// КАЖДОГО альбома манифеста, даже если качать нечего (`ImportCoordinator`), поэтому
/// множество надёжно пополняется при обычном синке.
///
/// `@MainActor`: пишется из `confirm` и читается из автоочереди — обе на MainActor.
/// Тяжёлый обход папки (`fingerprint`) — `nonisolated`, гоняется на детач-таске.
@MainActor
final class DeliveredStore {
    private var records: [String: String]
    private let fileURL: URL

    init(fileURL: URL = DeliveredStore.defaultURL) {
        self.fileURL = fileURL
        self.records = Self.load(fileURL)
    }

    /// Доставлен ли альбом из этой папки И не менялся (сохранённый отпечаток совпал с
    /// текущим). `fingerprint` считать заранее вне MainActor через `Self.fingerprint`.
    func isDelivered(folder: URL, fingerprint: String) -> Bool {
        records[Self.key(folder)] == fingerprint
    }

    /// Помечает папку доставленной с её текущим отпечатком. Идемпотентно, сразу
    /// сохраняет на диск.
    func markDelivered(folder: URL, fingerprint: String) {
        let key = Self.key(folder)
        guard records[key] != fingerprint else { return }
        records[key] = fingerprint
        save()
    }

    /// Канонический ключ папки (устойчив к `..`/симлинкам/хвостовому слэшу).
    private static func key(_ folder: URL) -> String {
        folder.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Дешёвый отпечаток содержимого папки: `кол-во:суммарный_размер` по НЕскрытым
    /// файлам. Только `stat` (без чтения/хеширования) — быстро даже на больших
    /// много-дисковых рипах. Добавили/заменили/убрали файл → отпечаток другой →
    /// авто-ресинк; при этом отпечаток УСТОЙЧИВ к шуму: `.skipsHiddenFiles` выкидывает
    /// `.DS_Store`/`._*` (Finder трогает их при простом просмотре папки), а mtime не
    /// учитывается вовсе (сдвигается от Spotlight/облака/тегов, а содержимое то же).
    /// Раньше mtime + `.DS_Store` в отпечатке воскрешали уже синкнутые альбомы в
    /// очереди на пустом месте. `nonisolated`: чистый FS-обход с детач-таски.
    nonisolated static func fingerprint(of folder: URL) -> String {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return "missing"
        }
        var count = 0
        var totalSize = 0
        for case let url as URL in enumerator {
            guard let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
            count += 1
            totalSize += v.fileSize ?? 0
        }
        return "\(count):\(totalSize)"
    }

    /// `~/Library/Application Support/ZverMac/delivered.json`.
    nonisolated static var defaultURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ZverMac", isDirectory: true)
        return base.appendingPathComponent("delivered.json")
    }

    private static func load(_ url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return dict
    }

    private func save() {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
