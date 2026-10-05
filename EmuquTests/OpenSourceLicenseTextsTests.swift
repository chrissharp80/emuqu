@testable import Emuqu
import XCTest

/// The license texts the open-source packages require to ship with the app,
/// and the third-party policy links the privacy policy shows.
@MainActor
final class OpenSourceLicenseTextsTests: XCTestCase {
    private func document(_ title: String) -> String {
        OpenSourceLicenseTexts.documents.first { $0.title == title }?.text ?? ""
    }

    /// Apache-2.0 §4(a) needs the license itself, not a link to it.
    func testApacheTextIsTheFullLicenseWithItsUsers() {
        let text = document("Apache License 2.0")
        XCTAssertTrue(text.contains("TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION"))
        XCTAssertTrue(text.contains("END OF TERMS AND CONDITIONS"))
        XCTAssertTrue(text.contains("Runtime Library Exception"))
        for package in ["swift-transformers", "swift-jinja", "swift-crypto", "swift-asn1",
                        "swift-protobuf", "swift-collections", "swift-argument-parser"] {
            XCTAssertTrue(text.contains(package), "\(package) is Apache-2.0 and must be listed.")
        }
    }

    /// MIT requires every copyright notice alongside the permission notice.
    func testMITTextCarriesEveryCopyrightLine() {
        let text = document("MIT License")
        XCTAssertTrue(text.contains("Permission is hereby granted, free of charge"))
        for holder in ["argmax, inc.", "OpenAI", "YaoYuan", "Roy Marmelstein"] {
            XCTAssertTrue(text.contains(holder), "MIT copyright line for \(holder) is missing.")
        }
    }

    /// Apache-2.0 §4(d): the NOTICE files of swift-crypto and swift-asn1.
    func testNoticeFilesAreShipped() {
        XCTAssertTrue(document("swift-crypto NOTICE").contains("The SwiftCrypto Project"))
        XCTAssertTrue(document("swift-asn1 NOTICE").contains("The SwiftASN1 Project"))
    }

    /// Guideline 5.1.1(i): every service that can receive data is named with a
    /// link to how it handles it.
    func testPrivacyPolicyLinksEveryService() {
        let names = Set(PrivacyPolicyView.servicePolicies.map(\.name))
        for name in ["Apple", "Anthropic", "OpenAI", "Google", "xAI", "DeepSeek", "Tavily", "MET Norway",
                     "Overpass (overpass-api.de)", "Overpass (overpass.private.coffee)", "OpenTopoData", "Hugging Face"] {
            XCTAssertTrue(names.contains(name), "\(name) has no policy link.")
        }
        XCTAssertTrue(PrivacyPolicyView.servicePolicies.allSatisfy { $0.url.scheme == "https" })
    }
}
