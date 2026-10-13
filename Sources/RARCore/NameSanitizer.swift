// SPDX-License-Identifier: MIT

/// Turns an archive name into a safe relative path with `/` as separator.
///
/// Original code; unrar's path logic is deliberately not used.
/// - `\` becomes `/`
/// - empty components, `.` and `..` are removed (so is a leading `/`)
/// - a leading Windows drive letter (`C:`) is removed
/// - control characters (U+0000...U+001F, U+007F) are rejected
/// - the result must be non-empty and at most `maxLength` UTF-8 bytes
public enum NameSanitizer {
    public static func sanitize(_ rawName: String, maxLength: Int) throws -> String {
        guard rawName.utf8.count <= maxLength else {
            throw RARError.limitExceeded(.nameLength)
        }
        if rawName.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            throw RARError.invalidEntryName(rawName)
        }

        var components = rawName
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        if let first = components.first, isDriveLetter(first) {
            components.removeFirst()
        }
        components.removeAll { $0 == "." || $0 == ".." }

        let result = components.joined(separator: "/")
        guard !result.isEmpty else { throw RARError.invalidEntryName(rawName) }
        return result
    }

    private static func isDriveLetter(_ component: String) -> Bool {
        let scalars = Array(component.unicodeScalars)
        guard scalars.count == 2, scalars[1] == ":" else { return false }
        let letter = scalars[0].value
        return (0x41...0x5A).contains(letter) || (0x61...0x7A).contains(letter)
    }
}
