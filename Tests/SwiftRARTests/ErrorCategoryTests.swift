// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import CBZWriter
import RARCore
import SwiftRAR

/// `category` must agree with the error guide (Errors.md in the DocC catalog).
final class ErrorCategoryTests: XCTestCase {
    func testEveryRARErrorCase() {
        let expected: [(RARError, ErrorCategory)] = [
            (.unknownFormat, .corrupt),
            (.truncated, .corrupt),
            (.corruptHeader("x"), .corrupt),
            (.corruptData("x"), .corrupt),
            (.badHeaderCRC, .corrupt),
            (.badDataCRC(entry: "x"), .corrupt),
            (.invalidEntryName("x"), .corrupt),
            (.duplicateEntryName("x"), .corrupt),
            (.emptyArchive, .corrupt),
            (.unsupportedFormat("x"), .unsupported),
            (.encrypted, .unsupported),
            (.multiVolume, .unsupported),
            (.unsupportedCompression(method: 3), .unsupported),
            (.missingChecksum(entry: "x"), .unsupported),
            (.limitExceeded(.entrySize), .limit),
            (.io("x"), .io),
            (.cancelled, .cancelled),
        ]
        for (error, category) in expected {
            XCTAssertEqual(error.category, category, "\(error)")
        }
    }

    func testEveryCBZWriterErrorCase() {
        let expected: [(CBZWriterError, ErrorCategory)] = [
            (.zip64Required, .limit),
            (.tooManyEntries, .limit),
            (.invalidName("x"), .usage),
            (.duplicateName("x"), .usage),
            (.invalidState("x"), .usage),
            (.io("x"), .io),
        ]
        for (error, category) in expected {
            XCTAssertEqual(error.category, category, "\(error)")
        }
    }

    /// The categories of errors that real input produces through the public API.
    func testErrorsFromTheReaderHaveTheirCategory() throws {
        func openCategory(_ bytes: [UInt8], limits: Limits = .default) -> ErrorCategory? {
            do {
                _ = try RARReader(source: DataSource(bytes), limits: limits)
                return nil
            } catch {
                return (error as? RARError)?.category
            }
        }
        let page = TestFile(name: "p.jpg", contents: Array(repeating: 7, count: 100))
        var encrypted = page
        encrypted.encrypted = true
        var tight = Limits.default
        tight.maxEntrySize = 10
        let valid = RAR5Builder.build([page])

        XCTAssertEqual(openCategory(Array("not an archive".utf8)), .corrupt)
        XCTAssertEqual(openCategory(Array(valid.prefix(valid.count - 20))), .corrupt)
        XCTAssertEqual(openCategory(RAR5Builder.build([encrypted])), .unsupported)
        XCTAssertEqual(openCategory(valid, limits: tight), .limit)

        var badCRC = page
        badCRC.crcOverride = 0xDEAD_BEEF
        let reader = try RARReader(source: DataSource(RAR4Builder.build([badCRC])), limits: .default)
        XCTAssertThrowsError(try reader.data(for: reader.entries[0])) {
            XCTAssertEqual(($0 as? RARError)?.category, .corrupt)
        }
    }
}
