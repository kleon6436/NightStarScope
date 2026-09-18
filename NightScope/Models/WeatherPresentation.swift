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
        case 71...77:    return Color.blue.opacity(0.7)
        case 80...82:    return .blue
        case 85, 86:     return Color.blue.opacity(0.7)
        case 95...99:    return .orange
        default:         return .secondary
        }
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

    var cloudCoverText: String {
        guard isReliableWeather, let weather else { return "—" }
        return L10n.percent(weather.avgCloudCover)
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

