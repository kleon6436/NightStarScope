import SwiftUI
import Combine
import CoreLocation

/// 予報一覧の 1 夜分の表示値。判定や文言の組み立ては入力が変わったときだけ行う。
struct UpcomingNightRow: Identifiable {
    let night: NightSummary
    let index: StarGazingIndex?
    let weather: DayWeatherSummary?
    let isReliableWeather: Bool
    let hasPartialWeather: Bool
    let isForecastOutOfRange: Bool
    let hasWeatherLoadError: Bool
    let isSelected: Bool
    /// 選択中のタイムゾーンで組み立てた表示文言。
    let presentation: ForecastCardPresentation
    let accessibilityLabel: String
    let milkyWayPeakText: String
    let currentObservationDate: Date

    /// 一覧の夜は日付ごとに 1 件のため、夜の日付で識別する。
    var id: Date { night.date }
}

/// 予報一覧全体の表示値。行と「狙い目」の判定をまとめて 1 回で求める。
struct UpcomingNightsDisplay {
    let rows: [UpcomingNightRow]
    /// 「狙い目」の判定結果。強調に値するかの判定と最低夜数の判定は呼び出し側で行う。
    let bestNightPick: BestNightPick?
    /// 星空指数が出ている夜の数。
    let scoredNightCount: Int
    /// macOS の見出しに添える「狙い目」の文言。
    let bestNightHighlightText: String?
}

/// 未来数夜の表示と選択状態を管理する ViewModel。
@MainActor
@Observable
final class UpcomingNightsGridViewModel {
    // 詳細画面の状態は DetailViewModel（@Observable）へ転送し、読み出し時に Observation が追跡する。
    /// カレンダーグリッドに表示する夜間データ。
    var displayNights: [NightSummary] { detailViewModel.upcomingNights }
    var isLoading: Bool { detailViewModel.isUpcomingLoading }
    var selectedDate: Date { detailViewModel.selectedDate }
    var observationMode: ObservationMode { detailViewModel.observationMode }
    var upcomingIndexes: [Date: StarGazingIndex] { detailViewModel.upcomingIndexes }
    var weatherErrorMessage: String? { detailViewModel.weatherErrorMessage }
    var selectedTimeZone: TimeZone { detailViewModel.selectedTimeZone }
    /// 天気サービスは ObservableObject のため、publisher を購読して Observation 対象の値として持つ。
    private(set) var weatherByDate: [String: DayWeatherSummary]

    @ObservationIgnored private let detailViewModel: DetailViewModel
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    /// `display` の計算結果。計算中に読んだ Observation 対象の入力のいずれかが変わると破棄する。
    /// 現在時刻に依存する判定（今夜・部分予報）が日をまたいで古くならないよう、日付の区切りもキーに含める。
    @ObservationIgnored private var displayCache: (key: DisplayCacheKey, display: UpcomingNightsDisplay)?

    private struct DisplayCacheKey: Equatable {
        let currentObservationDate: Date
        let currentDayStart: Date
    }

    /// 詳細画面の状態をそのまま監視して、一覧へ反映する。
    init(detailViewModel: DetailViewModel) {
        self.detailViewModel = detailViewModel
        self.weatherByDate = detailViewModel.weatherService.weatherByDate
        setupBindings()
    }

    private func setupBindings() {
        detailViewModel.weatherService.weatherByDatePublisher
            .sink { [weak self] in self?.weatherByDate = $0 }
            .store(in: &cancellables)
    }

    // MARK: - Display Snapshot

    /// 一覧の表示値。描画のたびに判定し直さないよう、入力が変わるまで使い回す。
    var display: UpcomingNightsDisplay {
        let key = DisplayCacheKey(
            currentObservationDate: detailViewModel.currentObservationDate(),
            currentDayStart: ObservationTimeZone.startOfDay(
                for: detailViewModel.currentDate(),
                timeZone: selectedTimeZone
            )
        )
        if let displayCache, displayCache.key == key {
            // キャッシュを返すときも入力を読み、呼び出し側（View）の Observation 追跡に入力を登録する。
            _ = (displayNights, selectedDate, observationMode, upcomingIndexes)
            _ = (weatherByDate, weatherErrorMessage, selectedTimeZone)
            return displayCache.display
        }
        // 計算中に読んだ入力が変わった時点（willSet）で同期的にキャッシュを破棄する。
        // 入力はすべて MainActor 上で更新されるため、通知もメインスレッドで届く。
        let display = withObservationTracking {
            makeDisplay()
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                self?.displayCache = nil
            }
        }
        displayCache = (key, display)
        return display
    }

    /// 指定した夜の行を組み立てる（プレースホルダー行など `displayNights` 以外にも使う）。
    func rows(for nights: [NightSummary]) -> [UpcomingNightRow] {
        let hasWeatherLoadError = weatherErrorMessage != nil
        let currentObservationDate = currentObservationDate()
        return nights.map { night in
            let weather = weatherSummary(for: night.date)
            let index = starGazingIndex(for: night.date)
            return UpcomingNightRow(
                night: night,
                index: index,
                weather: weather,
                isReliableWeather: hasReliableWeatherData(for: night, weather: weather),
                hasPartialWeather: hasPartialWeatherData(for: night, weather: weather),
                isForecastOutOfRange: isForecastOutOfRange(for: night, weather: weather),
                hasWeatherLoadError: hasWeatherLoadError,
                isSelected: isDateSelected(night.date),
                presentation: forecastPresentation(for: night),
                accessibilityLabel: cardAccessibilityLabel(night: night, weather: weather, index: index),
                milkyWayPeakText: milkyWayPeakText(night: night),
                currentObservationDate: currentObservationDate
            )
        }
    }

    private func makeDisplay() -> UpcomingNightsDisplay {
        let rows = rows(for: displayNights)
        let candidates: [BestNightPicker.Input] = rows.map { row in
            (
                summary: row.night,
                index: row.index,
                weather: row.weather,
                isReliableWeather: row.isReliableWeather
            )
        }
        let scoredNightCount = candidates.filter { $0.index != nil }.count
        let pick = BestNightPicker.pick(nights: candidates, referenceDate: detailViewModel.currentDate())
        return UpcomingNightsDisplay(
            rows: rows,
            bestNightPick: pick,
            scoredNightCount: scoredNightCount,
            bestNightHighlightText: highlightText(pick: pick, scoredNightCount: scoredNightCount)
        )
    }

    // MARK: - Public Properties

    // MARK: - Public Methods

    func setSelectedDate(_ date: Date) {
        // DetailViewModel.selectedDate の didSet が appController.selectedDate 更新と
        // 当日詳細の再計算を担うため、ここでは選択日だけを更新する
        detailViewModel.selectedDate = date
    }

    /// 指定日の天気サマリーを、詳細画面と同じキー規則で引く。
    func weatherSummary(for date: Date) -> DayWeatherSummary? {
        let key = detailViewModel.weatherService.dateKey(date, timeZone: selectedTimeZone)
        return weatherByDate[key]
    }

    /// 天気データが夜間を通して使えるかを判定する。
    func hasReliableWeatherData(for night: NightSummary, weather: DayWeatherSummary?) -> Bool {
        guard let weather else { return false }
        return night.hasUsableWeatherData(
            nighttimeHours: weather.nighttimeHours,
            referenceDate: detailViewModel.currentDate()
        )
    }

    /// 途中までしか評価できない天気データかを判定する。
    func hasPartialWeatherData(for night: NightSummary, weather: DayWeatherSummary?) -> Bool {
        guard let weather else { return false }
        return !night.hasUsableWeatherData(
            nighttimeHours: weather.nighttimeHours,
            referenceDate: detailViewModel.currentDate()
        )
    }

    /// 予報対象外かどうかを判定する。
    func isForecastOutOfRange(for night: NightSummary, weather: DayWeatherSummary?) -> Bool {
        guard weather == nil else { return false }
        return detailViewModel.weatherService.isForecastOutOfRange(
            for: night.date,
            in: weatherByDate,
            timeZone: selectedTimeZone
        )
    }

    /// 選択日での星空指数を返す。
    func starGazingIndex(for date: Date) -> StarGazingIndex? {
        let startOfDay = ObservationTimeZone.startOfDay(for: date, timeZone: selectedTimeZone)
        guard let baseIndex = upcomingIndexes[startOfDay] else { return nil }
        guard let night = displayNights.first(where: {
            ObservationTimeZone.isDate($0.date, inSameDayAs: date, timeZone: selectedTimeZone)
        }) else {
            return baseIndex
        }
        // ベース指数と同じ現在時刻（AppController の時計）で部分予報を判定する。
        return baseIndex.adjusted(
            for: observationMode,
            nightSummary: night,
            weather: weatherSummary(for: date),
            referenceDate: detailViewModel.currentDate()
        )
    }

    /// 1 夜分の表示用プレゼンテーションを、判定ロジック込みで組み立てる。
    func forecastPresentation(for night: NightSummary) -> ForecastCardPresentation {
        let weather = weatherSummary(for: night.date)
        return ForecastCardPresentation(
            night: night,
            weather: weather,
            timeZone: selectedTimeZone,
            isReliableWeather: hasReliableWeatherData(for: night, weather: weather),
            hasPartialWeather: hasPartialWeatherData(for: night, weather: weather),
            isForecastOutOfRange: isForecastOutOfRange(for: night, weather: weather),
            hasWeatherLoadError: weatherErrorMessage != nil,
            currentObservationDate: detailViewModel.currentObservationDate()
        )
    }

    /// 天の川のピーク時刻と観測窓の長さ（例: "23:10・3.5h"）。ウィンドウが無い夜は "—"。
    func milkyWayPeakText(night: NightSummary) -> String {
        guard let window = night.bestViewingWindow else { return "—" }
        let peak = window.peakTime.nightTimeString(timeZone: night.timeZone)
        let hours = L10n.number(window.duration / 3600, fractionDigits: 1)
        return "\(peak)・\(hours)h"
    }

    /// 「狙い目」判定に渡す候補を `displayNights` から組み立てる。macOS / iOS で同じ入力を使う。
    func bestNightCandidates() -> [BestNightPicker.Input] {
        displayNights.map { night in
            let weather = weatherSummary(for: night.date)
            return (
                summary: night,
                index: starGazingIndex(for: night.date),
                weather: weather,
                isReliableWeather: hasReliableWeatherData(for: night, weather: weather)
            )
        }
    }

    /// 「狙い目」として 1 行で添える文言。強調に値しない、または比較対象が無い場合は nil。
    /// - Parameter referenceDate: 部分予報の判定に使う現在時刻。nil なら AppController の時計を使う。
    func bestNightHighlightText(referenceDate: Date? = nil) -> String? {
        let candidates = bestNightCandidates()
        return highlightText(
            pick: BestNightPicker.pick(
                nights: candidates,
                referenceDate: referenceDate ?? detailViewModel.currentDate()
            ),
            scoredNightCount: candidates.filter { $0.index != nil }.count
        )
    }

    private func highlightText(pick: BestNightPick?, scoredNightCount: Int) -> String? {
        // 指数が出ていない夜は比較対象にならないため、採点済みの夜数で判定する。
        guard scoredNightCount >= 2 else { return nil }
        guard let pick, pick.isWorthHighlighting else { return nil }
        let presentation = forecastPresentation(for: pick.summary)
        let window = pick.windowText ?? presentation.darkStartText ?? "—"
        return L10n.format("狙い目: %@ %@", presentation.shortDateLabel, window)
    }

    /// 指定日が現在の選択日かを返す。
    func isDateSelected(_ date: Date) -> Bool {
        ObservationTimeZone.isDate(date, inSameDayAs: selectedDate, timeZone: selectedTimeZone)
    }

    /// 現在の選択日が「今日」（現在の観測日）かを返す。深夜〜明け方は進行中の前夜を「今日」とみなす。
    /// - Parameter referenceDate: 現在時刻として扱う時刻。nil なら AppController の時計を使う。
    func isSelectedDateToday(referenceDate: Date? = nil) -> Bool {
        ObservationTimeZone.isDate(
            selectedDate,
            inSameDayAs: detailViewModel.currentObservationDate(referenceDate: referenceDate),
            timeZone: selectedTimeZone
        )
    }

    /// 現在の観測日（アプリ全体の「今日」）。予報カードの「今夜」「明夜」の判定に使う。
    func currentObservationDate() -> Date {
        detailViewModel.currentObservationDate()
    }

    /// 選択日を「今日」（現在の観測日）へ戻す。深夜〜明け方は進行中の前夜を選ぶ。
    func selectToday(referenceDate: Date? = nil) {
        setSelectedDate(detailViewModel.currentObservationDate(referenceDate: referenceDate))
    }

    /// 夜間範囲の表示用テキストを組み立てる。
    func observableRangeText(night: NightSummary, weather: DayWeatherSummary?) -> String {
        // 暗時間ゼロ（白夜等）は専用テキスト
        if night.totalDarkHours <= 0 {
            return L10n.tr("暗い時間なし")
        }
        if let weather,
           let text = night.weatherAwareRangeText(
               nighttimeHours: weather.nighttimeHours,
               referenceDate: detailViewModel.currentDate()
           ) {
            return text.isEmpty ? L10n.tr("天候不良") : text
        }
        return night.darkRangeText.isEmpty ? "—" : night.darkRangeText
    }

    /// カード全体の VoiceOver 用ラベルを作る。
    func cardAccessibilityLabel(night: NightSummary, weather: DayWeatherSummary?, index: StarGazingIndex?) -> String {
        var parts: [String] = []
        parts.append(DateFormatters.fullDateString(from: night.date, timeZone: selectedTimeZone))
        if night.totalDarkHours <= 0 {
            parts.append(L10n.tr("暗い時間なし"))
            parts.append(L10n.format("月: %@", night.moonPhaseName))
            return parts.joined(separator: "、")
        }
        if let idx = index { parts.append(L10n.format("星空指数%d", idx.score)) }
        if hasReliableWeatherData(for: night, weather: weather), let w = weather {
            parts.append(L10n.format("天気%@", w.weatherLabel))
            if let range = w.nightTemperatureRange {
                parts.append(TemperatureFormat.accessibilityRange(high: range.upperBound, low: range.lowerBound))
            }
        } else if hasPartialWeatherData(for: night, weather: weather) {
            parts.append(L10n.tr("天気予報一部のみ"))
        } else if isForecastOutOfRange(for: night, weather: weather) {
            parts.append(L10n.tr("天気予報対象外"))
        }
        parts.append(L10n.format("月: %@", night.moonPhaseName))
        return parts.joined(separator: "、")
    }

    /// 天気コードからアイコン色を決める。
    func weatherIconColor(code: Int) -> Color {
        WeatherPresentation.color(forWeatherCode: code)
    }

    /// 未来日が不足している場合のプレースホルダーを作る。
    func placeholderNight(at offset: Int) -> NightSummary {
        let baseDate = ObservationTimeZone.startOfDay(for: selectedDate, timeZone: selectedTimeZone)
        let date = ObservationTimeZone.date(byAdding: .day, value: offset, to: baseDate, timeZone: selectedTimeZone) ?? baseDate
        return NightSummary(
            date: date,
            location: CLLocationCoordinate2D(latitude: 35.6762, longitude: 139.6503),
            events: [],
            viewingWindows: [],
            moonPhaseAtMidnight: 0,
            timeZoneIdentifier: selectedTimeZone.identifier
        )
    }
}
