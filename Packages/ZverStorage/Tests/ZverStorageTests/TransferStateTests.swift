import Testing
import Foundation
@testable import ZverStorage

/// Тесты модели передачи: ``TransferState`` (стадии одной выгрузки/загрузки) и
/// ``BackupItem`` (описание задачи). Чистые значения — без сети и очереди.
@Suite struct TransferStateTests {

    // MARK: - BackupItem

    @Test func backupItemStoresFields() {
        let url = URL(fileURLWithPath: "/tmp/track.flac")
        let item = BackupItem(
            id: "t1",
            localFile: url,
            remotePath: "library/a/track.flac",
            expectedSha: "abc123",
            fileSize: 4096
        )
        #expect(item.id == "t1")
        #expect(item.localFile == url)
        #expect(item.remotePath == "library/a/track.flac")
        #expect(item.expectedSha == "abc123")
        #expect(item.fileSize == 4096)
    }

    @Test func backupItemExpectedShaIsOptional() {
        let item = BackupItem(
            id: "t2",
            localFile: URL(fileURLWithPath: "/tmp/x"),
            remotePath: "p",
            expectedSha: nil,
            fileSize: 0
        )
        #expect(item.expectedSha == nil)
    }

    @Test func backupItemEquatableByValue() {
        let a = BackupItem(id: "t", localFile: URL(fileURLWithPath: "/x"), remotePath: "p", expectedSha: "s", fileSize: 1)
        let b = BackupItem(id: "t", localFile: URL(fileURLWithPath: "/x"), remotePath: "p", expectedSha: "s", fileSize: 1)
        #expect(a == b)
    }

    // MARK: - TransferState

    @Test func transferStateCasesAreDistinct() {
        let resource = RemoteResource(path: "p", name: "p", size: 1, sha256: "s", isDir: false)
        let states: [TransferState] = [
            .queued,
            .requestingHref,
            .transferring(bytesSent: 0),
            .verifying,
            .done(resource),
            .failed(.unauthorized, attempt: 1),
        ]
        // Каждая стадия отлична от соседних.
        #expect(states[0] != states[1])
        #expect(states[2] != states[3])
        #expect(states[4] != states[5])
    }

    @Test func transferringTracksBytesSent() {
        let a = TransferState.transferring(bytesSent: 100)
        let b = TransferState.transferring(bytesSent: 200)
        #expect(a != b)
        #expect(a == .transferring(bytesSent: 100))
    }

    @Test func doneCarriesResource() {
        let resource = RemoteResource(path: "p", name: "p", size: 42, sha256: "deadbeef", isDir: false)
        let state = TransferState.done(resource)
        if case let .done(r) = state {
            #expect(r.sha256 == "deadbeef")
            #expect(r.size == 42)
        } else {
            Issue.record("ожидался .done")
        }
    }

    @Test func failedCarriesErrorAndAttempt() {
        let state = TransferState.failed(.rateLimited(retryAfter: 3), attempt: 4)
        if case let .failed(error, attempt) = state {
            #expect(attempt == 4)
            if case .rateLimited(let ra) = error {
                #expect(ra == 3)
            } else {
                Issue.record("ожидался .rateLimited")
            }
        } else {
            Issue.record("ожидался .failed")
        }
    }

    @Test func isTerminalDistinguishesFinishedStates() {
        let resource = RemoteResource(path: "p", name: "p", size: 1, sha256: nil, isDir: false)
        #expect(TransferState.done(resource).isTerminal)
        #expect(TransferState.failed(.notFound, attempt: 1).isTerminal)
        #expect(!TransferState.queued.isTerminal)
        #expect(!TransferState.requestingHref.isTerminal)
        #expect(!TransferState.transferring(bytesSent: 0).isTerminal)
        #expect(!TransferState.verifying.isTerminal)
    }
}
