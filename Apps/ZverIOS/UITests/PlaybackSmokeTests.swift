import XCTest

/// Смоук-тест воспроизведения. Репродуцирует краш SIGTRAP
/// (dispatch_assert_queue_fail): после старта воспроизведения трека
/// с обложкой MediaPlayer сериализует Now Playing на своей фоновой
/// accessQueue и вызывает там MPMediaItemArtwork requestHandler —
/// MainActor-изолированное замыкание там падает.
///
/// Трек должен быть ДЛИННЫМ (8с, ui_smoke.flac): на коротком (1с) трек
/// заканчивается раньше, чем загрузится обложка, и краш-путь не выполняется.
///
/// Требование: фикстуры из scripts/make-fixtures.sh лежат в Documents
/// приложения на симуляторе (кладутся через simctl get_app_container).
final class PlaybackSmokeTests: XCTestCase {

    @MainActor
    func testTapTrackWithArtworkDoesNotCrash() throws {
        let app = XCUIApplication()
        app.launch()

        // Корень — разделы библиотеки; список треков теперь в «Песнях».
        let songs = app.staticTexts["Песни"]
        XCTAssertTrue(songs.waitForExistence(timeout: 10),
                      "Нет раздела «Песни» на корневом экране библиотеки")
        songs.tap()

        let row = app.staticTexts["Длинный трек"]
        XCTAssertTrue(row.waitForExistence(timeout: 10),
                      "В библиотеке нет «Длинный трек» — ui_smoke.flac не в Documents приложения?")
        row.tap()

        // Окно, за которое артворк загружается и Now Playing пушится с обложкой
        // (трек 8с — играет всё это время, guard по track.id проходит).
        sleep(5)

        // Живой запрос к иерархии: на упавшем приложении он честно фейлится,
        // в отличие от app.state, который может вернуть устаревшее значение.
        XCTAssertTrue(row.exists, "Приложение упало после старта воспроизведения")
        XCTAssertEqual(app.state, .runningForeground)
    }
}
