import Foundation

// MARK: - Time Formatting

/// 設定済みの Formatter をキーごとに使い回す。
/// Formatter の生成と `setLocalizedDateFormatFromTemplate` は 1 回あたり 0.1 ms 前後かかり、
/// 一覧の行や View の body から何度も呼ばれるためキャッシュする。
/// 設定後に変更しない Foundation の Formatter は複数スレッドから同時に整形してよいため、辞書だけをロックで守る。
final class FormatterCache<CachedFormatter: AnyObject>: @unchecked Sendable {
    /// 観測地を何度も切り替えてもキーが増え続けないよう、上限に達したら全消去する。
    private static var capacity: Int { 128 }

    private let lock = NSLock()
    private var storage: [String: CachedFormatter] = [:]
    private var observers: [NSObjectProtocol] = []

    /// ロケール・タイムゾーン設定の変更時は、既定値を取り込んで作った Formatter を作り直す。
    init() {
        let center = NotificationCenter.default
        observers = [NSLocale.currentLocaleDidChangeNotification, .NSSystemTimeZoneDidChange].map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.removeAll()
            }
        }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func formatter(for key: String, make: () -> CachedFormatter) -> CachedFormatter {
        lock.lock()
        defer { lock.unlock() }
        if let cached = storage[key] {
            return cached
        }
        if storage.count >= Self.capacity {
            storage.removeAll(keepingCapacity: true)
        }
        let formatter = make()
        storage[key] = formatter
        return formatter
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
    }
}

enum FormatterFactory {
    private static let dateFormatters = FormatterCache<DateFormatter>()

    static func observationTimeZone(dateFormat: String, timeZone: TimeZone) -> DateFormatter {
        dateFormatters.formatter(for: "fixed|\(dateFormat)|\(timeZone.identifier)") {
            let formatter = DateFormatter()
            // 固定書式はユーザーの 12/24 時間設定や数字体系に左右されないようにする。
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = dateFormat
            formatter.timeZone = timeZone
            return formatter
        }
    }

    static func observationTimeZone(
        dateStyle: DateFormatter.Style,
        timeStyle: DateFormatter.Style,
        timeZone: TimeZone
    ) -> DateFormatter {
        // DateFormatter は生成時の Locale.current を使うため、ロケール変更通知でキャッシュを破棄する。
        let key = "style|\(dateStyle.rawValue)|\(timeStyle.rawValue)|\(timeZone.identifier)|\(Locale.current.identifier)"
        return dateFormatters.formatter(for: key) {
            let formatter = DateFormatter()
            formatter.dateStyle = dateStyle
            formatter.timeStyle = timeStyle
            formatter.timeZone = timeZone
            return formatter
        }
    }

    static func localizedDate(
        template: String,
        timeZone: TimeZone = .current,
        locale: Locale = .autoupdatingCurrent
    ) -> DateFormatter {
        dateFormatters.formatter(for: "template|\(template)|\(timeZone.identifier)|\(locale.identifier)") {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.setLocalizedDateFormatFromTemplate(template)
            formatter.timeZone = timeZone
            return formatter
        }
    }

    /// 曜日記号などロケールだけで決まる値を読むための Formatter。
    static func localeSymbols(locale: Locale = .autoupdatingCurrent) -> DateFormatter {
        dateFormatters.formatter(for: "symbols|\(locale.identifier)") {
            let formatter = DateFormatter()
            formatter.locale = locale
            return formatter
        }
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

