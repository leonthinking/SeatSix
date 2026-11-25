import Foundation
import XCTest
@testable import SeatSixProbe

final class PrivateReportWriterTests: XCTestCase {
    func testNewReportIsPrivateInsideReadableParent() throws {
        try withDirectory { directory in
            let target = directory.appendingPathComponent("report.json")
            try PrivateReportWriter.write(Data("private report".utf8), to: target)
            XCTAssertEqual(try permissions(target), 0o600)
            XCTAssertEqual(try String(contentsOf: target), "private report")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["report.json"])
        }
    }

    func testReplacementDoesNotInheritReadableOldPermissions() throws {
        try withDirectory { directory in
            let target = directory.appendingPathComponent("report.json")
            try Data("old report".utf8).write(to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
            try PrivateReportWriter.write(Data("new private report".utf8), to: target)
            XCTAssertEqual(try permissions(target), 0o600)
            XCTAssertEqual(try String(contentsOf: target), "new private report")
        }
    }

    func testFailedReplacementCleansPrivateTemporaryFile() throws {
        try withDirectory { directory in
            let target = directory.appendingPathComponent("existing-directory")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            XCTAssertThrowsError(try PrivateReportWriter.write(Data("private".utf8), to: target))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["existing-directory"])
        }
    }

    private func permissions(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue
    }
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}
