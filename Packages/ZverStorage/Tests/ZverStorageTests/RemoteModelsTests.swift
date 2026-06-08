import Testing
import Foundation
@testable import ZverStorage

@Suite struct RemoteModelsTests {
    // MARK: - RemoteResource

    @Test func remoteResourceInitAndFields() {
        let r = RemoteResource(
            path: "library/album/track.flac",
            name: "track.flac",
            size: 12_345,
            sha256: "abc123",
            isDir: false
        )
        #expect(r.path == "library/album/track.flac")
        #expect(r.name == "track.flac")
        #expect(r.size == 12_345)
        #expect(r.sha256 == "abc123")
        #expect(r.isDir == false)
    }

    @Test func remoteResourceEquality() {
        let a = RemoteResource(path: "p", name: "n", size: 10, sha256: "s", isDir: false)
        let b = RemoteResource(path: "p", name: "n", size: 10, sha256: "s", isDir: false)
        let c = RemoteResource(path: "p", name: "n", size: 11, sha256: "s", isDir: false)
        #expect(a == b)
        #expect(a != c)
    }

    @Test func remoteResourceCodableRoundTrip() throws {
        let original = RemoteResource(
            path: "library/a/b.flac",
            name: "b.flac",
            size: 999,
            sha256: "deadbeef",
            isDir: false
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RemoteResource.self, from: data)
        #expect(decoded == original)
    }

    @Test func remoteResourceCodableRoundTripDirectoryWithoutSha() throws {
        let original = RemoteResource(
            path: "library/a",
            name: "a",
            size: 0,
            sha256: nil,
            isDir: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RemoteResource.self, from: data)
        #expect(decoded == original)
        #expect(decoded.sha256 == nil)
        #expect(decoded.isDir)
    }

    // MARK: - UploadTarget / DownloadTarget

    @Test func uploadTargetCarriesLocalAndRemote() {
        let url = URL(fileURLWithPath: "/tmp/track.flac")
        let target = UploadTarget(localFile: url, remotePath: "library/a/track.flac")
        #expect(target.localFile == url)
        #expect(target.remotePath == "library/a/track.flac")
    }

    @Test func downloadTargetCarriesResumeOffset() {
        let url = URL(fileURLWithPath: "/tmp/track.flac")
        let target = DownloadTarget(remotePath: "library/a/track.flac", localFile: url, resumeFrom: 4_096)
        #expect(target.remotePath == "library/a/track.flac")
        #expect(target.localFile == url)
        #expect(target.resumeFrom == 4_096)
    }

    @Test func downloadTargetDefaultsResumeToZero() {
        let url = URL(fileURLWithPath: "/tmp/track.flac")
        let target = DownloadTarget(remotePath: "p", localFile: url)
        #expect(target.resumeFrom == 0)
    }

    // MARK: - RemoteError

    @Test func remoteErrorRateLimitedCarriesRetryAfter() {
        let err = RemoteError.rateLimited(retryAfter: 30)
        if case let .rateLimited(retryAfter) = err {
            #expect(retryAfter == 30)
        } else {
            Issue.record("ожидался .rateLimited")
        }
    }

    @Test func remoteErrorRateLimitedAllowsNilRetryAfter() {
        let err = RemoteError.rateLimited(retryAfter: nil)
        if case let .rateLimited(retryAfter) = err {
            #expect(retryAfter == nil)
        } else {
            Issue.record("ожидался .rateLimited")
        }
    }

    @Test func remoteErrorServerCarriesStatus() {
        let err = RemoteError.server(status: 503)
        if case let .server(status) = err {
            #expect(status == 503)
        } else {
            Issue.record("ожидался .server")
        }
    }

    @Test func remoteErrorTransportWrapsUnderlying() {
        struct Boom: Error {}
        let err = RemoteError.transport(underlying: Boom())
        if case let .transport(underlying) = err {
            #expect(underlying is Boom)
        } else {
            Issue.record("ожидался .transport")
        }
    }

    @Test func remoteErrorIsError() {
        // RemoteError должен быть бросаемым (conforms to Error).
        let err: any Error = RemoteError.notFound
        #expect(err is RemoteError)
    }
}
