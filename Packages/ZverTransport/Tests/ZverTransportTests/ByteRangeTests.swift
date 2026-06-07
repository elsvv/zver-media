import Testing
import Foundation
@testable import ZverTransport

@Suite struct ByteRangeTests {
    // MARK: - Отсутствие/пустой заголовок → full

    @Test func nilHeaderIsFull() {
        #expect(ByteRange.parse(header: nil, fileSize: 1000) == .full)
    }

    @Test func emptyHeaderIsFull() {
        #expect(ByteRange.parse(header: "", fileSize: 1000) == .full)
        #expect(ByteRange.parse(header: "   ", fileSize: 1000) == .full)
    }

    // MARK: - bytes=start-end

    @Test func explicitClosedRange() {
        #expect(ByteRange.parse(header: "bytes=0-99", fileSize: 1000) == .partial(start: 0, end: 99))
        #expect(ByteRange.parse(header: "bytes=100-199", fileSize: 1000) == .partial(start: 100, end: 199))
    }

    @Test func closedRangeEndClampedToFileSize() {
        // end за пределами файла → клампим к fileSize-1.
        #expect(ByteRange.parse(header: "bytes=0-100000", fileSize: 1000) == .partial(start: 0, end: 999))
        #expect(ByteRange.parse(header: "bytes=500-999999", fileSize: 1000) == .partial(start: 500, end: 999))
    }

    @Test func wholeFileViaExplicitRange() {
        #expect(ByteRange.parse(header: "bytes=0-999", fileSize: 1000) == .partial(start: 0, end: 999))
    }

    // MARK: - bytes=start- (открытый конец)

    @Test func openEndedRange() {
        #expect(ByteRange.parse(header: "bytes=500-", fileSize: 1000) == .partial(start: 500, end: 999))
        #expect(ByteRange.parse(header: "bytes=0-", fileSize: 1000) == .partial(start: 0, end: 999))
    }

    // MARK: - bytes=-suffix (последние N байт)

    @Test func suffixRange() {
        #expect(ByteRange.parse(header: "bytes=-200", fileSize: 1000) == .partial(start: 800, end: 999))
        #expect(ByteRange.parse(header: "bytes=-1", fileSize: 1000) == .partial(start: 999, end: 999))
    }

    @Test func suffixLargerThanFileClampsToWholeFile() {
        // Запросили больше, чем есть → весь файл.
        #expect(ByteRange.parse(header: "bytes=-5000", fileSize: 1000) == .partial(start: 0, end: 999))
    }

    @Test func suffixZeroIsUnsatisfiable() {
        // bytes=-0 — последние ноль байт, нечего отдать.
        #expect(ByteRange.parse(header: "bytes=-0", fileSize: 1000) == .unsatisfiable)
    }

    // MARK: - Вне границ → unsatisfiable (416)

    @Test func startBeyondFileIsUnsatisfiable() {
        #expect(ByteRange.parse(header: "bytes=1000-1100", fileSize: 1000) == .unsatisfiable)
        #expect(ByteRange.parse(header: "bytes=5000-", fileSize: 1000) == .unsatisfiable)
    }

    @Test func startEqualsFileSizeIsUnsatisfiable() {
        // Первый недоступный байт — индекс == fileSize.
        #expect(ByteRange.parse(header: "bytes=1000-", fileSize: 1000) == .unsatisfiable)
    }

    // MARK: - Пустой файл

    @Test func anyRangeOnEmptyFileIsUnsatisfiable() {
        #expect(ByteRange.parse(header: "bytes=0-0", fileSize: 0) == .unsatisfiable)
        #expect(ByteRange.parse(header: "bytes=0-", fileSize: 0) == .unsatisfiable)
        #expect(ByteRange.parse(header: "bytes=-10", fileSize: 0) == .unsatisfiable)
    }

    // MARK: - Битый Range → full (не unsatisfiable, мягкий фоллбэк)

    @Test func garbageHeaderIsFull() {
        #expect(ByteRange.parse(header: "garbage", fileSize: 1000) == .full)
        #expect(ByteRange.parse(header: "bytes=abc-def", fileSize: 1000) == .full)
        #expect(ByteRange.parse(header: "bytes=", fileSize: 1000) == .full)
        #expect(ByteRange.parse(header: "bytes=-", fileSize: 1000) == .full)
        #expect(ByteRange.parse(header: "items=0-10", fileSize: 1000) == .full)
    }

    @Test func reversedRangeIsFull() {
        // start > end (после кламп) — невалидно → мягкий фоллбэк к full.
        #expect(ByteRange.parse(header: "bytes=500-100", fileSize: 1000) == .full)
    }

    @Test func multipartRangeFallsBackToFull() {
        // Множественные диапазоны не поддерживаем → отдаём весь файл.
        #expect(ByteRange.parse(header: "bytes=0-99,200-299", fileSize: 1000) == .full)
    }

    // MARK: - Пробелы внутри

    @Test func whitespaceAroundRangeIsTolerated() {
        #expect(ByteRange.parse(header: "bytes= 0-99 ", fileSize: 1000) == .partial(start: 0, end: 99))
        #expect(ByteRange.parse(header: " bytes=0-99", fileSize: 1000) == .partial(start: 0, end: 99))
    }
}
