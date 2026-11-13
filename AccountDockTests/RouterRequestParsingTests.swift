import XCTest
@testable import AccountDock

final class RouterRequestParsingTests: XCTestCase {
    private func parse(_ text: String) throws -> (HTTPRequest, Int)? {
        try HTTPParser.parse(Data(text.utf8))
    }

    func testARequestWithABodyIsReadWholeAndWaitsForMissingBytes() throws {
        let whole = try XCTUnwrap(try parse("POST /v1/messages HTTP/1.1\r\nContent-Length: 5\r\n\r\nhelloNEXT"))
        XCTAssertEqual(String(decoding: whole.0.body, as: UTF8.self), "hello")
        XCTAssertEqual(whole.1, "POST /v1/messages HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello".utf8.count)
        XCTAssertNil(try parse("POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\nhel"), "more bytes are needed")
        let chunked = try XCTUnwrap(try parse("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n"))
        XCTAssertEqual(String(decoding: chunked.0.body, as: UTF8.self), "abc")
    }

    func testABodyLengthThatCannotBeOneIsRefusedInsteadOfTrapping() {
        XCTAssertThrowsError(try parse("POST / HTTP/1.1\r\nContent-Length: -5\r\n\r\n"))
        XCTAssertThrowsError(try parse("POST / HTTP/1.1\r\nContent-Length: banana\r\n\r\n"))
        XCTAssertThrowsError(try parse("POST / HTTP/1.1\r\nContent-Length: \(HTTPParser.maxBodyBytes + 1)\r\n\r\n"))
        XCTAssertThrowsError(try parse("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n-3\r\nabc\r\n0\r\n\r\n"))
    }

    func testARouteTargetsFailuresGoBackToThePoolUnlessItAlreadyAnswered() {
        for status in [400, 401, 403, 429, 500, 503, 529] {
            XCTAssertTrue(RouterLogic.handsBackToPool(isRouteTarget: true, status: status, wroteReply: false), "\(status)")
            XCTAssertFalse(RouterLogic.handsBackToPool(isRouteTarget: false, status: status, wroteReply: false), "the pool's own \(status) is the answer")
        }
        XCTAssertTrue(RouterLogic.handsBackToPool(isRouteTarget: true, status: nil, wroteReply: false), "an unreachable target")
        XCTAssertFalse(RouterLogic.handsBackToPool(isRouteTarget: true, status: nil, wroteReply: true), "a reply already begun cannot be sent again")
        XCTAssertFalse(RouterLogic.handsBackToPool(isRouteTarget: true, status: 200, wroteReply: false))
    }

    func testAnErrorInAnOpenStreamIsWrittenAsAnErrorEvent() {
        let body = RouterLogic.errorBody(type: "overloaded_error", message: "cut off")
        let event = String(decoding: RouterLogic.streamedError(body, status: 529), as: UTF8.self)
        XCTAssertTrue(event.hasPrefix("event: error\ndata: "))
        XCTAssertTrue(event.contains("overloaded_error") && event.hasSuffix("\n\n"))
    }
}
