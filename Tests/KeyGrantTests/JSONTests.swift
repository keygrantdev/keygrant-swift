import Foundation
import Testing

@testable import KeyGrant

/// JSON as JavaScript reads it (`JSON.parse`) and writes it (`JSON.stringify`): the server's
/// bodies, a lease's payload and the state file are read here as the reference reads them.
@Suite("JSON, as JavaScript reads and writes it", suiteTimeLimit)
struct JSONTests {
    @Test(arguments: [
        #"{"a":1,}"#, "[1,]", "[1,,2]", #"{"a":1 "b":2}"#, "{'a':1}", "{a:1}", #"{"a":1}//"#, "/* */{}", "NaN", "Infinity",
        "-Infinity", "01", "-01", "+1", ".5", "1.", "1e", "1e+", "-", "0x10", #""a"#, "tru", "nul", "", " ", "[", "{",
        "{\"a\":1}x", "[1] [2]", "\u{FEFF}{}", "\u{A0}{}", "{}\u{0C}", "\"a\u{0001}b\"", "\"a\tb\"", "\"a\nb\"", #""\x41""#,
        #""\u12""#, #""\U0041""#, #""\'""#,
    ])
    func refusesWhatJSONParseRefuses(text: String) {
        #expect(JSONText.parse(text) == nil)
    }

    @Test func takesAnyValueAtTheTopAndTheFourWhitespaceCharactersAroundIt() {
        #expect(JSONText.parse("5") == 5)
        #expect(JSONText.parse(#""x""#) == "x")
        #expect(JSONText.parse("null") == .null)
        #expect(JSONText.parse(" \t\r\n true \n") == true)
        #expect(JSONText.parse(#" { "a" : [ 1 , { } , [ ] ] } "#) == ["a": [1, [:], []]])
    }

    @Test func keepsTheLastValueOfAMemberNamedTwice() {
        #expect(JSONText.parse(#"{"a":1,"a":2}"#) == ["a": 2])
        #expect(JSONText.parse(#"{"o":{"a":"x","a":"y"},"o":{"b":1}}"#) == ["o": ["b": 1]])
        #expect(JSONText.parse(#"{"a":{"b":1},"a":null}"#) == ["a": .null])
    }

    @Test func readsNumbersAsJavaScriptDoes() throws {
        #expect(JSONText.parse("1e400") == .number(.infinity))
        #expect(JSONText.parse("-1e400") == .number(-.infinity))
        #expect(JSONText.parse("1e-400") == 0)
        #expect(JSONText.parse("9007199254740993") == 9_007_199_254_740_992)
        #expect(JSONText.parse("1E2") == 100 && JSONText.parse("1e+2") == 100 && JSONText.parse("2.5e-1") == 0.25)
        let negativeZero = try #require(JSONText.parse("-0")?.numberValue)
        #expect(negativeZero == 0 && negativeZero.sign == .minus)
        let long = "0." + String(repeating: "1", count: 400)
        #expect(JSONText.parse(long)?.numberValue == Double(long))
    }

    @Test func readsEscapesAndKeepsTextAsItIs() {
        #expect(JSONText.parse(#""\"\\\/\b\f\n\r\t""#) == "\"\\/\u{8}\u{C}\n\r\t")
        #expect(JSONText.parse(#""éé""#) == "\u{E9}\u{E9}")
        #expect(JSONText.parse(#""😀""#) == "😀")
        #expect(JSONText.parse("\"😀 e\u{301} \u{2028}\"") == "😀 e\u{301} \u{2028}")
        #expect(JSONText.parse(#""a\u0000b""#) == "a\u{0}b")
    }

    @Test func readsAnEscapedLoneSurrogateAsTheReplacementCharacterWhichSwiftCannotHoldOtherwise() {
        #expect(JSONText.parse(#""\ud800""#) == "\u{FFFD}")
        #expect(JSONText.parse(#""\udc00x""#) == "\u{FFFD}x")
        #expect(JSONText.parse(#""\ud800A""#) == "\u{FFFD}A")
        #expect(JSONText.parse(#""\ud800𐀀""#) == "\u{FFFD}\u{10000}")
    }

    @Test func decodesBytesAsTextDecoderDoesReplacingWhatIsNotUTF8AndDroppingAByteOrderMark() {
        var bytes = Array(#"{"s":""#.utf8)
        bytes += [0xFF, 0xFE, 0x41, 0xC3]
        bytes += Array(#""}"#.utf8)
        #expect(JSONText.parse(decoding: Data(bytes)) == ["s": "\u{FFFD}\u{FFFD}A\u{FFFD}"])
        #expect(JSONText.parse(decoding: Data([0xEF, 0xBB, 0xBF] + Array("[1]".utf8))) == [1])
        // One mark is dropped, as TextDecoder drops one; text read as Node's readFile reads it keeps it.
        #expect(JSONText.parse(decoding: Data([0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF] + Array("[1]".utf8))) == nil)
        #expect(JSONText.parse("\u{FEFF}[1]") == nil)
    }

    @Test func takesNestingAThousandDeepAndHandlesItWithoutRecursion() async throws {
        let depth = 1_000
        #expect(JSONText.maxDepth == depth)
        let arrays = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        let objects = String(repeating: #"{"a":"#, count: depth - 1) + "{}" + String(repeating: "}", count: depth - 1)
        for text in [arrays, objects] {
            // Parsed here, and released here at the end: releasing a value does recurse.
            let parsed = try #require(JSONText.parse(text))
            let again = try #require(JSONText.parse(text))
            // Compared, hashed and written on a thread whose 64 KB stack holds a few hundred frames:
            // done with recursion, a thousand levels would overflow it.
            let (equal, sameHash, written) = await onSmallStack {
                (parsed == again, parsed.hashValue == again.hashValue, JSONText.text(parsed))
            }
            #expect(equal && sameHash)
            #expect(written == text)
            withExtendedLifetime((parsed, again)) {}
        }
        // One deeper is refused (README, Parity): a Swift value that deep is released recursively.
        #expect(JSONText.parse("[" + arrays + "]") == nil)
    }

    @Test(arguments: [
        (1e21, "1e+21"), (1e20, "100000000000000000000"), (123_456_789_012_345_683_968, "123456789012345680000"),
        (1.5e-7, "1.5e-7"), (1e-7, "1e-7"), (0.000001, "0.000001"), (0.1, "0.1"), (-2.5, "-2.5"), (123.456, "123.456"),
        (-0.0, "0"), (Double.leastNonzeroMagnitude, "5e-324"), (1.7976931348623157e308, "1.7976931348623157e+308"), (1_790_000_000_000, "1790000000000"),
        (Double.infinity, "null"), (-Double.infinity, "null"), (Double.nan, "null"), (1e15, "1000000000000000"),
    ])
    func writesNumbersAsJavaScriptPrintsThem(value: Double, text: String) {
        #expect(JSONText.numberText(value) == text)
        if value.isFinite { #expect(Double(text) == value) }
    }

    @Test func writesStringsAsJSONStringifyEscapesThem() {
        #expect(JSONText.text("\"\\/\u{8}\u{C}\n\r\t\u{1}\u{1F}\u{7F}é😀\u{2028}") == #""\"\\/\b\f\n\r\t\u0001\u001f"# + "\u{7F}é😀\u{2028}\"")
    }

    @Test func writesWhatItReadsBackAsTheSameValue() {
        let value: LicenseJSON = [
            "s": "e\u{301} \u{E9} \"q\" \u{0}", "n": [0, -1.5, 1e300, 9_007_199_254_740_991], "b": [true, false, .null], "o": ["": [:]],
        ]
        #expect(JSONText.parse(JSONText.text(value)) == value)
        #expect(JSONText.text(["b": 1, "a": 2, "B": 3]) == #"{"B":3,"a":2,"b":1}"#)
    }
}

/// Where the SDK reads JSON: a lease's payload, the state file, a server's body.
@Suite("JSON where the SDK reads it", suiteTimeLimit)
struct JSONEntryPointTests {
    let signer = Signer()
    let base = #""iss":"keygrant","product":"p","aid":"a","model":"perpetual","lim":1,"major":1,"ent":{},"iat":1,"exp":9999999999"#

    /// A lease whose payload is `payload`, as written.
    func verified(_ payload: String) throws -> VerifyResult {
        let token = signer.sign(input: base64URLEncode(Data(#"{"alg":"EdDSA","typ":"JWT"}"#.utf8)) + "." + base64URLEncode(Data(payload.utf8)))
        return verifyLease(token, keys: try KeySet(publicJWK: signer.publicJWK), now: 0)
    }

    @Test func readsALeasesPayloadAsTheReferenceDoes() throws {
        #expect(try verified(#"{"sub":"K",\#(base),}"#).failure == .badClaims)
        #expect(try verified(#"{"sub":"FIRST",\#(base),"sub":"SECOND"}"#).claims?.sub == "SECOND")
        #expect(try verified(#"{"sub":"K",\#(base),"x":1e400}"#).failure == nil)
        let deep = String(repeating: "[", count: 600) + String(repeating: "]", count: 600)
        #expect(try verified(#"{"sub":"K",\#(base),"x":\#(deep)}"#).failure == nil)
        // TextDecoder drops a byte-order mark before JSON.parse reads the payload.
        #expect(try verified("\u{FEFF}" + #"{"sub":"K",\#(base)}"#).failure == nil)
    }

    @Test func setsAStateFileWithAByteOrderMarkAsideAsTheReferenceCannotParseIt() async throws {
        let fs = MemoryFileSystem([statePath: "\u{FEFF}" + saved])
        #expect(try await storage(fs).read() == nil)
        #expect(fs.files.keys.contains { $0.hasSuffix(".corrupt") })
    }

    @Test func neverReadsNorWritesBackAPurchaseSecretAnEarlierVersionStored() async throws {
        let retired = #""purchaseToken":"q1w2e3r4t5y6u7i8o9p0a1s2d3f4g5h6j7k8l9z0x1c","purchaseTokenAt":1756913600000,"claimAskedAt":1756999940000"#
        let fs = MemoryFileSystem([statePath: #"{"trialStart":1756740800000,"# + retired + #","later":{"n":1}}"#])
        let storage = storage(fs)
        let state = try #require(try await storage.read())
        #expect(state == StoredState(trialStart: 1_756_740_800_000, otherFields: ["later": ["n": 1]]))
        try await storage.write(state)
        #expect(fs.files[statePath].flatMap(JSONText.parse) == ["trialStart": 1_756_740_800_000, "later": ["n": 1]])
    }

    @Test func neverWritesAPurchaseSecretSetAmongTheOtherFieldsByHand() {
        let state = StoredState(
            trialStart: 1_756_740_800_000,
            otherFields: [
                "purchaseToken": "q1w2e3r4t5y6u7i8o9p0a1s2d3f4g5h6j7k8l9z0x1c", "purchaseTokenAt": 1_756_913_600_000,
                "claimAskedAt": 1_756_999_940_000, "later": ["n": 1],
            ]
        )
        #expect(state.json == ["trialStart": 1_756_740_800_000, "later": ["n": 1]])
    }

    @Test func writesBackANumberPastADoubleAsNullAsJSONStringifyDoes() async throws {
        let fs = MemoryFileSystem([statePath: #"{"key":"K","x":1e400}"#])
        let storage = storage(fs)
        let state = try #require(try await storage.read())
        #expect(state.otherFields["x"] == .number(.infinity))
        try await storage.write(state)
        #expect(fs.files[statePath].flatMap(JSONText.parse) == ["key": "K", "x": .null])
    }
}
