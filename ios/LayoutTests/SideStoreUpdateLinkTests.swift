import Foundation
import XCTest

final class SideStoreUpdateLinkTests: XCTestCase {
    func testTargetsTheFixedHTTPSReleaseAsset() throws {
        let url = try XCTUnwrap(SideStoreUpdateLink.make())
        let link = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(link.scheme, "sidestore")
        XCTAssertEqual(link.host, "install")
        XCTAssertEqual(link.queryItems?.count, 1)
        XCTAssertEqual(link.queryItems?.first?.name, "url")
        let address = try XCTUnwrap(link.queryItems?.first?.value)
        let download = try XCTUnwrap(URLComponents(string: address))
        XCTAssertEqual(download.scheme, "https")
        XCTAssertEqual(download.host, "github.com")
        XCTAssertEqual(download.path, "/Yhaijiao/saykey-releases/releases/download/lab-phone-asr/CapsWriterLab-sideload.ipa")
    }
}
