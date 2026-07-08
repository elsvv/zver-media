import Testing
import Foundation
@testable import ZverImport

/// Чистая логика клиента Internet Archive (Live Music Archive): построение запросов
/// (`advancedsearch.php`, `/metadata`, `/download`) и Codable-разбор их JSON. Сеть сюда
/// не заглядывает — только URL из компонентов и `Data → модель`, поэтому покрываем
/// `swift test` на записанных JSON-фикстурах (встроены строками — самодостаточно, без
/// бинарников). Сетевые обёртки (`search`/`fetchRelease`) — тонкий `URLSession`-адаптер,
/// проверяется компиляцией.
@Suite struct ArchiveOrgClientTests {

    // MARK: - Построение запроса поиска

    @Test func searchQueryWrapsUserTermsInEtreeCollection() {
        #expect(ArchiveOrgClient.searchQuery("grateful dead") == "collection:(etree) AND (grateful dead)")
    }

    @Test func searchQueryEmptyFallsBackToCollectionOnly() {
        #expect(ArchiveOrgClient.searchQuery("") == "collection:(etree)")
        #expect(ArchiveOrgClient.searchQuery("   ") == "collection:(etree)")
    }

    @Test func searchURLTargetsAdvancedSearchWithFieldsAndPaging() throws {
        let url = ArchiveOrgClient.searchURL(query: "phish", rows: 25, page: 2)
        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(comps.scheme == "https")
        #expect(comps.host == "archive.org")
        #expect(comps.path == "/advancedsearch.php")

        let items = try #require(comps.queryItems)
        // q несёт коллекцию etree и пользовательский термин.
        let q = try #require(items.first { $0.name == "q" }?.value)
        #expect(q.contains("collection:(etree)"))
        #expect(q.contains("phish"))

        // Запрашиваем ровно нужные поля карточки.
        let fields = items.filter { $0.name == "fl[]" }.compactMap(\.value)
        for field in ["identifier", "title", "creator", "year", "downloads"] {
            #expect(fields.contains(field))
        }
        #expect(items.contains { $0.name == "output" && $0.value == "json" })
        #expect(items.contains { $0.name == "rows" && $0.value == "25" })
        #expect(items.contains { $0.name == "page" && $0.value == "2" })
    }

    @Test func metadataURLTargetsIdentifier() {
        let url = ArchiveOrgClient.metadataURL(identifier: "gd1977-05-08")
        #expect(url.absoluteString == "https://archive.org/metadata/gd1977-05-08")
    }

    @Test func downloadURLPercentEncodesFileSegment() {
        let url = ArchiveOrgClient.downloadURL(identifier: "gd1977-05-08", fileName: "gd77 d1t01.flac")
        #expect(url.absoluteString == "https://archive.org/download/gd1977-05-08/gd77%20d1t01.flac")
    }

    @Test func downloadURLKeepsSubdirectorySegments() {
        // Иногда файл лежит в подпапке item — путь сохраняем как сегменты.
        let url = ArchiveOrgClient.downloadURL(identifier: "item", fileName: "disc1/01 track.flac")
        #expect(url.absoluteString == "https://archive.org/download/item/disc1/01%20track.flac")
    }

    // MARK: - Разбор поиска

    private let searchJSON = """
    {
      "responseHeader": {"status": 0, "QTime": 12},
      "response": {
        "numFound": 3,
        "start": 0,
        "docs": [
          {"identifier": "gd1977-05-08", "title": "Barton Hall", "creator": "Grateful Dead", "year": "1977", "downloads": 254321},
          {"identifier": "phish1997", "title": ["Phish Live"], "creator": ["Phish", "Trey Anastasio"], "downloads": 9001},
          {"identifier": "noyear", "title": "No Year Show", "creator": "Some Band"}
        ]
      }
    }
    """

    @Test func parseSearchReadsAllCards() throws {
        let items = try ArchiveOrgClient.parseSearch(Data(searchJSON.utf8))
        #expect(items.count == 3)

        let first = items[0]
        #expect(first.identifier == "gd1977-05-08")
        #expect(first.title == "Barton Hall")
        #expect(first.creator == "Grateful Dead")
        #expect(first.year == "1977")
        #expect(first.downloads == 254321)
    }

    @Test func parseSearchJoinsArrayValuedFields() throws {
        // IA отдаёт creator/title то строкой, то массивом — массив склеиваем.
        let items = try ArchiveOrgClient.parseSearch(Data(searchJSON.utf8))
        let phish = items[1]
        #expect(phish.title == "Phish Live")
        #expect(phish.creator == "Phish, Trey Anastasio")
        #expect(phish.year == nil)
        #expect(phish.downloads == 9001)
    }

    @Test func parseSearchToleratesMissingOptionalFields() throws {
        let items = try ArchiveOrgClient.parseSearch(Data(searchJSON.utf8))
        let noyear = items[2]
        #expect(noyear.year == nil)
        #expect(noyear.downloads == nil)
    }

    @Test func parseSearchSkipsDocsWithoutIdentifier() throws {
        // Битую запись (нет identifier) пропускаем, остальные читаем.
        let json = """
        {"response": {"docs": [
          {"title": "No id"},
          {"identifier": "ok", "title": "Good"}
        ]}}
        """
        let items = try ArchiveOrgClient.parseSearch(Data(json.utf8))
        #expect(items.map(\.identifier) == ["ok"])
    }

    // MARK: - Разбор метаданных релиза

    private let metadataJSON = """
    {
      "metadata": {"identifier": "gd1977-05-08", "title": "Barton Hall", "creator": "Grateful Dead", "year": "1977"},
      "files": [
        {"name": "gd77-05-08d1t02.flac", "format": "24bit Flac", "size": "48000000", "length": "6:05", "title": "Loser", "track": "2"},
        {"name": "gd77-05-08d1t01.flac", "format": "Flac", "size": "31456789", "length": "365.5", "title": "Minglewood Blues", "track": "01"},
        {"name": "gd77-05-08d1t01.mp3", "format": "VBR MP3", "size": "5000000", "track": "1"},
        {"name": "cover.jpg", "format": "JPEG", "size": "204800"},
        {"name": "gd77.txt", "format": "Text", "size": "1024"}
      ],
      "server": "ia601234.us.archive.org"
    }
    """

    @Test func parseMetadataExtractsReleaseFields() throws {
        let release = try ArchiveOrgClient.parseMetadata(Data(metadataJSON.utf8), identifier: "gd1977-05-08")
        #expect(release.identifier == "gd1977-05-08")
        #expect(release.title == "Barton Hall")
        #expect(release.creator == "Grateful Dead")
        #expect(release.year == "1977")
    }

    @Test func parseMetadataKeepsOnlyFlacFormats() throws {
        // MP3/JPEG/Text отбрасываем — остаются только Flac и 24bit Flac.
        let release = try ArchiveOrgClient.parseMetadata(Data(metadataJSON.utf8), identifier: "gd1977-05-08")
        #expect(release.flacFiles.count == 2)
        #expect(release.flacFiles.allSatisfy { $0.format.lowercased().contains("flac") })
    }

    @Test func parseMetadataSortsFlacByTrackNumber() throws {
        // В JSON t02 идёт раньше t01 — после разбора сортируем по номеру дорожки.
        let release = try ArchiveOrgClient.parseMetadata(Data(metadataJSON.utf8), identifier: "gd1977-05-08")
        #expect(release.flacFiles.map(\.name) == ["gd77-05-08d1t01.flac", "gd77-05-08d1t02.flac"])
        #expect(release.flacFiles.map(\.track) == [1, 2])
    }

    @Test func parseMetadataParsesSizeTitleAndDuration() throws {
        let release = try ArchiveOrgClient.parseMetadata(Data(metadataJSON.utf8), identifier: "gd1977-05-08")
        let first = release.flacFiles[0]
        #expect(first.format == "Flac")
        #expect(first.sizeBytes == 31_456_789)
        #expect(first.title == "Minglewood Blues")
        // "365.5" — секунды дробью.
        #expect(first.durationSeconds == 365.5)

        let second = release.flacFiles[1]
        #expect(second.format == "24bit Flac")
        #expect(second.sizeBytes == 48_000_000)
        // "6:05" — минуты:секунды → 365.
        #expect(second.durationSeconds == 365)
    }

    @Test func parseMetadataEmptyWhenNoFlac() throws {
        let json = """
        {"metadata": {"identifier": "x"}, "files": [
          {"name": "a.mp3", "format": "VBR MP3"},
          {"name": "b.jpg", "format": "JPEG"}
        ]}
        """
        let release = try ArchiveOrgClient.parseMetadata(Data(json.utf8), identifier: "x")
        #expect(release.flacFiles.isEmpty)
    }

    @Test func flacFormatMatchIsCaseInsensitive() {
        #expect(ArchiveOrgClient.isFlacFormat("Flac"))
        #expect(ArchiveOrgClient.isFlacFormat("FLAC"))
        #expect(ArchiveOrgClient.isFlacFormat("24bit Flac"))
        #expect(ArchiveOrgClient.isFlacFormat("24Bit FLAC"))
        #expect(ArchiveOrgClient.isFlacFormat("VBR MP3") == false)
        #expect(ArchiveOrgClient.isFlacFormat(nil) == false)
    }
}
