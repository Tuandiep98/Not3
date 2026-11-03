import XCTest
@testable import Not3

final class ShareParsingTests: XCTestCase {
    func testCodes() {
        XCTAssertEqual(ShareParsing.code(for: URL(string: "https://github.com/acme/app-ios/pull/42")!), "#42")
        XCTAssertEqual(ShareParsing.code(for: URL(string: "https://github.com/acme/app-ios/issues/7#issuecomment-1")!), "#7")
        XCTAssertNil(ShareParsing.code(for: URL(string: "https://github.com/acme/app-ios")!))
        XCTAssertEqual(ShareParsing.code(for: URL(string: "https://acme.atlassian.net/browse/not-118")!), "NOT-118")
        XCTAssertEqual(ShareParsing.code(for: URL(string: "https://acme.atlassian.net/jira/software/projects/NOT/boards/1?selectedIssue=NOT-5")!), "NOT-5")
        XCTAssertNil(ShareParsing.code(for: URL(string: "https://example.com/browse/NOT-1")!))
    }

    func testTitle() {
        let pr = URL(string: "https://github.com/acme/app-ios/pull/42")!
        XCTAssertEqual(ShareParsing.title(text: "Fix login crash\nmore text", url: pr), "Fix login crash (#42)")
        XCTAssertEqual(ShareParsing.title(text: "PR #42: Fix login", url: pr), "PR #42: Fix login")
        XCTAssertEqual(ShareParsing.title(text: nil, url: pr), "app-ios #42")
        XCTAssertEqual(ShareParsing.title(text: pr.absoluteString, url: pr), "app-ios #42", "the link itself is not a title")
        XCTAssertEqual(ShareParsing.title(text: nil, url: URL(string: "https://acme.atlassian.net/browse/NOT-118")!), "NOT-118")
        XCTAssertEqual(ShareParsing.title(text: nil, url: URL(string: "https://www.example.com/a/b")!), "example.com/a/b")
        XCTAssertEqual(ShareParsing.title(text: "  \n Mua sữa ", url: nil), "Mua sữa")
    }
}
