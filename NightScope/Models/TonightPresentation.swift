import Foundation

// MARK: - Night Verdict

/// 「今夜は星を見に行くべきか」を見出し・理由・段階チップの 3 点で伝える表示モデル。
/// - Note: 純粋な値型。入力が同じなら常に同じ文字列を返す（I/O も現在時刻依存もなし）。
struct NightVerdictPresentation {
    /// 段階に応じた見出し。指数が未計算の場合は「計算中」。
    let headline: String
    /// 見出しを補足する一文。最大 2 節を「。」で連結する。
    let reason: String
    /// 星空指数の段階ラベル。指数が未計算の場合は空文字。
    let tierChipText: String

    init(
        index: StarGazingIndex?,
        summary: NightSummary,
        weather: DayWeatherSummary?,
        hasReliableWeather: Bool
    ) {
        let tier = index?.tier
        self.headline = Self.makeHeadline(tier: tier)
        self.tierChipText = index?.label ?? ""
        self.reason = Self.makeReason(
            tier: tier,
            summary: summary,
            weather: weather,
            hasReliableWeather: hasReliableWeather
        )
    }

    // MARK: - Headline

    private static func makeHeadline(tier: StarGazingIndex.Tier?) -> String {
        guard let tier else { return L10n.tr("計算中") }
        switch tier {
        case .excellent: return L10n.tr("絶好の星空日和")
        case .good:      return L10n.tr("今夜は星見向き")
        case .fair:      return L10n.tr("条件はまずまず")
        case .poor:      return L10n.tr("今夜はやや不向き")
        case .bad:       return L10n.tr("今夜は星見に不向き")
        }
    }

    // MARK: - Reason

    /// 優先度順（天気 → 月 → 結露）に節を集め、先頭 2 節だけを採用する。
    /// 根拠: 3 節以上は読み飛ばされるため、判断に効く情報だけを残す。
    private static func makeReason(
        tier: StarGazingIndex.Tier?,
        summary: NightSummary,
        weather: DayWeatherSummary?,
        hasReliableWeather: Bool
    ) -> String {
        var clauses: [String] = []

        if hasReliableWeather, let weather {
            clauses.append(weatherClause(weather))
        } else {
            clauses.append(L10n.tr("天気データなし"))
        }

        if let moonClause = moonClause(summary: summary, tier: tier) {
            clauses.append(moonClause)
        }

        // 結露リスクは天気データ由来のため、信頼できる予報がある場合のみ言及する。
        if hasReliableWeather, weather?.dewRiskLevel == .high {
            clauses.append(L10n.tr("結露リスク高"))
        }

        return clauses.prefix(2).joined(separator: L10n.tr("reason.separator"))
    }

    private static func weatherClause(_ weather: DayWeatherSummary) -> String {
        let cloud = L10n.percent(weather.avgCloudCover)
        if weather.maxPrecipitation > 0 {
            return L10n.format("%@で雲量%@", weather.weatherLabel, cloud)
        }
        return L10n.format("%@・雲量%@", weather.weatherLabel, cloud)
    }

    /// 月に触れる価値があるのは「明るすぎる」か「条件が良い夜に月がほぼない」ときだけ。
    private static func moonClause(summary: NightSummary, tier: StarGazingIndex.Tier?) -> String? {
        let illumination = summary.moonIllumination
        if illumination >= Constants.brightMoonIllumination {
            return L10n.tr("明るい月明かりあり")
        }
        let isFavorableTier = tier == .excellent || tier == .good
        if illumination < Constants.darkMoonIllumination, isFavorableTier {
            return L10n.tr("月明かりはほぼなし")
        }
        return nil
    }

    private enum Constants {
        /// 根拠: illumination 0.6 以上は上弦〜満月域で、淡い天体の観測に明確な影響が出る。
        static let brightMoonIllumination = 0.6
        /// 根拠: illumination 0.15 未満は新月前後で、月明かりの影響が実用上無視できる。
        static let darkMoonIllumination = 0.15
    }
}

// MARK: - Night Timeline

/// 18:00〜翌 06:00 を 0.0〜1.0 の比率に写像する、夜間タイムライン描画用モデル。
/// - Note: 比率はすべて軸の左端を 0.0、右端を 1.0 とする。
struct NightTimelineModel {
    /// 軸の左端（既定: summary.date の 18:00）。
    let axisStart: Date
    /// 軸の右端（既定: 翌日の 06:00）。
    let axisEnd: Date

    private let summary: NightSummary
    private let nighttimeHours: [HourlyWeather]
    private let timeZone: TimeZone

    init(
        summary: NightSummary,
        nighttimeHours: [HourlyWeather],
        axisStartHour: Int = 18,
        axisEndHour: Int = 6
    ) {
        self.summary = summary
        self.nighttimeHours = nighttimeHours
        let timeZone = summary.timeZone
        self.timeZone = timeZone

        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: timeZone)
        let dayStart = calendar.startOfDay(for: summary.date)
        let start = calendar.date(byAdding: .hour, value: axisStartHour, to: dayStart) ?? dayStart
        // 終端の時刻が開始以下なら翌日に回り込む（既定の 18:00 → 翌 06:00）。
        let endDayOffset = axisEndHour <= axisStartHour ? 1 : 0
        let endDayStart = calendar.date(byAdding: .day, value: endDayOffset, to: dayStart) ?? dayStart
        self.axisStart = start
        self.axisEnd = calendar.date(byAdding: .hour, value: axisEndHour, to: endDayStart) ?? start
    }

    var totalSeconds: TimeInterval { axisEnd.timeIntervalSince(axisStart) }

    /// 日時を軸上の比率へ変換する。軸の外側は 0.0 / 1.0 に丸める。
    func fraction(of date: Date) -> Double {
        guard totalSeconds > 0 else { return 0 }
        return min(max(date.timeIntervalSince(axisStart) / totalSeconds, 0), 1)
    }

    /// 天文薄明が終わっている区間。夕方側・早朝側のどちらかが欠けている場合は nil。
    var darkSegment: (startFraction: Double, endFraction: Double)? {
        guard let start = summary.eveningDarkStart,
              let end = summary.morningDarkEnd else { return nil }
        let startFraction = fraction(of: start)
        let endFraction = fraction(of: end)
        guard startFraction < endFraction else { return nil }
        return (startFraction, endFraction)
    }

    /// 暗夜区間の外側（薄明帯）。暗夜が取れない夜は軸全体を薄明として返す。
    var twilightSegments: [(start: Double, end: Double)] {
        guard let dark = darkSegment else { return [(0, 1)] }
        var segments: [(start: Double, end: Double)] = []
        if dark.startFraction > 0 { segments.append((0, dark.startFraction)) }
        if dark.endFraction < 1 { segments.append((dark.endFraction, 1)) }
        return segments
    }

    /// 銀河中心の最適観測ウィンドウ。
    var milkyWaySegment: (start: Double, end: Double, peak: Double)? {
        guard let window = summary.bestViewingWindow else { return nil }
        return (
            fraction(of: window.start),
            fraction(of: window.end),
            fraction(of: window.peakTime)
        )
    }

    /// 軸内に収まる時間別天気サンプル（時刻順）。
    var cloudSamples: [(fraction: Double, cloudCoverPercent: Double, precipitationMM: Double)] {
        nighttimeHours
            .filter { $0.date >= axisStart && $0.date <= axisEnd }
            .sorted { $0.date < $1.date }
            .map { (fraction(of: $0.date), $0.cloudCoverPercent, $0.precipitationMM) }
    }

    /// 3 時間刻みの目盛り（既定では 18:00 / 21:00 / 00:00 / 03:00 / 06:00 の 5 点）。
    var tickLabels: [(fraction: Double, text: String)] {
        guard totalSeconds > 0 else { return [] }
        return stride(from: 0, through: totalSeconds, by: Constants.tickIntervalSeconds).map { offset in
            let date = axisStart.addingTimeInterval(offset)
            return (fraction(of: date), date.nightTimeString(timeZone: timeZone))
        }
    }

    /// 暗夜の時間帯表記。暗い時間が無い夜は nil。
    var darkRangeText: String? { summary.darkRangeText.nilIfEmpty }

    /// 天の川ウィンドウの時間帯表記（例: "22:00〜02:00"）。ウィンドウが無い夜は nil。
    var milkyWayRangeText: String? {
        guard let window = summary.bestViewingWindow else { return nil }
        let start = window.start.nightTimeString(timeZone: timeZone)
        let end = window.end.nightTimeString(timeZone: timeZone)
        return "\(start)〜\(end)"
    }

    /// 暗夜の長さ（例: "9.0h"）。
    var darkHoursText: String {
        "\(L10n.number(summary.totalDarkHours, fractionDigits: 1))h"
    }

    private enum Constants {
        static let tickIntervalSeconds: TimeInterval = 3 * 3600
    }
}

// MARK: - Best Night

/// 数夜の候補から「一番の狙い目」を 1 つ選んだ結果。
struct BestNightPick {
    let summary: NightSummary
    let index: StarGazingIndex
    /// 天気を考慮した観測可能時間帯（例: "21:00〜03:30"）。算出できない場合は nil。
    let windowText: String?
    /// 選定理由の短文（例: "雲量18%・暗夜9.0h"）。
    let reasonText: String
    /// UI で強調表示する価値があるか。条件が並の夜を過度に推さないための判定。
    let isWorthHighlighting: Bool
}

/// 予報中の各夜を比較して、最も条件の良い夜を選ぶ純粋ロジック。
struct BestNightPicker {
    typealias Candidate = (
        summary: NightSummary,
        index: StarGazingIndex,
        weather: DayWeatherSummary?,
        isReliableWeather: Bool
    )

    /// 星空指数が最も高い夜を選ぶ。同点なら観測可能時間が長い夜、それも同じなら早い日付。
    /// - Parameter referenceDate: 部分的な予報カバレッジ判定に使う基準時刻（テスト用に差し替え可能）。
    static func pick(
        nights: [(summary: NightSummary, index: StarGazingIndex?, weather: DayWeatherSummary?, isReliableWeather: Bool)],
        referenceDate: Date = Date()
    ) -> BestNightPick? {
        let candidates: [Candidate] = nights.compactMap { night in
            guard let index = night.index else { return nil }
            return (night.summary, index, night.weather, night.isReliableWeather)
        }
        guard !candidates.isEmpty else { return nil }

        // sorted(by:) は安定ソートではないため、最後に元の並び順で決着させる。
        let ranked = candidates.enumerated().sorted { lhs, rhs in
            if lhs.element.index.score != rhs.element.index.score {
                return lhs.element.index.score > rhs.element.index.score
            }
            let lhsDuration = observableWindowDuration(lhs.element, referenceDate: referenceDate)
            let rhsDuration = observableWindowDuration(rhs.element, referenceDate: referenceDate)
            if lhsDuration != rhsDuration { return lhsDuration > rhsDuration }
            if lhs.element.summary.date != rhs.element.summary.date {
                return lhs.element.summary.date < rhs.element.summary.date
            }
            return lhs.offset < rhs.offset
        }

        guard let winner = ranked.first?.element else { return nil }
        let otherScores = ranked.dropFirst().map(\.element.index.score)

        return BestNightPick(
            summary: winner.summary,
            index: winner.index,
            windowText: windowText(winner, referenceDate: referenceDate),
            reasonText: reasonText(winner),
            isWorthHighlighting: isWorthHighlighting(winner: winner, otherScores: otherScores)
        )
    }

    // MARK: - Helpers

    private static func observableWindowDuration(_ candidate: Candidate, referenceDate: Date) -> TimeInterval {
        guard let window = observableWindow(candidate, referenceDate: referenceDate) else { return 0 }
        return window.end.timeIntervalSince(window.start)
    }

    private static func observableWindow(
        _ candidate: Candidate,
        referenceDate: Date
    ) -> (start: Date, end: Date)? {
        guard let weather = candidate.weather else { return nil }
        return candidate.summary.weatherAwareObservableWindow(
            nighttimeHours: weather.nighttimeHours,
            referenceDate: referenceDate
        )
    }

    /// 天気込みの観測可能時間帯を "HH:mm〜HH:mm" で返す。
    /// - Note: `weatherAwareRangeText` は「観測不可」「月明かり」といった非時刻の値も返すため、
    ///         時刻レンジだけが欲しいここではウィンドウから直接組み立てる。
    private static func windowText(_ candidate: Candidate, referenceDate: Date) -> String? {
        guard let window = observableWindow(candidate, referenceDate: referenceDate) else { return nil }
        let timeZone = candidate.summary.timeZone
        return "\(window.start.nightTimeString(timeZone: timeZone))〜\(window.end.nightTimeString(timeZone: timeZone))"
    }

    private static func reasonText(_ candidate: Candidate) -> String {
        let darkHours = L10n.number(candidate.summary.totalDarkHours, fractionDigits: 1)
        if candidate.isReliableWeather, let weather = candidate.weather {
            return L10n.format("雲量%@・暗夜%@h", L10n.percent(weather.avgCloudCover), darkHours)
        }
        return L10n.format("暗夜%@h", darkHours)
    }

    private static func isWorthHighlighting(winner: Candidate, otherScores: [Int]) -> Bool {
        switch winner.index.tier {
        case .excellent, .good, .fair:
            return true
        case .poor, .bad:
            // 条件自体は良くなくても、他の夜より明確に抜けているなら推す価値がある。
            return otherScores.allSatisfy { winner.index.score - $0 >= Constants.dominantScoreMargin }
        }
    }

    private enum Constants {
        /// 他の夜に対してこの点差以上あれば「相対的に狙い目」とみなす。
        static let dominantScoreMargin = 10
    }
}
