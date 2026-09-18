import Foundation

// MARK: - Time Formatting

enum FormatterFactory {
    static func observationTimeZone(dateFormat: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = dateFormat
        formatter.timeZone = timeZone
        return formatter
    }

    static func observationTimeZone(
        dateStyle: DateFormatter.Style,
        timeStyle: DateFormatter.Style,
        timeZone: TimeZone
    ) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        formatter.timeZone = timeZone
        return formatter
    }

    static func localizedDate(
        template: String,
        timeZone: TimeZone = .current,
        locale: Locale = .autoupdatingCurrent
    ) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        formatter.timeZone = timeZone
        return formatter
    }
}

enum DateFormatters {
    static func nightTimeString(from date: Date, timeZone: TimeZone = .current) -> String {
        FormatterFactory.observationTimeZone(dateFormat: "HH:mm", timeZone: timeZone).string(from: date)
    }

    static func monthTitleString(from date: Date, timeZone: TimeZone = .current) -> String {
        FormatterFactory.localizedDate(template: "yMMMM", timeZone: timeZone).string(from: date)
    }

    /// ロケールに応じた「月日」表記を返す (ja: 8月12日 / en: Aug 12)。
    static func monthDayString(from date: Date, timeZone: TimeZone = .current) -> String {
        FormatterFactory.localizedDate(template: "MMMd", timeZone: timeZone).string(from: date)
    }

    /// 年を持たない月日の組を、referenceDate の年に当てはめてロケール表記へ変換する。
    static func monthDayString(
        month: Int,
        day: Int,
        timeZone: TimeZone = .current,
        referenceDate: Date = Date()
    ) -> String {
        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: timeZone)
        var components = DateComponents()
        components.year = calendar.component(.year, from: referenceDate)
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else {
            return "\(month)/\(day)"
        }
        return monthDayString(from: date, timeZone: timeZone)
    }

    static func fullDateString(from date: Date, timeZone: TimeZone = .current) -> String {
        FormatterFactory.observationTimeZone(
            dateStyle: .full,
            timeStyle: .none,
            timeZone: timeZone
        )
        .string(from: date)
    }

    static func yearMonthDayWeekdayString(
        from date: Date,
        timeZone: TimeZone = .current,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        FormatterFactory.localizedDate(template: "yMMMMEEEEd", timeZone: timeZone, locale: locale).string(from: date)
    }
    
    static func yearMonthDayWeekdayStringWithoutWeekday(from date: Date, timeZone: TimeZone = .current) -> String {
        FormatterFactory.localizedDate(template: "yMMMMd", timeZone: timeZone).string(from: date)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension Date {
    /// HH:mm 形式の時刻文字列を返す
    func nightTimeString(timeZone: TimeZone = .current) -> String {
        DateFormatters.nightTimeString(from: self, timeZone: timeZone)
    }
}

