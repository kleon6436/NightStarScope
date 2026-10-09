import SwiftUI
import Foundation

// MARK: - Weather Presentation

enum WeatherPresentation {
    static func primaryLabel(for weather: DayWeatherSummary) -> String {
        weather.weatherLabel
    }

    static func color(forWeatherCode code: Int) -> Color {
        switch code {
        case 0, 1:       return .yellow
        case 2:          return .secondary
        case 3:          return .secondary
        case 45, 48:     return .secondary
        case 51...65:    return .blue
        case 68:         return .cyan
        case 71...77:    return Color.blue.opacity(0.7)
        case 80...82:    return .blue
        case 85, 86:     return Color.blue.opacity(0.7)
        case 95...99:    return .orange
        default:         return .secondary
        }
    }
}

// MARK: - Temperature Format

/// 気温（℃）を端末ロケールの温度単位で短く整形する。
/// 単位記号は省き `18°` の形にする。℃/℉ の選択はロケール（ユーザーの温度単位設定を含む）に従う。
enum TemperatureFormat {
    /// 単位記号なしの短い表記（例: `18°`、en_US では `64°`）。
    static func short(_ celsius: Double, locale: Locale = .autoupdatingCurrent) -> String {
        let converted = localized(celsius, locale: locale)
        let formatter = MeasurementFormatter()
        formatter.locale = locale
        formatter.unitOptions = .temperatureWithoutUnit
        formatter.numberFormatter.maximumFractionDigits = 0
        return formatter.string(from: converted)
    }

    /// 夜間の「最高/最低」表記（例: `12°/6°`）。
    static func range(high: Double, low: Double, locale: Locale = .autoupdatingCurrent) -> String {
        "\(short(high, locale: locale))/\(short(low, locale: locale))"
    }

    /// VoiceOver 向けに単位名まで含めた表記（例: `18 degrees Celsius`）。
    static func spoken(_ celsius: Double, locale: Locale = .autoupdatingCurrent) -> String {
        let converted = localized(celsius, locale: locale)
        let formatter = MeasurementFormatter()
        formatter.locale = locale
        formatter.unitOptions = .providedUnit
        formatter.unitStyle = .long
        formatter.numberFormatter.maximumFractionDigits = 0
        return formatter.string(from: converted)
    }

    /// 夜間の最高・最低気温の読み上げ文。
    static func accessibilityRange(high: Double, low: Double, locale: Locale = .autoupdatingCurrent) -> String {
        L10n.format("夜間の気温 最高 %@、最低 %@", spoken(high, locale: locale), spoken(low, locale: locale))
    }

    /// ロケールの温度単位へ換算し、整数に丸める。
    /// MeasurementFormatter は `.temperatureWithoutUnit` で単位換算をしないため自前で換算する。
    /// 先に丸めることで `-0°` や偶数丸め（12.5 → 12）を避ける。
    private static func localized(_ celsius: Double, locale: Locale) -> Measurement<UnitTemperature> {
        let unit = UnitTemperature(forLocale: locale)
        let rounded = Measurement(value: celsius, unit: UnitTemperature.celsius)
            .converted(to: unit)
            .value
            .rounded()
        // -0.0 を 0 に揃える
        return Measurement(value: rounded == 0 ? 0 : rounded, unit: unit)
    }
}

// MARK: - Forecast Card Presentation

/// 予報カードに表示する短縮ラベルや補助文をまとめる。
struct ForecastCardPresentation {
    let night: NightSummary
    let weather: DayWeatherSummary?
    let timeZone: TimeZone
    let isReliableWeather: Bool
    let hasPartialWeather: Bool
    let isForecastOutOfRange: Bool
    let hasWeatherLoadError: Bool

    var shortDateLabel: String {
        FormatterFactory.localizedDate(template: "MEd", timeZone: timeZone).string(from: night.date)
    }

    var relativeNightLabel: String? {
        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: timeZone)
        if ObservationTimeZone.isDateInToday(night.date, timeZone: timeZone) { return L10n.tr("今夜") }
        if calendar.isDateInTomorrow(night.date) { return L10n.tr("明夜") }
        return nil
    }

    /// 天文薄明が終わる時刻 (HH:mm)。暗い時間が始まらない夜は nil。
    var darkStartText: String? {
        night.eveningDarkStart.map { $0.nightTimeString(timeZone: timeZone) }
    }

    var cloudCoverText: String {
        guard isReliableWeather, let weather else { return "—" }
        return L10n.percent(weather.avgCloudCover)
    }

    /// 夜間の最高/最低気温（例: `12°/6°`）。夜間を通した予報がない夜は nil。
    var temperatureRangeText: String? {
        guard isReliableWeather, let range = weather?.nightTemperatureRange else { return nil }
        return TemperatureFormat.range(high: range.upperBound, low: range.lowerBound)
    }

    var weatherDetailText: String? {
        if isReliableWeather, let weather {
            return WeatherPresentation.primaryLabel(for: weather)
        }
        if hasPartialWeather { return L10n.tr("夜間予報は一部のみ") }
        if isForecastOutOfRange { return L10n.tr("天気予報対象外") }
        if hasWeatherLoadError { return L10n.tr("取得失敗") }
        return nil
    }
}

