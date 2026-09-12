import Foundation

enum DisplayFormatters {
    static func size(_ size: Int64?) -> String {
        guard let size else { return "--" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.includesCount = true
        return formatter.string(fromByteCount: size)
    }

    /// Formats a modification date. Files touched today / yesterday / the day
    /// before are shown with a relative day label ("今天"/"昨天"/"前天") plus the
    /// time, matching how Finder surfaces recent edits; older dates fall back to
    /// a short numeric date and time.
    ///
    /// `now` and `calendar` are injectable so the relative logic is deterministic
    /// in tests.
    static func date(_ date: Date?, relativeTo now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date else { return "--" }

        let startOfDate = calendar.startOfDay(for: date)
        let startOfNow = calendar.startOfDay(for: now)
        let dayDelta = calendar.dateComponents([.day], from: startOfDate, to: startOfNow).day ?? 0

        switch dayDelta {
        case 0:
            return "今天 \(timeFormatter.string(from: date))"
        case 1:
            return "昨天 \(timeFormatter.string(from: date))"
        case 2:
            return "前天 \(timeFormatter.string(from: date))"
        default:
            return dateTimeFormatter.string(from: date)
        }
    }

    /// Byte count without the parenthesized raw count — for capacity readouts
    /// (Settings storage section) where `size(_:)`'s "x bytes" suffix is noise.
    static func compactSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    /// "yyyy-MM-dd" day key → "M/d" axis label (usage trend chart). Returns the
    /// key unchanged when it does not have the expected shape.
    static func shortDay(_ dayKey: String) -> String {
        let parts = dayKey.split(separator: "-")
        guard parts.count == 3, let month = Int(parts[1]), let day = Int(parts[2]) else { return dayKey }
        return "\(month)/\(day)"
    }
}
