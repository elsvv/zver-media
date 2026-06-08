import Testing
import Foundation
@testable import ZverStorage

/// Тесты сборки `URLRequest` для всех эндпоинтов Яндекс REST.
///
/// Проверяем: базовый URL/метод/query каждого запроса, маппинг относительного
/// пути в `app:/...`-префикс с percent-кодированием (пробелы, кириллица,
/// зарезервированные символы), отдельную подстановку токена `Authorization: OAuth`
/// (чтобы не светить токен в основной фабрике), и сборку запроса на временный href.
@Suite struct YandexRequestFactoryTests {
    /// Фабрика с реальной базой Яндекс-API и app-folder префиксом.
    private func factory() -> YandexRequestFactory {
        YandexRequestFactory(
            baseURL: URL(string: "https://cloud-api.yandex.net/v1/disk")!,
            rootPrefix: "app:/"
        )
    }

    /// Достаёт и парсит query-компоненты запроса в словарь.
    private func queryItems(_ request: URLRequest) -> [String: String] {
        guard let url = request.url,
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems
        else { return [:] }
        var dict: [String: String] = [:]
        for item in items {
            dict[item.name] = item.value
        }
        return dict
    }

    // MARK: - uploadHref

    @Test func uploadHrefIsGetToResourcesUploadWithOverwrite() {
        let req = factory().uploadHref(path: "library/album/track.flac")
        #expect(req.httpMethod == "GET")
        let url = req.url!
        #expect(url.scheme == "https")
        #expect(url.host == "cloud-api.yandex.net")
        #expect(url.path == "/v1/disk/resources/upload")
        let q = queryItems(req)
        #expect(q["path"] == "app:/library/album/track.flac")
        #expect(q["overwrite"] == "true")
    }

    // MARK: - downloadHref

    @Test func downloadHrefIsGetToResourcesDownload() {
        let req = factory().downloadHref(path: "library/album/track.flac")
        #expect(req.httpMethod == "GET")
        #expect(req.url!.path == "/v1/disk/resources/download")
        let q = queryItems(req)
        #expect(q["path"] == "app:/library/album/track.flac")
    }

    // MARK: - resourceMeta

    @Test func resourceMetaIsGetToResourcesWithFields() {
        let fields = "name,size,sha256,md5,type,_embedded.items.name"
        let req = factory().resourceMeta(path: "library/album", fields: fields)
        #expect(req.httpMethod == "GET")
        #expect(req.url!.path == "/v1/disk/resources")
        let q = queryItems(req)
        #expect(q["path"] == "app:/library/album")
        #expect(q["fields"] == fields)
    }

    @Test func resourceMetaWithoutFieldsOmitsFieldsQuery() {
        let req = factory().resourceMeta(path: "library/album", fields: nil)
        let q = queryItems(req)
        #expect(q["path"] == "app:/library/album")
        #expect(q["fields"] == nil)
    }

    // MARK: - delete

    @Test func deletePermanentlyIsDeleteToResources() {
        let req = factory().delete(path: "library/album/track.flac", permanently: true)
        #expect(req.httpMethod == "DELETE")
        #expect(req.url!.path == "/v1/disk/resources")
        let q = queryItems(req)
        #expect(q["path"] == "app:/library/album/track.flac")
        #expect(q["permanently"] == "true")
    }

    @Test func deleteNonPermanentSendsFalse() {
        let req = factory().delete(path: "library/x", permanently: false)
        let q = queryItems(req)
        #expect(q["permanently"] == "false")
    }

    // MARK: - createFolder

    @Test func createFolderIsPutToResources() {
        let req = factory().createFolder(path: "library/album")
        #expect(req.httpMethod == "PUT")
        #expect(req.url!.path == "/v1/disk/resources")
        let q = queryItems(req)
        #expect(q["path"] == "app:/library/album")
    }

    // MARK: - operationStatus

    @Test func operationStatusIsGetToHref() {
        let href = URL(string: "https://cloud-api.yandex.net/v1/disk/operations/abc123")!
        let req = factory().operationStatus(href: href)
        #expect(req.httpMethod == "GET")
        #expect(req.url == href)
    }

    // MARK: - transfer (PUT тела на upload-href / GET с Range на download-href)

    @Test func transferPutHasNoRangeHeaderByDefault() {
        let href = URL(string: "https://uploader.dst.yandex.net/upload?token=xyz")!
        let req = factory().transfer(href: href, method: "PUT", range: nil)
        #expect(req.httpMethod == "PUT")
        #expect(req.url == href)
        #expect(req.value(forHTTPHeaderField: "Range") == nil)
    }

    @Test func transferGetWithResumeOffsetSetsRangeHeader() {
        let href = URL(string: "https://downloader.dst.yandex.net/get?token=xyz")!
        let req = factory().transfer(href: href, method: "GET", range: 4_096)
        #expect(req.httpMethod == "GET")
        #expect(req.url == href)
        #expect(req.value(forHTTPHeaderField: "Range") == "bytes=4096-")
    }

    @Test func transferZeroRangeOmitsRangeHeader() {
        let href = URL(string: "https://downloader.dst.yandex.net/get")!
        let req = factory().transfer(href: href, method: "GET", range: 0)
        #expect(req.value(forHTTPHeaderField: "Range") == nil)
    }

    // MARK: - percent-encoding пути

    @Test func pathWithSpacesIsPercentEncoded() {
        let req = factory().resourceMeta(path: "library/Pink Floyd/The Wall.flac", fields: nil)
        // Сырая строка URL должна содержать процентное кодирование пробела, не literal space.
        let raw = req.url!.absoluteString
        #expect(!raw.contains(" "))
        #expect(raw.contains("%20"))
        // Но декодированное значение query восстанавливает исходный путь.
        let q = queryItems(req)
        #expect(q["path"] == "app:/library/Pink Floyd/The Wall.flac")
    }

    @Test func pathWithCyrillicIsPercentEncoded() {
        let req = factory().resourceMeta(path: "library/Кино/Группа крови.flac", fields: nil)
        let raw = req.url!.absoluteString
        #expect(raw.contains("%D0"))  // кириллица в UTF-8 → %D0.. / %D1..
        let q = queryItems(req)
        #expect(q["path"] == "app:/library/Кино/Группа крови.flac")
    }

    @Test func pathWithReservedCharsIsEncoded() {
        // Знак "+" в имени не должен превратиться в пробел при декодировании.
        let req = factory().uploadHref(path: "library/a+b/track #1.flac")
        let q = queryItems(req)
        #expect(q["path"] == "app:/library/a+b/track #1.flac")
    }

    // MARK: - префикс

    @Test func leadingSlashInRelativePathIsNormalized() {
        // Путь с ведущим слэшем не должен давать app://library.
        let req = factory().resourceMeta(path: "/library/x", fields: nil)
        let q = queryItems(req)
        #expect(q["path"] == "app:/library/x")
    }

    @Test func catalogBackupAtRootMapsDirectlyUnderPrefix() {
        let req = factory().uploadHref(path: "catalog.sqlite.backup")
        let q = queryItems(req)
        #expect(q["path"] == "app:/catalog.sqlite.backup")
    }

    @Test func customRootPrefixIsHonoured() {
        let f = YandexRequestFactory(
            baseURL: URL(string: "https://cloud-api.yandex.net/v1/disk")!,
            rootPrefix: "disk:/Zver"
        )
        let req = f.resourceMeta(path: "library/x", fields: nil)
        let q = queryItems(req)
        #expect(q["path"] == "disk:/Zver/library/x")
    }

    // MARK: - authorized: подстановка токена

    @Test func authorizedAddsOAuthHeaderWithoutMutatingOriginal() {
        let f = factory()
        let bare = f.resourceMeta(path: "library/x", fields: nil)
        #expect(bare.value(forHTTPHeaderField: "Authorization") == nil)

        let authed = f.authorized(bare, token: "AQAA-secret")
        #expect(authed.value(forHTTPHeaderField: "Authorization") == "OAuth AQAA-secret")
        // URL/метод сохранены.
        #expect(authed.url == bare.url)
        #expect(authed.httpMethod == bare.httpMethod)
        // Оригинал не мутирован (токена в фикстурах не светим).
        #expect(bare.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func authorizedPreservesExistingRangeHeader() {
        let f = factory()
        let href = URL(string: "https://downloader.dst.yandex.net/get")!
        let req = f.transfer(href: href, method: "GET", range: 100)
        let authed = f.authorized(req, token: "tok")
        #expect(authed.value(forHTTPHeaderField: "Range") == "bytes=100-")
        #expect(authed.value(forHTTPHeaderField: "Authorization") == "OAuth tok")
    }
}
