import Testing
import Foundation
@testable import ZverImport

/// Чистая логика перехвата скачиваний из webview (Bandcamp): по какому ответу
/// навигации форсить `.download` и как обезопасить имя файла назначения. WebKit
/// сюда не заглядывает — только `Bool` + `String`, поэтому тестируется через
/// `swift test`.
@Suite struct WebDownloadPolicyTests {

    // MARK: - shouldDownload

    @Test func allowsNormalPageWebKitCanShow() {
        // Обычная HTML-страница: WebKit её показывает — не перехватываем.
        #expect(WebDownloadPolicy.shouldDownload(canShowMIMEType: true, mimeType: "text/html") == false)
    }

    @Test func downloadsWhenWebKitCannotShow() {
        // Архив/бинарь, который WebKit не умеет отрисовать (application/octet-stream).
        #expect(WebDownloadPolicy.shouldDownload(canShowMIMEType: false, mimeType: "application/octet-stream"))
    }

    @Test func downloadsWhenWebKitCannotShowUnknownMIME() {
        // Неизвестный MIME + WebKit не показывает → это файл в библиотеку.
        #expect(WebDownloadPolicy.shouldDownload(canShowMIMEType: false, mimeType: nil))
    }

    @Test func forcesZipEvenIfShowable() {
        // Даже если сервер пометил zip как «показываемый» — нам нужен файл.
        #expect(WebDownloadPolicy.shouldDownload(canShowMIMEType: true, mimeType: "application/zip"))
        #expect(WebDownloadPolicy.shouldDownload(canShowMIMEType: false, mimeType: "application/zip"))
    }

    @Test func forcesAudioEvenIfWebKitCouldPlayInline() {
        // WebKit умеет проигрывать аудио inline (canShowMIMEType == true), но нам
        // нужен файл во FLAC/MP3 в библиотеку — перехватываем.
        #expect(WebDownloadPolicy.shouldDownload(canShowMIMEType: true, mimeType: "audio/x-flac"))
        #expect(WebDownloadPolicy.shouldDownload(canShowMIMEType: true, mimeType: "audio/mpeg"))
    }

    @Test func mimeMatchIsCaseInsensitive() {
        #expect(WebDownloadPolicy.shouldDownload(canShowMIMEType: true, mimeType: "AUDIO/FLAC"))
        #expect(WebDownloadPolicy.shouldDownload(canShowMIMEType: true, mimeType: "Application/Zip"))
    }

    @Test func mimeParametersAreIgnored() {
        // "audio/flac; charset=binary" — берём тип до ';'.
        #expect(WebDownloadPolicy.shouldDownload(canShowMIMEType: true, mimeType: "audio/flac; charset=binary"))
        #expect(WebDownloadPolicy.shouldDownload(canShowMIMEType: true, mimeType: "application/zip;"))
    }

    @Test func nilMIMEWithShowableStaysInPage() {
        // WebKit показывает и MIME неизвестен — не перехватываем (редкий случай).
        #expect(WebDownloadPolicy.shouldDownload(canShowMIMEType: true, mimeType: nil) == false)
    }

    @Test func plainAudioPrefixOnlyNotFalsePositive() {
        // "audiobook/..." не должен считаться аудио (сравниваем именно "audio/").
        #expect(WebDownloadPolicy.shouldDownload(canShowMIMEType: true, mimeType: "audiobook/x") == false)
    }

    // MARK: - sanitizedFilename

    @Test func keepsPlainFilename() {
        #expect(WebDownloadPolicy.sanitizedFilename("Artist - Album.zip") == "Artist - Album.zip")
    }

    @Test func stripsPathTraversal() {
        // suggestedFilename контролирует сервер — «../» отбрасываем.
        #expect(WebDownloadPolicy.sanitizedFilename("../../etc/passwd") == "passwd")
    }

    @Test func stripsSubdirectories() {
        #expect(WebDownloadPolicy.sanitizedFilename("sub/dir/track.flac") == "track.flac")
    }

    @Test func emptyOrBlankFallsBack() {
        #expect(WebDownloadPolicy.sanitizedFilename("") == "download")
        #expect(WebDownloadPolicy.sanitizedFilename("   ") == "download")
    }

    @Test func dotComponentsFallBack() {
        #expect(WebDownloadPolicy.sanitizedFilename("..") == "download")
        #expect(WebDownloadPolicy.sanitizedFilename(".") == "download")
    }

    @Test func customFallback() {
        #expect(WebDownloadPolicy.sanitizedFilename("", fallback: "release.zip") == "release.zip")
    }
}
