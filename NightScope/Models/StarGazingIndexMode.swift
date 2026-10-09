import Foundation

extension StarGazingIndex {
    /// 観測モードに合わせて既存の星空指数を再重み付けする。
    /// - Parameter referenceDate: 「今日」の判定に使う基準時刻。ベース指数の `compute` と同じ値を渡す。
    func adjusted(
        for mode: ObservationMode,
        nightSummary: NightSummary,
        weather: DayWeatherSummary?,
        referenceDate: Date = Date()
    ) -> StarGazingIndex {
        guard mode != .general else { return self }

        // ベース指数と同じ usableWeatherContext（同じ referenceDate）で評価対象の天気を絞る。
        // context が取得できない場合はベース指数も天気を評価していないため、天気由来のキャップは掛けない。
        let darkWeather: DayWeatherSummary? = weather.flatMap {
            nightSummary.usableWeatherContext(
                nighttimeHours: $0.nighttimeHours,
                referenceDate: referenceDate
            )?.weather
        }

        var adjustedScore = Self.modeWeightedScore(for: mode, index: self) + Self.modeBonus(for: mode, nightSummary: nightSummary)
        adjustedScore = min(adjustedScore, Self.confidenceCap(for: self))
        if let baseScoreCap = Self.baseScoreCap(for: mode, index: self) {
            adjustedScore = min(adjustedScore, baseScoreCap)
        }
        if let weatherCap = Self.weatherSafetyCap(for: darkWeather) {
            adjustedScore = min(adjustedScore, weatherCap)
        }
        if let modeCap = Self.modeCap(for: mode, nightSummary: nightSummary, weather: darkWeather) {
            adjustedScore = min(adjustedScore, modeCap)
        }

        return replacingScore(max(0, min(100, adjustedScore)))
    }

    private static func modeWeightedScore(for mode: ObservationMode, index: StarGazingIndex) -> Int {
        let weights = mode.weights
        var components: [(value: Double, weight: Double)] = [
            (Double(index.constellationScore) / Double(Self.maxConstellationScore), weights.constellation),
            (Double(index.milkyWayScore) / Double(Self.maxMilkyWayScore), weights.milkyWay)
        ]
        if index.hasWeatherData {
            components.append((Double(index.weatherScore) / Double(Self.maxWeatherScore), weights.weather))
        }
        if index.hasLightPollutionData {
            components.append((Double(index.lightPollutionScore) / Double(Self.maxLightPollutionScore), weights.lightPollution))
        }

        let totalWeight = components.reduce(0) { $0 + $1.weight }
        guard totalWeight > 0 else { return 0 }
        let normalized = components.reduce(0) { $0 + ($1.value * $1.weight) } / totalWeight
        return Int((normalized * 100).rounded())
    }

    private static func baseScoreCap(for mode: ObservationMode, index: StarGazingIndex) -> Int? {
        switch mode {
        case .moon, .planetary:
            return nil
        default:
            return index.score
        }
    }

    private static func confidenceCap(for index: StarGazingIndex) -> Int {
        switch (index.hasWeatherData, index.hasLightPollutionData) {
        case (false, false): return 54
        case (false, true): return 74
        default: return 100
        }
    }

    private static func weatherSafetyCap(for weather: DayWeatherSummary?) -> Int? {
        guard let weather else { return nil }
        let code = weather.representativeWeatherCode
        if weather.maxPrecipitation >= 0.5 || weather.avgCloudCover >= 75 || code == 45 || code == 48 || (51...99).contains(code) {
            return 34
        }
        if weather.maxPrecipitation > 0.1 || weather.avgCloudCover >= 55 {
            return 49
        }
        return nil
    }

    private static func modeBonus(for mode: ObservationMode, nightSummary: NightSummary) -> Int {
        guard mode == .moon else { return 0 }
        return Int((moonIllumination(for: nightSummary.moonPhaseAtMidnight) * 15).rounded())
    }

    private static func modeCap(for mode: ObservationMode, nightSummary: NightSummary, weather: DayWeatherSummary?) -> Int? {
        let illumination = moonIllumination(for: nightSummary.moonPhaseAtMidnight)
        let moonFraction = nightSummary.moonAboveHorizonFractionDuringDark

        switch mode {
        case .milkyWay where illumination >= 0.15 && moonFraction >= 0.35:
            return 49
        case .planetary where (weather?.avgCloudCover ?? 0) >= 45 || (weather?.avgWindSpeed ?? 0) >= 20 || (weather?.maxWindGusts ?? 0) >= 35:
            return 64
        case .photography where (weather?.avgCloudCover ?? 0) >= 45 || (weather?.avgWindSpeed ?? 0) >= 20 || (weather?.maxWindGusts ?? 0) >= 35:
            return 64
        default:
            return nil
        }
    }

    private static func moonIllumination(for phase: Double) -> Double {
        (1.0 - cos(phase * 2.0 * .pi)) / 2.0
    }
}
