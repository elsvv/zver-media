import Testing
import Foundation
@testable import ZverMetadata

@Suite struct CueSheetTests {
    // Реалистичный single-file cue образа: REM-строки, альбомные TITLE/PERFORMER
    // до FILE, отступы, INDEX 00 пре-гэп у 2-го трека.
    private let imageCue = """
    REM GENRE Trip-Hop
    REM DATE 1994
    PERFORMER "Portishead"
    TITLE "Dummy"
    FILE "Portishead - Dummy.flac" WAVE
      TRACK 01 AUDIO
        TITLE "Mysterons"
        PERFORMER "Portishead"
        INDEX 01 00:00:00
      TRACK 02 AUDIO
        TITLE "Sour Times"
        INDEX 00 04:12:30
        INDEX 01 04:14:05
      TRACK 03 AUDIO
        TITLE "Strangers"
        INDEX 01 08:15:00
    """

    @Test func parsesSingleFileImageTracks() {
        let cue = CueSheet.parse(from: imageCue)
        #expect(cue.files.count == 1)
        #expect(cue.isSingleFileImage)
        let file = cue.files[0]
        #expect(file.fileName == "Portishead - Dummy.flac")
        #expect(file.tracks.count == 3)

        #expect(file.tracks[0].index == 1)
        #expect(file.tracks[0].title == "Mysterons")
        #expect(file.tracks[0].performer == "Portishead")
        #expect(file.tracks[0].startFrames75 == 0)

        #expect(file.tracks[1].index == 2)
        #expect(file.tracks[1].title == "Sour Times")
        // Трек без своего PERFORMER: альбомный PERFORMER не наследуется (nil).
        #expect(file.tracks[1].performer == nil)
    }

    @Test func trackStartUsesIndex01NotIndex00() {
        // Граница = INDEX 01, а не INDEX 00 (пре-гэп). У 2-го трека:
        // INDEX 00 = 04:12:30, INDEX 01 = 04:14:05 → берём 04:14:05.
        let cue = CueSheet.parse(from: imageCue)
        let t2 = cue.files[0].tracks[1]
        #expect(t2.startFrames75 == ((4 * 60 + 14) * 75) + 5)     // = 19055
        let t3 = cue.files[0].tracks[2]
        #expect(t3.startFrames75 == (8 * 60 + 15) * 75)           // = 37125
    }

    @Test func msfToCdFramesArithmetic() {
        // MM:SS:FF → 1/75 c: ((MM·60+SS)·75 + FF).
        let cue = CueSheet.parse(from: """
        FILE "x.flac" WAVE
          TRACK 01 AUDIO
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            INDEX 01 01:30:37
        """)
        #expect(cue.files[0].tracks[0].startFrames75 == 0)
        #expect(cue.files[0].tracks[1].startFrames75 == ((1 * 60 + 30) * 75) + 37)  // 6787
    }

    @Test func frameOffsetsConvertsFramesToSamples() {
        // 44100 Гц: 44100/75 = 588 сэмплов на CD-фрейм (точно).
        let cue = CueSheet.parse(from: """
        FILE "x.flac" WAVE
          TRACK 01 AUDIO
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            INDEX 01 00:02:00
          TRACK 03 AUDIO
            INDEX 01 00:05:00
        """)
        let expected: [Int64] = [0, 2 * 44100, 5 * 44100]
        #expect(cue.frameOffsets(sampleRate: 44100) == expected)
    }

    @Test func frameOffsetsRoundsToNearestSample() {
        // Нецелое деление → округление к ближайшему сэмплу.
        // frames75=1 @100Гц: 1/75·100 = 1.333 → 1; frames75=2: 2.667 → 3.
        let cue = CueSheet.parse(from: """
        FILE "x.flac" WAVE
          TRACK 01 AUDIO
            INDEX 01 00:00:01
          TRACK 02 AUDIO
            INDEX 01 00:00:02
        """)
        let expected: [Int64] = [1, 3]
        #expect(cue.frameOffsets(sampleRate: 100) == expected)
    }

    @Test func multiFileCueIsNotImage() {
        // FILE на каждый трек — обычный многофайловый альбом, НЕ образ.
        let cue = CueSheet.parse(from: """
        FILE "01 - one.flac" WAVE
          TRACK 01 AUDIO
            TITLE "One"
            INDEX 01 00:00:00
        FILE "02 - two.flac" WAVE
          TRACK 01 AUDIO
            TITLE "Two"
            INDEX 01 00:00:00
        """)
        #expect(cue.files.count == 2)
        #expect(!cue.isSingleFileImage)
        #expect(cue.files[0].fileName == "01 - one.flac")
        #expect(cue.files[1].fileName == "02 - two.flac")
    }

    @Test func singleFileSingleTrackIsNotImage() {
        // Один FILE и один TRACK — не образ (раскрывать нечего).
        let cue = CueSheet.parse(from: """
        FILE "whole.flac" WAVE
          TRACK 01 AUDIO
            INDEX 01 00:00:00
        """)
        #expect(cue.files.count == 1)
        #expect(!cue.isSingleFileImage)
    }

    @Test func unquotedFileNameDropsTrailingType() {
        let cue = CueSheet.parse(from: """
        FILE image.wav WAVE
          TRACK 01 AUDIO
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            INDEX 01 00:01:00
        """)
        #expect(cue.files[0].fileName == "image.wav")
        #expect(cue.isSingleFileImage)
    }

    @Test func toleratesBOMAndCRLF() {
        let cue = CueSheet.parse(from:
            "\u{FEFF}FILE \"x.flac\" WAVE\r\n  TRACK 01 AUDIO\r\n    INDEX 01 00:00:00\r\n"
            + "  TRACK 02 AUDIO\r\n    INDEX 01 00:03:00\r\n")
        #expect(cue.files.count == 1)
        #expect(cue.files[0].fileName == "x.flac")
        #expect(cue.files[0].tracks.count == 2)
        #expect(cue.files[0].tracks[1].startFrames75 == 3 * 75)   // 00:03:00 = 3 c
    }

    @Test func emptyContentGivesNoFiles() {
        #expect(CueSheet.parse(from: "").files.isEmpty)
        #expect(!CueSheet.parse(from: "REM only comment\n").isSingleFileImage)
    }

    @Test func trackBeforeFileIsIgnored() {
        // TRACK до FILE — некорректно; не должно падать и создавать треки.
        let cue = CueSheet.parse(from: """
        TRACK 01 AUDIO
          INDEX 01 00:00:00
        """)
        #expect(cue.files.isEmpty)
    }

    @Test func frameOffsetsEmptyWhenNoFiles() {
        #expect(CueSheet.parse(from: "").frameOffsets(sampleRate: 44100).isEmpty)
    }
}
