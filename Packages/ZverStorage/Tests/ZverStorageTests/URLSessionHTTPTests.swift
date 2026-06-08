import Testing
import Foundation
@testable import ZverStorage

/// Тесты ЧИСТОГО правила диспозиции приёмника при скачивании
/// (`URLSessionHTTPClient.downloadDisposition`).
///
/// Сам `URLSessionHTTPClient.download` — рантайм-адаптер поверх `URLSession` (сетью
/// его проверяет владелец на устройстве), но решение «append/overwrite/leave» по
/// HTTP-статусу — чистое и обязано быть покрыто: именно его дефект (мутация приёмника
/// телом ошибки на не-2xx) безвозвратно повреждал докачку.
@Suite struct URLSessionHTTPTests {
    typealias Disposition = URLSessionHTTPClient.DownloadDisposition

    // MARK: - 206: докачка

    @Test func partialContentWithExistingPrefixAppends() {
        #expect(
            URLSessionHTTPClient.downloadDisposition(statusCode: 206, destinationExists: true)
                == .append
        )
    }

    @Test func partialContentWithoutPrefixOverwrites() {
        // 206 без лежащего префикса — дописывать некуда: материализуем целиком.
        #expect(
            URLSessionHTTPClient.downloadDisposition(statusCode: 206, destinationExists: false)
                == .overwrite
        )
    }

    // MARK: - 200: полное тело

    @Test func okOverwritesRegardlessOfExisting() {
        #expect(
            URLSessionHTTPClient.downloadDisposition(statusCode: 200, destinationExists: false)
                == .overwrite
        )
        #expect(
            URLSessionHTTPClient.downloadDisposition(statusCode: 200, destinationExists: true)
                == .overwrite
        )
    }

    // MARK: - не-2xx: приёмник НЕ трогаем (регрессия повреждения докачки)

    @Test func transientServerErrorLeavesPrefixUntouched() {
        // 5xx на докачке (истёкший href, троттлинг и т.п.): тело ошибки в temp
        // НЕ должно затереть валидный частичный префикс — иначе докачка ломается
        // навсегда и sha никогда не сойдётся.
        for status in [500, 502, 503, 504] {
            #expect(
                URLSessionHTTPClient.downloadDisposition(statusCode: status, destinationExists: true)
                    == .leaveUntouched
            )
        }
    }

    @Test func notFoundOrGoneOrRangeNotSatisfiableLeaveUntouched() {
        // 404/410 (истёкший href), 416 (Range вне диапазона), 401/403 — на любом
        // из них приёмник остаётся нетронутым (даже если ошибка фатальна, валидный
        // префикс не теряется).
        for status in [401, 403, 404, 410, 416] {
            #expect(
                URLSessionHTTPClient.downloadDisposition(statusCode: status, destinationExists: true)
                    == .leaveUntouched
            )
            #expect(
                URLSessionHTTPClient.downloadDisposition(statusCode: status, destinationExists: false)
                    == .leaveUntouched
            )
        }
    }
}
