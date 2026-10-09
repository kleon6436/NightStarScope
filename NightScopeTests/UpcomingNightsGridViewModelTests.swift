import XCTest
@testable import NightScope

/// 既定の UserDefaults 保存先を使うと、保存済みの名前なし地点の復元で実際の逆ジオコーディングが走るため、
/// メモリ上の保存先（東京）を使う AppController を作る。
@MainActor
private func makeInMemoryAppController(
    weatherService: (any WeatherProviding)? = nil,
    calculationService: NightCalculating,
    now: @escaping () -> Date = Date.init
) -> AppController {
    let storage = AppControllerTests.InMemoryLocationStorage()
    storage.latitude = 35.6762
    storage.longitude = 139.6503
    storage.name = "東京"
    storage.timeZoneIdentifier = TestTimeZones.tokyo.identifier
    let locationController = LocationController(
        storage: storage,
        searchService: AppControllerTests.NoopLocationSearchService(),
        locationNameResolver: AppControllerTests.FixedLocationNameResolver(
            details: ResolvedLocationDetails(name: "東京", timeZoneIdentifier: TestTimeZones.tokyo.identifier)
        )
    )
    return AppController(
        locationController: locationController,
        weatherService: weatherService,
        calculationService: calculationService,
        now: now
    )
}

/// 東京の 21 時だけ天気予報がある（部分予報の）曇天の夜を作る。今夜扱いのときだけ天気が評価に入る。
private func makeCloudyPartiallyCoveredTokyoNight() -> (night: NightSummary, weather: DayWeatherSummary, now: Date) {
    let tokyo = TestTimeZones.tokyo
    let dayStart = ObservationTimeZone.gregorianCalendar(timeZone: tokyo).date(
        from: DateComponents(year: 2024, month: 3, day: 9)
    )!
    let (night, _) = makePartiallyCoveredNight(dayStart: dayStart, timeZone: tokyo)
    let cloudyHour = HourlyWeather(
        date: night.events[0].date,
        temperatureCelsius: 10,
        cloudCoverPercent: 90,
        precipitationMM: 0,
        windSpeedKmh: 5,
        humidityPercent: 60,
        dewpointCelsius: 2,
        weatherCode: 3,
        visibilityMeters: 20_000,
        windGustsKmh: nil,
        windSpeedKmh500hpa: nil
    )
    return (
        night,
        DayWeatherSummary(date: dayStart, nighttimeHours: [cloudyHour]),
        dayStart.addingTimeInterval(22 * 3600)
    )
}

@MainActor
final class UpcomingNightsGridViewModelTests: XCTestCase {
    func test_displaysAllUpcomingNights() async {
        let mockCalc = MockNightCalculationService()
        let appController = makeInMemoryAppController(calculationService: mockCalc)
        let timeZoneIdentifier = appController.locationController.selectedTimeZone.identifier
        let nightWithWindow = makeNightSummary(
            date: Date(),
            withWindow: true,
            timeZoneIdentifier: timeZoneIdentifier
        )
        let nightWithoutWindow = makeNightSummary(
            date: Date().addingTimeInterval(86_400),
            withWindow: false,
            timeZoneIdentifier: timeZoneIdentifier
        )
        await mockCalc.enqueueUpcomingNights([nightWithWindow, nightWithoutWindow])
        let detailVM = DetailViewModel(appController: appController)
        let gridVM = UpcomingNightsGridViewModel(detailViewModel: detailVM)

        appController.recalculateUpcoming()
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            if !gridVM.displayNights.isEmpty { break }
        }

        XCTAssertEqual(gridVM.displayNights.count, 2)
        XCTAssertFalse(gridVM.displayNights[0].viewingWindows.isEmpty)
        XCTAssertTrue(gridVM.displayNights[1].viewingWindows.isEmpty)
    }

    func test_observableRangeText_noWeather_emptyRange() {
        let mockCalc = MockNightCalculationService()
        let appController = makeInMemoryAppController(calculationService: mockCalc)
        let detailVM = DetailViewModel(appController: appController)
        let vm = UpcomingNightsGridViewModel(detailViewModel: detailVM)

        // placeholder は events=[] → totalDarkHours=0 → "暗い時間なし"
        XCTAssertEqual(vm.observableRangeText(night: .placeholder, weather: nil), L10n.tr("暗い時間なし"))
    }

    func test_weatherIconColor_clear() {
        let mockCalc = MockNightCalculationService()
        let appController = makeInMemoryAppController(calculationService: mockCalc)
        let detailVM = DetailViewModel(appController: appController)
        let vm = UpcomingNightsGridViewModel(detailViewModel: detailVM)

        XCTAssertEqual(vm.weatherIconColor(code: 0), .yellow)
        XCTAssertEqual(vm.weatherIconColor(code: 1), .yellow)
    }

    func test_weatherIconColor_rain() {
        let mockCalc = MockNightCalculationService()
        let appController = makeInMemoryAppController(calculationService: mockCalc)
        let detailVM = DetailViewModel(appController: appController)
        let vm = UpcomingNightsGridViewModel(detailViewModel: detailVM)

        XCTAssertEqual(vm.weatherIconColor(code: 61), .blue)
        XCTAssertEqual(vm.weatherIconColor(code: 80), .blue)
    }

    func test_weatherIconColor_thunderstorm() {
        let mockCalc = MockNightCalculationService()
        let appController = makeInMemoryAppController(calculationService: mockCalc)
        let detailVM = DetailViewModel(appController: appController)
        let vm = UpcomingNightsGridViewModel(detailViewModel: detailVM)

        XCTAssertEqual(vm.weatherIconColor(code: 95), .orange)
    }

    func test_cardAccessibilityLabel_containsDate() {
        let mockCalc = MockNightCalculationService()
        let appController = makeInMemoryAppController(calculationService: mockCalc)
        let detailVM = DetailViewModel(appController: appController)
        let vm = UpcomingNightsGridViewModel(detailViewModel: detailVM)

        let night = makeNightSummary()
        let label = vm.cardAccessibilityLabel(night: night, weather: nil, index: nil)
        XCTAssertTrue(label.contains(DateFormatters.fullDateString(from: night.date, timeZone: detailVM.selectedTimeZone)))
        XCTAssertTrue(label.contains(L10n.format("月: %@", night.moonPhaseName)))
    }

    func test_cardAccessibilityLabel_withIndex() {
        let mockCalc = MockNightCalculationService()
        let appController = makeInMemoryAppController(calculationService: mockCalc)
        let detailVM = DetailViewModel(appController: appController)
        let vm = UpcomingNightsGridViewModel(detailViewModel: detailVM)

        let night = makeNightSummary()
        let weather = DayWeatherSummary(date: night.date, nighttimeHours: [
            HourlyWeather(
                date: night.events[0].date,
                temperatureCelsius: 15,
                cloudCoverPercent: 10,
                precipitationMM: 0,
                windSpeedKmh: 5,
                humidityPercent: 40,
                dewpointCelsius: 2,
                weatherCode: 0,
                visibilityMeters: 20_000,
                windGustsKmh: nil,
                windSpeedKmh500hpa: nil
            )
        ])
        let index = StarGazingIndex.compute(nightSummary: night, weather: weather, bortleClass: 3.0)
        let label = vm.cardAccessibilityLabel(night: night, weather: weather, index: index)
        XCTAssertTrue(label.contains(L10n.format("星空指数%d", index.score)))
        XCTAssertTrue(label.contains(L10n.format("天気%@", weather.weatherLabel)))
    }

    func test_cardAccessibilityLabel_withPartialWeather_usesPartialForecastMessage() {
        let mockCalc = MockNightCalculationService()
        let appController = makeInMemoryAppController(calculationService: mockCalc)
        let detailVM = DetailViewModel(appController: appController)
        let vm = UpcomingNightsGridViewModel(detailViewModel: detailVM)

        let night = makeNightSummary(
            date: Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date(),
            withWindow: true
        )
        let weather = DayWeatherSummary(date: night.date, nighttimeHours: [
            makeHourlyWeather()
        ])
        let label = vm.cardAccessibilityLabel(night: night, weather: weather, index: nil)

        XCTAssertTrue(label.contains(L10n.tr("天気予報一部のみ")))
        XCTAssertFalse(label.contains(L10n.format("天気%@", weather.weatherLabel)))
    }

    func test_cardAccessibilityLabel_withCurrentNightPartialWeather_usesWeatherLabel() {
        let mockCalc = MockNightCalculationService()
        let appController = makeInMemoryAppController(calculationService: mockCalc)
        let detailVM = DetailViewModel(appController: appController)
        let vm = UpcomingNightsGridViewModel(detailViewModel: detailVM)

        let night = makeNightSummary(withWindow: true)
        let weatherHourStart = Calendar.current.dateInterval(of: .hour, for: night.events[0].date)?.start ?? night.events[0].date
        let weather = DayWeatherSummary(date: night.date, nighttimeHours: [
            HourlyWeather(
                date: weatherHourStart,
                temperatureCelsius: 15,
                cloudCoverPercent: 10,
                precipitationMM: 0,
                windSpeedKmh: 5,
                humidityPercent: 40,
                dewpointCelsius: 2,
                weatherCode: 0,
                visibilityMeters: 20_000,
                windGustsKmh: nil,
                windSpeedKmh500hpa: nil
            )
        ])
        let label = vm.cardAccessibilityLabel(night: night, weather: weather, index: nil)

        XCTAssertTrue(label.contains(L10n.format("天気%@", weather.weatherLabel)))
        XCTAssertFalse(label.contains(L10n.tr("天気予報一部のみ")))
    }

    /// 白夜（暗時間ゼロ）でも、市民薄明後の時間帯を覆う予報があれば「予報一部のみ」としない。
    func test_hasPartialWeatherData_whiteNightWithFullNightForecast_isNotPartial() {
        let appController = makeInMemoryAppController(calculationService: MockNightCalculationService())
        let detailVM = DetailViewModel(appController: appController)
        let vm = UpcomingNightsGridViewModel(detailViewModel: detailVM)

        // 未来の夜（今日扱いの部分予報にならないよう 10 日後の UTC 正時を基準にする）
        let utc = TimeZone(identifier: "UTC")!
        let base = ObservationTimeZone.startOfDay(for: Date().addingTimeInterval(10 * 86_400), timeZone: utc)
            .addingTimeInterval(22 * 3600)
        let night = NightSummary(
            date: ObservationTimeZone.startOfDay(for: base, timeZone: utc),
            location: .init(latitude: 51.5, longitude: 0),
            events: (0..<16).map { i in
                AstroEvent(
                    date: base.addingTimeInterval(Double(i) * 900),
                    galacticCenterAltitude: 0,
                    galacticCenterAzimuth: 0,
                    sunAltitude: -10,
                    moonAltitude: -5,
                    moonPhase: 0.1
                )
            },
            viewingWindows: [],
            moonPhaseAtMidnight: 0.1,
            timeZoneIdentifier: utc.identifier
        )
        XCTAssertEqual(night.totalDarkHours, 0)
        let weather = DayWeatherSummary(date: night.date, nighttimeHours: (0..<4).map { hour in
            HourlyWeather(
                date: base.addingTimeInterval(Double(hour) * 3600),
                temperatureCelsius: 15,
                cloudCoverPercent: 10,
                precipitationMM: 0,
                windSpeedKmh: 5,
                humidityPercent: 40,
                dewpointCelsius: 2,
                weatherCode: 0,
                visibilityMeters: 20_000,
                windGustsKmh: nil,
                windSpeedKmh500hpa: nil
            )
        })

        XCTAssertFalse(vm.hasPartialWeatherData(for: night, weather: weather))
        XCTAssertTrue(vm.hasReliableWeatherData(for: night, weather: weather))
    }

    func test_observationModePreference_persistsSelection() {
        let suiteName = "ObservationModePreferenceTests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let preference = ObservationModePreference(userDefaults: defaults, key: "observation.mode.test")
        preference.mode = .photography

        let restored = ObservationModePreference(userDefaults: defaults, key: "observation.mode.test")
        XCTAssertEqual(restored.mode, .photography)
    }

    func test_observationModePreference_migratesLegacyDeepSkyToMilkyWay() {
        let suiteName = "ObservationModePreferenceLegacyMigrationTests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set("deepSky", forKey: "observation.mode.test")

        let restored = ObservationModePreference(userDefaults: defaults, key: "observation.mode.test")

        XCTAssertEqual(restored.mode, .milkyWay)
        XCTAssertEqual(defaults.string(forKey: "observation.mode.test"), ObservationMode.milkyWay.rawValue)
    }

    func test_observationModePreference_migratesLegacyLunarPlanetaryToMoon() {
        let suiteName = "ObservationModePreferenceLegacyLunarPlanetaryMigrationTests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set("lunarPlanetary", forKey: "observation.mode.test")

        let restored = ObservationModePreference(userDefaults: defaults, key: "observation.mode.test")

        XCTAssertEqual(restored.mode, .moon)
        XCTAssertEqual(defaults.string(forKey: "observation.mode.test"), ObservationMode.moon.rawValue)
    }

    func test_starGazingIndexForDate_appliesObservationModeAdjustment() async {
        let preference = ObservationModePreference(
            userDefaults: UserDefaults(suiteName: #function)!,
            key: #function
        )
        preference.mode = .moon

        let appController = makeInMemoryAppController(calculationService: MockNightCalculationService())
        let detailVM = DetailViewModel(appController: appController, observationModePreference: preference)
        let vm = UpcomingNightsGridViewModel(detailViewModel: detailVM)

        let nightDate = Date()
        let night = NightSummary(
            date: nightDate,
            location: .init(latitude: 35.6762, longitude: 139.6503),
            events: [
                AstroEvent(
                    date: nightDate,
                    galacticCenterAltitude: 28,
                    galacticCenterAzimuth: 180,
                    sunAltitude: -20,
                    moonAltitude: 30,
                    moonPhase: 0.5
                )
            ],
            viewingWindows: [
                ViewingWindow(
                    start: nightDate,
                    end: nightDate.addingTimeInterval(3600),
                    peakTime: nightDate.addingTimeInterval(1800),
                    peakAltitude: 30,
                    peakAzimuth: 180
                )
            ],
            moonPhaseAtMidnight: 0.5
        )
        let weather = DayWeatherSummary(date: nightDate, nighttimeHours: [
            HourlyWeather(
                date: nightDate,
                temperatureCelsius: 15,
                cloudCoverPercent: 10,
                precipitationMM: 0,
                windSpeedKmh: 5,
                humidityPercent: 40,
                dewpointCelsius: 2,
                weatherCode: 0,
                visibilityMeters: 20_000,
                windGustsKmh: 15,
                windSpeedKmh500hpa: nil
            )
        ])
        let baseIndex = StarGazingIndex.compute(nightSummary: night, weather: weather, bortleClass: 3.0)
        let key = ObservationTimeZone.startOfDay(for: night.date, timeZone: detailVM.selectedTimeZone)

        appController.upcomingNights = [night]
        appController.upcomingIndexes = [key: baseIndex]
        try? await Task.sleep(nanoseconds: 10_000_000)

        let adjusted = vm.starGazingIndex(for: night.date)
        XCTAssertNotNil(adjusted)
        XCTAssertGreaterThan(adjusted?.score ?? 0, baseIndex.score)
    }

    // MARK: - 観測日（夜が明けるまでは前夜）を「今日」とする

    func test_isSelectedDateToday_afterMidnight_treatsPreviousNightAsToday() {
        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: TestTimeZones.tokyo)
        let afterMidnight = calendar.date(from: DateComponents(year: 2026, month: 8, day: 13, hour: 2))!
        let previousNight = calendar.date(from: DateComponents(year: 2026, month: 8, day: 12))!
        let calendarToday = calendar.date(from: DateComponents(year: 2026, month: 8, day: 13))!
        let appController = makeInMemoryAppController(
            calculationService: MockNightCalculationService(),
            now: { afterMidnight }
        )
        let detailVM = DetailViewModel(appController: appController)
        let vm = UpcomingNightsGridViewModel(detailViewModel: detailVM)

        XCTAssertEqual(vm.selectedDate, previousNight)
        XCTAssertTrue(vm.isSelectedDateToday())

        vm.setSelectedDate(calendarToday)
        XCTAssertFalse(vm.isSelectedDateToday())

        vm.selectToday()
        XCTAssertEqual(appController.selectedDate, previousNight)
        XCTAssertTrue(vm.isSelectedDateToday())
    }

    /// モード補正もベース指数と同じ（AppController に注入した）現在時刻で部分予報を判定する。
    func test_starGazingIndexForDate_usesInjectedNowForModeAdjustment() async {
        let preference = ObservationModePreference(
            userDefaults: UserDefaults(suiteName: #function)!,
            key: #function
        )
        preference.mode = .moon
        let (night, weather, fixedNow) = makeCloudyPartiallyCoveredTokyoNight()
        let weatherService = WeatherKitService()
        let appController = makeInMemoryAppController(
            weatherService: weatherService,
            calculationService: MockNightCalculationService(),
            now: { fixedNow }
        )
        let timeZone = appController.locationController.selectedTimeZone
        weatherService.weatherByDate = [weatherService.dateKey(night.date, timeZone: timeZone): weather]
        let detailVM = DetailViewModel(appController: appController, observationModePreference: preference)
        let vm = UpcomingNightsGridViewModel(detailViewModel: detailVM)
        let baseIndex = StarGazingIndex.compute(nightSummary: night, weather: nil, bortleClass: 1)

        appController.upcomingNights = [night]
        appController.upcomingIndexes = [ObservationTimeZone.startOfDay(for: night.date, timeZone: timeZone): baseIndex]
        try? await Task.sleep(nanoseconds: 10_000_000)

        let expected = baseIndex.adjusted(for: .moon, nightSummary: night, weather: weather, referenceDate: fixedNow)
        XCTAssertEqual(vm.starGazingIndex(for: night.date)?.score, expected.score)
        // 今夜扱いなので曇天（雲量 90%）の安全上限がかかる。
        XCTAssertLessThanOrEqual(vm.starGazingIndex(for: night.date)?.score ?? 100, 34)
    }
}
