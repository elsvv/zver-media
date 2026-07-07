import XCTest
@testable import ZverMac

/// Тесты защиты от повторного «замусоривания» очереди уже синкнутыми альбомами:
/// удаление доставленной папки из `~/.zver-autoqueue` и устойчивость отпечатка
/// `DeliveredStore` к шуму (`.DS_Store`, сдвиг mtime).
final class AutoqueueTests: XCTestCase {

    // MARK: - Удаление доставленной папки из списка автоочереди

    func testAutoqueueContentRemovesDeliveredFolder() {
        let content = """
        /Users/x/Music/Album A
        /Users/x/Music/Album B
        /Users/x/Music/Album C
        """
        let out = MacEnqueue.autoqueueContent(content, removing: URL(fileURLWithPath: "/Users/x/Music/Album B"))
        XCTAssertFalse(out.contains("Album B"))
        XCTAssertTrue(out.contains("Album A"))
        XCTAssertTrue(out.contains("Album C"))
        XCTAssertTrue(out.hasSuffix("\n"))
    }

    func testAutoqueueContentIgnoresTrailingSlashAndBlankLines() {
        let content = "/Users/x/Music/Album A/\n\n   \n/Users/x/Music/Album B\n"
        // Хвостовой слэш не должен помешать совпадению (канонический путь).
        let out = MacEnqueue.autoqueueContent(content, removing: URL(fileURLWithPath: "/Users/x/Music/Album A"))
        XCTAssertFalse(out.contains("Album A"))
        XCTAssertEqual(out, "/Users/x/Music/Album B\n")
    }

    func testAutoqueueContentEmptyWhenLastRemoved() {
        let out = MacEnqueue.autoqueueContent("/Users/x/Only\n", removing: URL(fileURLWithPath: "/Users/x/Only"))
        XCTAssertEqual(out, "")
    }

    func testAutoqueueContentUnchangedWhenFolderAbsent() {
        let content = "/Users/x/A\n/Users/x/B\n"
        let out = MacEnqueue.autoqueueContent(content, removing: URL(fileURLWithPath: "/Users/x/NotThere"))
        XCTAssertEqual(out, content)
    }

    // MARK: - Отпечаток устойчив к .DS_Store и mtime

    func testFingerprintIgnoresHiddenFilesAndMtime() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("fp-" + UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 1000).write(to: dir.appendingPathComponent("01.flac"))
        try Data(repeating: 0, count: 2000).write(to: dir.appendingPathComponent("02.flac"))

        let base = DeliveredStore.fingerprint(of: dir)

        // Появился .DS_Store и у аудио сдвинулся mtime (Finder/Spotlight) — отпечаток
        // не должен измениться (иначе синкнутый альбом всплыл бы заново).
        try Data(repeating: 7, count: 6000).write(to: dir.appendingPathComponent(".DS_Store"))
        let future = Date().addingTimeInterval(10_000)
        try fm.setAttributes([.modificationDate: future], ofItemAtPath: dir.appendingPathComponent("01.flac").path)
        XCTAssertEqual(DeliveredStore.fingerprint(of: dir), base, "отпечаток должен игнорировать .DS_Store и mtime")

        // Реальная правка содержимого (заменили трек другим размером) — отпечаток меняется.
        try Data(repeating: 0, count: 9999).write(to: dir.appendingPathComponent("02.flac"))
        XCTAssertNotEqual(DeliveredStore.fingerprint(of: dir), base, "смена размера трека должна менять отпечаток")

        try? fm.removeItem(at: dir)
    }
}
