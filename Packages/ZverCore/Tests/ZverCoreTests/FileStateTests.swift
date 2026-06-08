import Foundation
import Testing
@testable import ZverCore

@Suite struct FileStateTests {

    // MARK: - rawValue (строки для БД)

    @Test func rawValuesAreStableStrings() {
        #expect(FileState.local.rawValue == "local")
        #expect(FileState.uploading.rawValue == "uploading")
        #expect(FileState.backedUp.rawValue == "backedUp")
        #expect(FileState.remote.rawValue == "remote")
        #expect(FileState.downloading.rawValue == "downloading")
    }

    @Test func initFromRawValueRoundTrips() {
        for state in FileState.allCases {
            #expect(FileState(rawValue: state.rawValue) == state)
        }
    }

    // MARK: - hasLocalFile

    @Test func hasLocalFileTrueForEverythingButRemote() {
        #expect(FileState.local.hasLocalFile)
        #expect(FileState.uploading.hasLocalFile)
        #expect(FileState.backedUp.hasLocalFile)
        #expect(FileState.downloading.hasLocalFile)
        #expect(!FileState.remote.hasLocalFile)
    }

    // MARK: - isInCloud

    @Test func isInCloudTrueForBackedUpAndRemote() {
        #expect(FileState.backedUp.isInCloud)
        #expect(FileState.remote.isInCloud)
        #expect(!FileState.local.isInCloud)
        #expect(!FileState.uploading.isInCloud)
        #expect(!FileState.downloading.isInCloud)
    }

    // MARK: - canTransition (граф жизненного цикла)

    @Test func validTransitionsAreAllowed() {
        // local ──upload──▶ uploading
        #expect(FileState.local.canTransition(to: .uploading))
        // uploading ──ok+shaОК──▶ backedUp
        #expect(FileState.uploading.canTransition(to: .backedUp))
        // uploading ──fail──▶ local (откат)
        #expect(FileState.uploading.canTransition(to: .local))
        // backedUp ──«Выгрузить»──▶ remote
        #expect(FileState.backedUp.canTransition(to: .remote))
        // remote ──«Скачать»──▶ downloading
        #expect(FileState.remote.canTransition(to: .downloading))
        // downloading ──ok+shaОК──▶ backedUp
        #expect(FileState.downloading.canTransition(to: .backedUp))
        // downloading ──fail──▶ remote (откат)
        #expect(FileState.downloading.canTransition(to: .remote))
    }

    @Test func invalidTransitionsAreRejected() {
        #expect(!FileState.local.canTransition(to: .remote))
        #expect(!FileState.local.canTransition(to: .downloading))
        #expect(!FileState.local.canTransition(to: .backedUp))
        #expect(!FileState.remote.canTransition(to: .backedUp))
        #expect(!FileState.remote.canTransition(to: .local))
        #expect(!FileState.remote.canTransition(to: .uploading))
        #expect(!FileState.backedUp.canTransition(to: .uploading))
        #expect(!FileState.backedUp.canTransition(to: .downloading))
        #expect(!FileState.uploading.canTransition(to: .remote))
        #expect(!FileState.uploading.canTransition(to: .downloading))
        #expect(!FileState.downloading.canTransition(to: .local))
        #expect(!FileState.downloading.canTransition(to: .uploading))
    }

    @Test func selfTransitionIsIdempotentNoOp() {
        // Переход в то же состояние — не валидное ребро графа (нечего менять).
        for state in FileState.allCases {
            #expect(!state.canTransition(to: state))
        }
    }
}
