// SPDX-License-Identifier: MIT

// Usage:
//   ListAndExtract <archive.rar>          lists the files
//   ListAndExtract <archive.rar> <name>   writes one file to stdout

import Foundation
import SwiftRAR

let arguments = CommandLine.arguments
guard arguments.count == 2 || arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: ListAndExtract <archive.rar> [name]\n".utf8))
    exit(2)
}

do {
    let reader = try RARReader(url: URL(fileURLWithPath: arguments[1]), limits: .default)
    if arguments.count == 2 {
        print("\(reader.format), \(reader.isSolid ? "solid" : "not solid"), \(reader.entries.count) files")
        for entry in reader.entries {
            print("\(entry.size)\t\(entry.isCompressed ? "compressed" : "stored")\t\(entry.name)")
        }
    } else {
        guard let entry = reader.entries.first(where: { $0.name == arguments[2] }) else {
            FileHandle.standardError.write(Data("no file named \(arguments[2])\n".utf8))
            exit(1)
        }
        // data(for:) returns only after the CRC32 matched, so nothing
        // unverified reaches stdout.
        FileHandle.standardOutput.write(try reader.data(for: entry))
    }
} catch let error as RARError {
    // Corrupt data, an unsupported feature or a limit: see RARError's cases.
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
