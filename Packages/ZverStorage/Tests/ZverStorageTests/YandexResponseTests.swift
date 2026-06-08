import Testing
import Foundation
@testable import ZverStorage

/// Тесты разбора JSON-ответов Яндекс REST.
///
/// Фикстуры — строковые JSON-литералы реальных форм ответов (из ресёрча):
/// `{href,method,templated}` для временных ссылок, `ResourceMeta` файла/папки
/// (со `sha256` и без), список через `_embedded.items`, статус async-операции.
@Suite struct YandexResponseTests {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    // MARK: - href

    @Test func parseHrefExtractsURL() throws {
        let json = """
        {
          "href": "https://uploader.dst.yandex.net/upload-target/abc123",
          "method": "PUT",
          "templated": false
        }
        """
        let url = try YandexResponse.parseHref(data(json))
        #expect(url.absoluteString == "https://uploader.dst.yandex.net/upload-target/abc123")
    }

    @Test func parseHrefDownloadVariant() throws {
        let json = """
        { "href": "https://downloader.dst.yandex.net/get?fn=track.flac", "method": "GET", "templated": false }
        """
        let url = try YandexResponse.parseHref(data(json))
        #expect(url.absoluteString == "https://downloader.dst.yandex.net/get?fn=track.flac")
    }

    @Test func parseHrefThrowsOnMissingHref() {
        let json = """
        { "method": "PUT", "templated": false }
        """
        #expect(throws: RemoteError.self) {
            _ = try YandexResponse.parseHref(data(json))
        }
    }

    // MARK: - ResourceMeta файла

    @Test func parseResourceFileWithSha() throws {
        let json = """
        {
          "name": "track.flac",
          "path": "app:/library/album/track.flac",
          "type": "file",
          "size": 41234567,
          "md5": "0123456789abcdef0123456789abcdef",
          "sha256": "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef0"
        }
        """
        let res = try YandexResponse.parseResource(data(json))
        #expect(res.name == "track.flac")
        #expect(res.size == 41_234_567)
        #expect(res.sha256 == "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef0")
        #expect(res.isDir == false)
        // path хранится без префикса app:/ — зеркало локального относительного пути.
        #expect(res.path == "library/album/track.flac")
    }

    @Test func parseResourceFileWithoutSha() throws {
        let json = """
        {
          "name": "track.flac",
          "path": "app:/library/album/track.flac",
          "type": "file",
          "size": 100
        }
        """
        let res = try YandexResponse.parseResource(data(json))
        #expect(res.sha256 == nil)
        #expect(res.size == 100)
        #expect(res.isDir == false)
    }

    @Test func parseResourceDirectory() throws {
        let json = """
        {
          "name": "album",
          "path": "app:/library/album",
          "type": "dir"
        }
        """
        let res = try YandexResponse.parseResource(data(json))
        #expect(res.isDir)
        #expect(res.name == "album")
        #expect(res.size == 0)
        #expect(res.sha256 == nil)
        #expect(res.path == "library/album")
    }

    @Test func parseResourceThrowsOnGarbage() {
        let json = "{ \"unexpected\": true }"
        #expect(throws: RemoteError.self) {
            _ = try YandexResponse.parseResource(data(json))
        }
    }

    // MARK: - список через _embedded.items

    @Test func parseListExtractsEmbeddedItems() throws {
        let json = """
        {
          "name": "album",
          "path": "app:/library/album",
          "type": "dir",
          "_embedded": {
            "items": [
              {
                "name": "01.flac",
                "path": "app:/library/album/01.flac",
                "type": "file",
                "size": 1000,
                "sha256": "aaa"
              },
              {
                "name": "02.flac",
                "path": "app:/library/album/02.flac",
                "type": "file",
                "size": 2000
              },
              {
                "name": "sub",
                "path": "app:/library/album/sub",
                "type": "dir"
              }
            ]
          }
        }
        """
        let items = try YandexResponse.parseList(data(json))
        #expect(items.count == 3)
        #expect(items[0].name == "01.flac")
        #expect(items[0].size == 1000)
        #expect(items[0].sha256 == "aaa")
        #expect(items[0].path == "library/album/01.flac")
        #expect(items[1].sha256 == nil)
        #expect(items[2].isDir)
    }

    @Test func parseListEmptyFolderReturnsEmptyArray() throws {
        let json = """
        {
          "name": "empty",
          "path": "app:/library/empty",
          "type": "dir",
          "_embedded": { "items": [] }
        }
        """
        let items = try YandexResponse.parseList(data(json))
        #expect(items.isEmpty)
    }

    @Test func parseListWithoutEmbeddedReturnsEmptyArray() throws {
        // Ответ на файл (не папку) — нет _embedded; list трактует как пусто.
        let json = """
        { "name": "track.flac", "path": "app:/library/x/track.flac", "type": "file", "size": 10 }
        """
        let items = try YandexResponse.parseList(data(json))
        #expect(items.isEmpty)
    }

    // MARK: - статус async-операции

    @Test func parseOperationInProgress() throws {
        let json = "{ \"status\": \"in-progress\" }"
        #expect(try YandexResponse.parseOperation(data(json)) == .inProgress)
    }

    @Test func parseOperationSuccess() throws {
        let json = "{ \"status\": \"success\" }"
        #expect(try YandexResponse.parseOperation(data(json)) == .success)
    }

    @Test func parseOperationFailed() throws {
        let json = "{ \"status\": \"failed\" }"
        #expect(try YandexResponse.parseOperation(data(json)) == .failed)
    }

    @Test func parseOperationUnknownStatusThrows() {
        let json = "{ \"status\": \"whatever\" }"
        #expect(throws: RemoteError.self) {
            _ = try YandexResponse.parseOperation(data(json))
        }
    }

    // MARK: - тело ошибки

    @Test func parseErrorBodyExtractsFields() throws {
        let json = """
        {
          "message": "Не удалось найти запрошенный ресурс.",
          "description": "Resource not found.",
          "error": "DiskNotFoundError"
        }
        """
        let body = YandexResponse.parseErrorBody(data(json))
        #expect(body?.error == "DiskNotFoundError")
        #expect(body?.message == "Не удалось найти запрошенный ресурс.")
        #expect(body?.description == "Resource not found.")
    }

    @Test func parseErrorBodyOnNonErrorJSONReturnsNil() {
        let json = "{ \"href\": \"x\", \"method\": \"GET\" }"
        let body = YandexResponse.parseErrorBody(data(json))
        #expect(body == nil)
    }
}
