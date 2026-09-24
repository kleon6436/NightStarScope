import Foundation

/// 夜間サマリーに対応する天気を引き当てて星空指数を計算する。
/// AppController（当夜・予報）と ComparisonController（地点比較）で同じ規則を使うために共有する。
@MainActor
struct StarGazingIndexBuilder {
    let weatherService: any WeatherProviding

    /// 天気は夜間サマリー自身のタイムゾーンで引く。
    /// `night.date` はそのタイムゾーンでの日付の開始時刻なので、別のタイムゾーンで日付キーを作ると前後の日にずれることがある。
    func weather(
        for night: NightSummary,
        from weatherByDate: [String: DayWeatherSummary]
    ) -> DayWeatherSummary? {
        weatherService.summary(for: night.date, from: weatherByDate, timeZone: night.timeZone)
    }

    /// `referenceDate` は「今日」の判定に使う。今日の夜だけは暗時間の一部しか天気がなくても評価に含める。
    func index(
        for night: NightSummary,
        weather: DayWeatherSummary?,
        bortleClass: Double?,
        referenceDate: Date
    ) -> StarGazingIndex {
        StarGazingIndex.compute(
            nightSummary: night,
            weather: weather,
            bortleClass: bortleClass,
            referenceDate: referenceDate
        )
    }

    func index(
        for night: NightSummary,
        weatherByDate: [String: DayWeatherSummary],
        bortleClass: Double?,
        referenceDate: Date
    ) -> StarGazingIndex {
        index(
            for: night,
            weather: weather(for: night, from: weatherByDate),
            bortleClass: bortleClass,
            referenceDate: referenceDate
        )
    }
}
