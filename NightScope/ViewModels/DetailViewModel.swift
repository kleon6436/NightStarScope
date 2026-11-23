import SwiftUI

/// 画面に表示する状態を「読み込み中 / 空 / 表示可」に畳み込む。
enum LoadableContentState: Equatable {
    case loading
    case empty
    case content
}

/// 詳細画面のカード表示可否をまとめて判定する。
struct DetailContentStateResolver {
    /// 直近予報の読み込み状況から、予報カードの表示状態を返す。
    func forecastState(hasDisplayNights: Bool, isUpcomingLoading: Bool) -> LoadableContentState {
        if isUpcomingLoading && !hasDisplayNights {
            return .loading
        }
        if !hasDisplayNights {
            return .empty
        }
        return .content
    }

    /// 当日の詳細表示に必要な夜間データの有無を判定する。
    func todayState(isCalculating: Bool, summary: NightSummary?) -> LoadableContentState {
        if isCalculating && summary == nil {
            return .loading
        }
        if summary == nil {
            return .empty
        }
        return .content
    }
}

@MainActor
/// 観測日の詳細情報と再計算状態を管理する ViewModel。
@Observable
final class DetailViewModel {
    /// 現在表示している当日詳細の元データ。
    private(set) var nightSummary: NightSummary?
    /// 調整後の星空指数。
    private(set) var starGazingIndex: StarGazingIndex?
    /// 選択中の観測モード。設定オブジェクト（@Observable）へ転送する。
    var observationMode: ObservationMode { observationModePreference.mode }
    /// 再計算中かどうか。
    private(set) var isCalculating = false
    /// 予報対象の未来数日分。
    private(set) var upcomingNights: [NightSummary] = []
    /// 日付ごとの星空指数キャッシュ。
    private(set) var upcomingIndexes: [Date: StarGazingIndex] = [:]
    var selectedDate: Date {
        didSet {
            // 同値の代入では何もしない（旧 $selectedDate 購読の removeDuplicates と同じ扱い）。
            guard selectedDate != oldValue else { return }
            requestObservationDate(selectedDate)
        }
    }
    /// 表示上の観測日。再計算中は一時的に前回表示を保持する。
    private(set) var displayedDate: Date
    // 地点・天気・光害サービス（@Observable）の状態は転送し、読み出し時に Observation が追跡する。
    var locationName: String { appController.locationController.locationName }
    var hasWeatherError: Bool { weatherErrorMessage != nil }
    var weatherErrorMessage: String? { appController.weatherService.errorMessage }
    var hasLightPollutionError: Bool { appController.lightPollutionService.fetchFailed }
    private(set) var currentWeather: DayWeatherSummary?
    var isWeatherLoading: Bool { appController.weatherService.isLoading }
    private(set) var isUpcomingLoading: Bool = false
    var selectedTimeZone: TimeZone { appController.locationController.selectedTimeZone }
    private(set) var isCurrentWeatherForecastOutOfRange = false
    private(set) var isCurrentWeatherCoverageIncomplete = false
    /// ヘッダーに添える観測地の現在気温（例: `18°`）。未取得・古い場合は nil。
    var currentTemperatureText: String? {
        appController.weatherService.currentTemperatureCelsius.map { TemperatureFormat.short($0) }
    }
    /// 現在気温の読み上げ文。`currentTemperatureText` と同じ値から作る。
    var currentTemperatureAccessibilityLabel: String? {
        appController.weatherService.currentTemperatureCelsius.map {
            L10n.format("現在の気温 %@", TemperatureFormat.spoken($0))
        }
    }

    @ObservationIgnored private let appController: AppController
    @ObservationIgnored private let observationModePreference: ObservationModePreference
    @ObservationIgnored private var timeZoneObservationTask: Task<Void, Never>?

    /// AppController の観測状態を詳細画面向けに同期する。
    init(
        appController: AppController,
        observationModePreference: ObservationModePreference = ObservationModePreference()
    ) {
        self.appController = appController
        self.observationModePreference = observationModePreference
        let initialState = appController.observationState
        self.nightSummary = initialState.nightSummary
        self.starGazingIndex = initialState.starGazingIndex
        self.isCalculating = initialState.isCalculating
        self.upcomingNights = initialState.upcomingNights
        self.upcomingIndexes = initialState.upcomingIndexes
        self.selectedDate = initialState.selectedDate
        self.displayedDate = initialState.selectedDate
        bind()
        updateDisplayedContentState()
    }

    deinit {
        timeZoneObservationTask?.cancel()
    }

    private func bind() {
        // 観測状態は書き換えの直後に同期的に受け取る。選択日の写しが遅れると、同じ実行中に続く日付選択が
        // 古い選択日との比較で捨てられたり、表示中の当夜を残すかの判断が前の状態と食い違ったりする。
        appController.observationStateDidChange = { [weak self] state in
            guard let self else { return }
            if !self.shouldPreserveDisplayedSummary(during: state) {
                self.nightSummary = state.nightSummary
                self.starGazingIndex = state.starGazingIndex
            }
            self.upcomingNights = state.upcomingNights
            self.upcomingIndexes = state.upcomingIndexes
            // Equatable な値は変化したときだけ書き込む（同値の代入は Observation も通知しない）。
            if self.isCalculating != state.isCalculating {
                self.isCalculating = state.isCalculating
            }
            if self.isUpcomingLoading != state.isUpcomingLoading {
                self.isUpcomingLoading = state.isUpcomingLoading
            }
            if self.selectedDate != state.selectedDate {
                self.selectedDate = state.selectedDate
            }
            self.updateDisplayedContentState()
        }
        // 天気の変化は AppController が指数を組み直して ObservationState を配信するため、上の購読で反映される。

        // タイムゾーンが変わったら、表示中の日付に対応する天気を引き直す。
        // Observations は購読開始時の値も流すため、開始時点の識別子と比べて変わったときだけ扱う。
        let locationController = appController.locationController
        let initialTimeZoneIdentifier = locationController.selectedTimeZone.identifier
        let timeZoneChanges = Observations { locationController.selectedTimeZone.identifier }
        timeZoneObservationTask = Task { [weak self] in
            var lastTimeZoneIdentifier = initialTimeZoneIdentifier
            for await identifier in timeZoneChanges where identifier != lastTimeZoneIdentifier {
                guard let self else { return }
                lastTimeZoneIdentifier = identifier
                self.updateDisplayedContentState()
            }
        }
    }

    /// 選択日の変更を AppController へ伝え、当日詳細を再計算させる。
    private func requestObservationDate(_ date: Date) {
        let normalizedDate = ObservationTimeZone.startOfDay(
            for: date,
            timeZone: selectedTimeZone
        )
        guard !ObservationTimeZone.isDate(
            appController.selectedDate,
            inSameDayAs: normalizedDate,
            timeZone: selectedTimeZone
        ) else {
            return
        }
        appController.selectObservationDate(
            normalizedDate,
            timeZone: selectedTimeZone
        )
    }

    var weatherService: any WeatherProviding {
        appController.weatherService
    }

    var lightPollutionService: LightPollutionService {
        appController.lightPollutionService
    }

    var displayedStarGazingIndex: StarGazingIndex? {
        guard let starGazingIndex else { return nil }
        guard let nightSummary else { return starGazingIndex }
        // ベース指数（AppController が注入された現在時刻で計算）と同じ「今」で部分予報を判定する。
        return starGazingIndex.adjusted(
            for: observationMode,
            nightSummary: nightSummary,
            weather: currentWeather,
            referenceDate: appController.currentDate()
        )
    }

    /// AppController の時計での現在時刻。星空指数のモード補正をベース指数と同じ基準時刻で行うために使う。
    func currentDate() -> Date {
        appController.currentDate()
    }

    /// 現在の観測日（アプリ全体の「今日」）。深夜〜明け方は進行中の前夜の日付を返す。
    /// - Parameter referenceDate: 現在時刻として扱う時刻。nil なら AppController の時計を使う。
    func currentObservationDate(referenceDate: Date? = nil) -> Date {
        appController.currentObservationDate(referenceDate: referenceDate)
    }

    /// 天気情報を再取得する。
    func refreshWeather() async {
        await appController.refreshWeather()
    }

    /// 光害情報を再取得する。
    func refreshLightPollution() async {
        await appController.refreshLightPollution()
    }

    /// 当日詳細に必要な外部データをまとめて更新する。
    func refreshExternalData() async {
        await appController.refreshExternalData()
    }

    /// 未来予報を再計算する。
    func refreshForecast() async {
        await appController.recalculateUpcomingAndWait()
    }

    /// 天気と光害データの再取得をバックグラウンドで開始する。
    func refreshExternalDataInBackground() {
        appController.refreshExternalDataInBackground()
    }

    /// バックグラウンドで天気再取得を行う。
    func retryWeatherInBackground() {
        Task {
            await refreshWeather()
        }
    }

    /// バックグラウンドで光害再取得を行う。
    func retryLightPollutionInBackground() {
        Task {
            await refreshLightPollution()
        }
    }

    /// バックグラウンドで予報再計算を行う。
    func retryForecastInBackground() {
        Task {
            await refreshForecast()
        }
    }

    private var effectiveDisplayDate: Date {
        guard isCalculating,
              let nightSummary,
              !ObservationTimeZone.isDate(
                nightSummary.date,
                inSameDayAs: selectedDate,
                timeZone: selectedTimeZone
              ) else {
            return selectedDate
        }

        return nightSummary.date
    }

    private func shouldPreserveDisplayedSummary(
        during state: AppController.ObservationState
    ) -> Bool {
        // 同じ地点・同じタイムゾーンで日付だけ変わった場合は、再計算中も前回表示を残す。
        guard state.isCalculating,
              state.nightSummary == nil,
              let displayedSummary = nightSummary else {
            return false
        }

        let selectedCoordinate = appController.locationController.selectedLocation
        let isSameLocation = displayedSummary.location.isSameCoordinate(as: selectedCoordinate)
        let isSameTimeZone = displayedSummary.timeZoneIdentifier == selectedTimeZone.identifier
        let isRefreshingDifferentDay = !ObservationTimeZone.isDate(
            displayedSummary.date,
            inSameDayAs: state.selectedDate,
            timeZone: selectedTimeZone
        )

        return isSameLocation && isSameTimeZone && isRefreshingDifferentDay
    }

    private func updateDisplayedContentState() {
        // 表示中の日付に対応する天気と星空指数を、観測タイムゾーン基準で揃える。
        let newDisplayedDate = effectiveDisplayDate
        if displayedDate != newDisplayedDate {
            displayedDate = newDisplayedDate
        }
        let weatherByDate = appController.weatherService.weatherByDate
        currentWeather = appController.weatherService.summary(
            for: newDisplayedDate,
            from: weatherByDate,
            timeZone: selectedTimeZone
        )
        let isCoverageIncomplete: Bool = {
            guard let nightSummary, let currentWeather else { return false }
            return !nightSummary.hasUsableWeatherData(
                nighttimeHours: currentWeather.nighttimeHours,
                referenceDate: appController.currentDate()
            )
        }()
        if isCurrentWeatherCoverageIncomplete != isCoverageIncomplete {
            isCurrentWeatherCoverageIncomplete = isCoverageIncomplete
        }
        let isOutOfRange = appController.weatherService.isForecastOutOfRange(
            for: newDisplayedDate,
            in: weatherByDate,
            timeZone: selectedTimeZone
        )
        if isCurrentWeatherForecastOutOfRange != isOutOfRange {
            isCurrentWeatherForecastOutOfRange = isOutOfRange
        }
    }
}
