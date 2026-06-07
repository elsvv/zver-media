import Testing
import Foundation
@testable import ZverTransport

@Suite struct HTTPRouterTests {
    // MARK: - Простые эндпоинты

    @Test func resolvesManifest() {
        #expect(HTTPRouter.resolve(path: "/manifest") == .manifest)
    }

    @Test func resolvesPair() {
        #expect(HTTPRouter.resolve(path: "/pair") == .pair)
    }

    @Test func resolvesConfirm() {
        #expect(HTTPRouter.resolve(path: "/confirm") == .confirm)
    }

    // MARK: - Альбом/файл

    @Test func resolvesAlbumFile() {
        #expect(HTTPRouter.resolve(path: "/album/A%20-%20B%20(2020)/01.flac")
            == .album(id: "A - B (2020)", fileName: "01.flac"))
    }

    @Test func percentDecodesFileNameAndAlbum() {
        // %20 → пробел, %28/%29 → скобки.
        #expect(HTTPRouter.resolve(path: "/album/Radiohead%20-%20In%20Rainbows%20%282007%29/folder.jpg")
            == .album(id: "Radiohead - In Rainbows (2007)", fileName: "folder.jpg"))
    }

    @Test func plainAlbumFileWithoutEncoding() {
        #expect(HTTPRouter.resolve(path: "/album/SimpleAlbum/track.flac")
            == .album(id: "SimpleAlbum", fileName: "track.flac"))
    }

    // MARK: - Query string игнорируется

    @Test func stripsQueryString() {
        #expect(HTTPRouter.resolve(path: "/manifest?foo=bar") == .manifest)
        #expect(HTTPRouter.resolve(path: "/album/X/01.flac?v=1")
            == .album(id: "X", fileName: "01.flac"))
    }

    // MARK: - Неизвестные пути

    @Test func unknownPathIsNotFound() {
        #expect(HTTPRouter.resolve(path: "/") == .notFound)
        #expect(HTTPRouter.resolve(path: "/unknown") == .notFound)
        #expect(HTTPRouter.resolve(path: "/album") == .notFound)
        #expect(HTTPRouter.resolve(path: "/album/") == .notFound)
        #expect(HTTPRouter.resolve(path: "/album/OnlyAlbumNoFile") == .notFound)
        #expect(HTTPRouter.resolve(path: "") == .notFound)
    }

    @Test func tooManySegmentsIsNotFound() {
        // /album/<id>/<file> — ровно три сегмента; вложенный путь файла недопустим.
        #expect(HTTPRouter.resolve(path: "/album/X/sub/01.flac") == .notFound)
    }

    // MARK: - Защита от path traversal

    @Test func dotDotInFileNameIsRejected() {
        #expect(HTTPRouter.resolve(path: "/album/X/..") == .notFound)
        #expect(HTTPRouter.resolve(path: "/album/X/..%2Fsecret") == .notFound)
        #expect(HTTPRouter.resolve(path: "/album/X/%2e%2e") == .notFound)
    }

    @Test func dotDotInAlbumIdIsRejected() {
        #expect(HTTPRouter.resolve(path: "/album/..%2F..%2Fetc/passwd") == .notFound)
        #expect(HTTPRouter.resolve(path: "/album/%2e%2e/01.flac") == .notFound)
    }

    @Test func encodedSlashInSegmentIsRejected() {
        // %2F декодируется в '/', создавая лишний разделитель пути → traversal.
        #expect(HTTPRouter.resolve(path: "/album/X/sub%2Ffile.flac") == .notFound)
        #expect(HTTPRouter.resolve(path: "/album/a%2Fb/01.flac") == .notFound)
    }

    @Test func absolutePathInFileNameIsRejected() {
        // Декодированный сегмент, начинающийся с '/', — абсолютный путь.
        #expect(HTTPRouter.resolve(path: "/album/X/%2Fetc%2Fpasswd") == .notFound)
    }

    @Test func emptySegmentsAreRejected() {
        // Пустой albumId или fileName после декода — traversal-риск.
        #expect(HTTPRouter.resolve(path: "/album//01.flac") == .notFound)
        #expect(HTTPRouter.resolve(path: "/album/X/") == .notFound)
        // %20 даёт пробел, не пусто — но имя из одних пробелов тоже отвергаем.
        #expect(HTTPRouter.resolve(path: "/album/%20/01.flac") == .notFound)
    }

    @Test func nullByteInSegmentIsRejected() {
        #expect(HTTPRouter.resolve(path: "/album/X/file%00.flac") == .notFound)
    }

    @Test func currentDirSegmentIsRejected() {
        // '.' как сегмент — тоже относительная навигация.
        #expect(HTTPRouter.resolve(path: "/album/./01.flac") == .notFound)
        #expect(HTTPRouter.resolve(path: "/album/X/.") == .notFound)
    }
}
