import Foundation
import Testing

@testable import XFinder

/// Fixed calendar + reference instant so the relative-date logic is
/// deterministic regardless of the machine's clock or time zone.
private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar
}()

private let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 4, hour: 15, minute: 30))!

private func day(_ d: Int, hour: Int = 9) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 6, day: d, hour: hour, minute: 0))!
}

private func format(_ date: Date?) -> String {
    DisplayFormatters.date(date, relativeTo: now, calendar: calendar)
}

// MARK: - Relative day labels (task 3)

@Test func sameDayShowsToday() {
    #expect(format(day(4)).hasPrefix("今天"))
}

@Test func previousDayShowsYesterday() {
    #expect(format(day(3)).hasPrefix("昨天"))
}

@Test func twoDaysAgoShowsDayBeforeYesterday() {
    #expect(format(day(2)).hasPrefix("前天"))
}

@Test func olderDatesAreNotRelative() {
    let formatted = format(day(1))
    for label in ["今天", "昨天", "前天"] {
        #expect(!formatted.contains(label), "edits older than two days must not use a relative label")
    }
}

@Test func futureDatesAreNotRelative() {
    // A clock skew / future mtime must not be mislabelled as 今天/昨天/前天.
    let formatted = format(day(6))
    for label in ["今天", "昨天", "前天"] {
        #expect(!formatted.contains(label), "future dates must not use a relative label")
    }
}

@Test func relativeLabelIncludesTime() {
    let formatted = format(day(4, hour: 13))
    #expect(formatted.hasPrefix("今天 "))
    #expect(formatted.count > "今天 ".count)
}

// MARK: - Nil handling

@Test func nilDateShowsPlaceholder() {
    #expect(format(nil) == "--")
}

// MARK: - Size

@Test func nilSizeShowsPlaceholder() {
    #expect(DisplayFormatters.size(nil) == "--")
}

@Test func zeroSizeIsFormatted() {
    #expect(!DisplayFormatters.size(0).isEmpty)
    #expect(DisplayFormatters.size(0) != "--")
}

// MARK: - Day-key axis labels

@Test func shortDayFormatsDayKey() {
    #expect(DisplayFormatters.shortDay("2026-09-12") == "9/12")
    #expect(DisplayFormatters.shortDay("2026-12-01") == "12/1")
}

@Test func shortDayKeepsMalformedKey() {
    #expect(DisplayFormatters.shortDay("unknown") == "unknown")
}
