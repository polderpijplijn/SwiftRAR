// SPDX-License-Identifier: MIT

import Foundation

/// MS-DOS date/time as used by RAR4 headers and ZIP: local time, 2-second
/// resolution, years 1980...2107. Packed as `date << 16 | time`.
public enum DOSTime {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    /// Converts a packed DOS value to a `Date`; `nil` for impossible values.
    public static func date(fromPacked packed: UInt32) -> Date? {
        let time = packed & 0xFFFF
        let date = packed >> 16
        var components = DateComponents()
        components.year = Int((date >> 9) & 0x7F) + 1980
        components.month = Int((date >> 5) & 0x0F)
        components.day = Int(date & 0x1F)
        components.hour = Int((time >> 11) & 0x1F)
        components.minute = Int((time >> 5) & 0x3F)
        components.second = Int(time & 0x1F) * 2
        guard let month = components.month, (1...12).contains(month),
              let day = components.day, (1...31).contains(day),
              let hour = components.hour, hour < 24,
              let minute = components.minute, minute < 60,
              let second = components.second, second < 60
        else { return nil }
        return calendar.date(from: components)
    }

    /// Converts a `Date` to a packed DOS value, clamped to 1980...2107.
    public static func packed(from date: Date) -> UInt32 {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = c.year ?? 1980
        if year < 1980 { return packedValue(year: 1980, month: 1, day: 1, hour: 0, minute: 0, second: 0) }
        if year > 2107 { return packedValue(year: 2107, month: 12, day: 31, hour: 23, minute: 59, second: 58) }
        return packedValue(
            year: year, month: c.month ?? 1, day: c.day ?? 1,
            hour: c.hour ?? 0, minute: c.minute ?? 0, second: c.second ?? 0
        )
    }

    private static func packedValue(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) -> UInt32 {
        let date = UInt32((year - 1980) << 9 | month << 5 | day)
        let time = UInt32(hour << 11 | minute << 5 | second / 2)
        return date << 16 | time
    }
}
