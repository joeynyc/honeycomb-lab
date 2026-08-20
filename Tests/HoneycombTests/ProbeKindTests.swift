import XCTest
@testable import Honeycomb

final class ProbeKindTests: XCTestCase {
    func testHistoricalVllmSSHName() {
        XCTAssertEqual(ProbeKind.parse("vllm-ssh"), .vllmSSH)
        XCTAssertEqual(ProbeKind.vllmSSH.rawValue, "vllm-ssh")
    }

    func testSSHServeAliasMapsToSameKind() {
        XCTAssertEqual(ProbeKind.parse("ssh-serve"), .vllmSSH)
    }

    func testUnknownProbeRejected() {
        XCTAssertNil(ProbeKind.parse("mystery"))
    }
}
