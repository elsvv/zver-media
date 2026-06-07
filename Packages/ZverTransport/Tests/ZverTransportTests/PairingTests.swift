import Testing
import Foundation
@testable import ZverTransport

@Suite struct PairingTests {
    // MARK: - Генерация кода

    @Test func generatedCodeIsExactlySixDigits() {
        // Многократно: ведущие нули допустимы, поэтому строка должна оставаться
        // ровно 6 символов даже при малых значениях.
        for _ in 0..<1000 {
            let code = Pairing.generateCode()
            #expect(code.count == 6)
            #expect(code.allSatisfy { $0.isNumber })
            #expect(code.allSatisfy { ("0"..."9").contains($0) })
        }
    }

    @Test func generatedCodesVary() {
        // Не должно быть константы: за 200 генераций ждём минимум пару разных.
        var seen = Set<String>()
        for _ in 0..<200 { seen.insert(Pairing.generateCode()) }
        #expect(seen.count > 1)
    }

    // MARK: - Генерация токена

    @Test func generatedTokenIs256BitHexLowercase() {
        let token = Pairing.generateToken()
        // 256 бит = 32 байта = 64 hex-символа.
        #expect(token.count == 64)
        #expect(token == token.lowercased())
        let hexDigits = CharacterSet(charactersIn: "0123456789abcdef")
        #expect(token.unicodeScalars.allSatisfy { hexDigits.contains($0) })
    }

    @Test func generatedTokensVary() {
        let a = Pairing.generateToken()
        let b = Pairing.generateToken()
        #expect(a != b)
    }

    // MARK: - Сверка кода

    @Test func verifyAcceptsMatchingCode() {
        #expect(Pairing.verify(code: "012345", expected: "012345"))
    }

    @Test func verifyRejectsWrongCode() {
        #expect(!Pairing.verify(code: "000000", expected: "012345"))
    }

    @Test func verifyRejectsDifferentLength() {
        // Разной длины строки не равны.
        #expect(!Pairing.verify(code: "12345", expected: "012345"))
        #expect(!Pairing.verify(code: "0123456", expected: "012345"))
    }

    @Test func verifyIsCaseAndContentSensitive() {
        #expect(!Pairing.verify(code: "012346", expected: "012345"))
    }

    // MARK: - Round-trip сообщений

    @Test func pairRequestRoundTrip() throws {
        let original = PairRequest(code: "098765")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PairRequest.self, from: data)
        #expect(decoded == original)
        #expect(decoded.code == "098765")
    }

    @Test func pairResponseRoundTrip() throws {
        let original = PairResponse(token: "deadbeef")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PairResponse.self, from: data)
        #expect(decoded == original)
        #expect(decoded.token == "deadbeef")
    }

    @Test func pairRequestDecodesFromJSON() throws {
        let json = Data(#"{"code":"007007"}"#.utf8)
        let decoded = try JSONDecoder().decode(PairRequest.self, from: json)
        #expect(decoded.code == "007007")
    }

    @Test func pairResponseDecodesFromJSON() throws {
        let json = Data(#"{"token":"abc123"}"#.utf8)
        let decoded = try JSONDecoder().decode(PairResponse.self, from: json)
        #expect(decoded.token == "abc123")
    }
}
