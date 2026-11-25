import Foundation
import XCTest
@testable import SeatSixApp

final class ServerAddressFormTests: XCTestCase {
    func testEmptyFormHasNoPrematureErrorAndCannotConnect() {
        let form = ServerAddressForm()
        XCTAssertTrue(form.useHTTPS)
        XCTAssertNil(form.validationMessage)
        XCTAssertNil(form.preview)
        XCTAssertThrowsError(try form.endpoint())
    }

    func testSeparateFieldsProduceTheExactEndpointAndDefaultPort() throws {
        var form = ServerAddressForm()
        form.host = " media.example.com "
        form.port = "9443"
        form.path = "reverse/emby/"
        XCTAssertEqual(try form.endpoint().baseURL.absoluteString, "https://media.example.com:9443/reverse/emby")
        XCTAssertNil(form.validationMessage)
        form.port = ""
        XCTAssertEqual(form.preview, "https://media.example.com/reverse/emby")
        form.useHTTPS = false
        XCTAssertNil(form.preview)
        XCTAssertTrue(form.validationMessage?.contains("局域网") == true)
        form.host = "192.168.1.2"
        XCTAssertEqual(form.preview, "http://192.168.1.2/reverse/emby")
    }

    func testPastingFullURLAuthoritativelyReplacesSchemePortAndPath() {
        var form = ServerAddressForm()
        form.port = "9443"; form.path = "/old"
        form.updateHost("http://127.0.0.1:8096/jellyfin/")
        XCTAssertFalse(form.useHTTPS)
        XCTAssertEqual(form.host, "127.0.0.1")
        XCTAssertEqual(form.port, "8096")
        XCTAssertEqual(form.path, "/jellyfin/")
        XCTAssertEqual(form.preview, "http://127.0.0.1:8096/jellyfin")
        form.updateHost("https://media.example.com")
        XCTAssertTrue(form.useHTTPS)
        XCTAssertEqual(form.port, "")
        XCTAssertEqual(form.path, "")
        XCTAssertEqual(form.preview, "https://media.example.com")
    }

    func testCompactPasteKeepsSchemeAndPlainHostEditKeepsPortAndPath() {
        var form = ServerAddressForm()
        form.useHTTPS = false
        form.updateHost("nas.local:8096/base")
        XCTAssertEqual(form.preview, "http://nas.local:8096/base")
        form.updateHost("other.local")
        XCTAssertEqual(form.preview, "http://other.local:8096/base")
        form.updateHost("other.local/new")
        XCTAssertEqual(form.preview, "http://other.local/new")
    }

    func testTypingAnAddressWaitsForCommitAndPastingAnAddressSplitsImmediately() {
        var form = ServerAddressForm()
        var typed = ""
        for character in "nas.local:8096/emby" {
            typed.append(character)
            form.editHost(typed)
            XCTAssertEqual(form.host, typed)
            XCTAssertEqual(form.port, "")
            XCTAssertEqual(form.path, "")
        }
        form.editHost("nas.local:8097/emby")
        XCTAssertEqual(form.host, "nas.local:8097/emby", "Replacing a single character must not move the caret to another component")
        form.editHost("nas.local:8097/emb")
        XCTAssertEqual(form.host, "nas.local:8097/emb", "Deleting a character must not split the field")
        form.updateHost(form.host)
        XCTAssertEqual(form.preview, "https://nas.local:8097/emb")
        form.editHost("http://192.168.1.2:8096/emby")
        XCTAssertEqual(form.host, "192.168.1.2")
        XCTAssertEqual(form.port, "8096")
        XCTAssertEqual(form.path, "/emby")
        XCTAssertFalse(form.useHTTPS)
        XCTAssertEqual(form.preview, "http://192.168.1.2:8096/emby")
    }

    func testIPv6AddressesRoundTripAndRejectInvalidOrAmbiguousLiterals() throws {
        var form = ServerAddressForm()
        form.updateHost("http://[::1]:8096/emby")
        XCTAssertEqual(form.host, "[::1]")
        XCTAssertEqual(form.preview, "http://[::1]:8096/emby")
        XCTAssertEqual(ServerAddressForm(url: try form.endpoint().baseURL), form)
        form.updateHost("https://[2001:db8::1]/base")
        XCTAssertEqual(form.preview, "https://[2001:db8::1]/base")
        for host in ["[not-an-ip]", "[::1", "::1", "[fe80:garbage]"] {
            form.host = host
            XCTAssertNil(form.preview, host)
        }
    }

    func testUnicodeAndEscapedPathsPreserveTheirSemantics() throws {
        var form = ServerAddressForm()
        form.updateHost("https://media.example.com:9443/影视/%E7%94%B5%E5%BD%B1/a%20b/%25")
        let url = try form.endpoint().baseURL
        XCTAssertEqual(url.path, "/影视/电影/a b/%")
        XCTAssertFalse(url.absoluteString.contains("%2520"))
        XCTAssertEqual(ServerAddressForm(url: url).preview, form.preview)
        form.path = "电影 空间"
        XCTAssertEqual(try form.endpoint().baseURL.path, "/电影 空间")
        form.path = "/base%2Fsegment/"
        XCTAssertEqual(try form.endpoint().baseURL.absoluteString, "https://media.example.com:9443/base%2Fsegment")
    }

    func testInvalidPastesRemainVisibleAndNeverYieldAnEndpoint() {
        let invalid = ["https://user:secret@media.example.com/base", "https://media.example.com?token=value",
            "https://media.example.com#section", "ftp://media.example.com/base", "https:///base",
            "https://media.example.com:999999999999999999999999", "https://media.example.com:",
            "https://bad host/base", "https://media.example.com/base%XX", "https://media.example.com/../admin"]
        for input in invalid {
            var form = ServerAddressForm()
            form.port = "9443"; form.path = "/old"
            form.updateHost(input)
            XCTAssertEqual(form.host, input)
            XCTAssertEqual(form.port, "9443")
            XCTAssertEqual(form.path, "/old")
            XCTAssertNil(form.preview, input)
            XCTAssertNotNil(form.validationMessage, input)
        }
    }

    func testPortValidationRejectsSignsDecimalsUnicodeAndOutOfRange() {
        var form = ServerAddressForm()
        form.host = "media.example.com"
        for port in ["0", "65536", "-1", "+443", "44.3", "４４３", "443abc", "9 443", "999999999999999999999999"] {
            form.port = port
            XCTAssertNil(form.preview, port)
            XCTAssertTrue(form.validationMessage?.contains("端口号") == true, port)
        }
        for port in ["1", "65535", "", "0443"] {
            form.port = port
            XCTAssertNotNil(form.preview, port)
        }
    }

    func testMalformedAndTraversingPathsCannotEscapeTheBase() {
        var form = ServerAddressForm()
        form.host = "media.example.com"
        for path in ["/a?b=c", "/a#b", "/a\\b", "/a\nb", "/a%", "/a%2", "/a%GG", "/a/../b",
                     "/a/./b", "/a/%2e%2E/b", "/a%2f..%2fb", "/a%5cb", "/a%00b", "/a%2F"] {
            form.path = path
            XCTAssertNil(form.preview, path)
            XCTAssertTrue(form.validationMessage?.contains("路径") == true, path)
        }
    }

    func testExistingURLRehydratesWithoutInventingDefaultsOrDiscardingInvalidParts() {
        let url = URL(string: "https://media.example.com:9443/reverse/emby")!
        let form = ServerAddressForm(url: url)
        XCTAssertEqual(form.host, "media.example.com")
        XCTAssertEqual(form.port, "9443")
        XCTAssertEqual(form.path, "/reverse/emby")
        XCTAssertEqual(form.preview, url.absoluteString)
        for value in ["https://user@media.example.com", "https://media.example.com?token=x", "ftp://media.example.com"] {
            XCTAssertNil(ServerAddressForm(url: URL(string: value)!).preview)
        }
    }
}
