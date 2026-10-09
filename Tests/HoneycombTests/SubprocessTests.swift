import XCTest
@testable import Honeycomb

final class SubprocessTests: XCTestCase {
    func testShellJoinKeepsTabFormatAsOneWord() {
        XCTAssertEqual(
            Subprocess.shellJoin(["docker", "ps", "--format", "{{.Names}}\t{{.Image}}"]),
            "docker ps --format '{{.Names}}\t{{.Image}}'"
        )
    }

    func testShellJoinNeutralizesInjection() {
        XCTAssertEqual(
            Subprocess.shellJoin(["docker", "start", "x; rm -rf ~"]),
            "docker start 'x; rm -rf ~'"
        )
        XCTAssertEqual(Subprocess.shellQuote("it's"), #"'it'\''s'"#)
        XCTAssertEqual(Subprocess.shellQuote(""), "''")
    }
}
