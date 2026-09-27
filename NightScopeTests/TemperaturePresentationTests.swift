import XCTest
import Combine
@testable import NightScope

// MARK: - DayWeatherSummary の気温集計

final class DayWeatherTemperatureTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 1_750_000_000)

    func test_nightTemperatureRange_emptyHours_returnsNil() {
        let summary = DayWeatherSummary(date: baseDate, nighttimeHours: [])
        XCTAssertNil(summary.nightTemperatureRange)
        XCTAssertEqual(summary.maxTemperature, 0)
    }

    func test_nightTemperatureRange_singleHour_collapsesToOneValue() {
        let summary = DayWeatherSummary(
            date: baseDate,
            nighttimeHours: [makeHour(offsetHours: 0, temperature: 9.5)]
        )
        XCTAssertEqual(summary.nightTemperatureRange, 9.5...9.5)
        XCTAssertEqual(summary.maxTemperature, 9.5)
        XCTAssertEqual(summary.minTemperature, 9.5)
    }

    func test_nightTemperatureRange_multipleHours_spansMinToMax() {
        let summary = DayWeatherSummary(date: baseDate, nighttimeHours: [
            makeHour(offsetHours: 0, temperature: 12),
            makeHour(offsetHours: 1, temperature: -3),
            makeHour(offsetHours: 2, temperature: 6)
        ])
        XCTAssertEqual(summary.nightTemperatureRange, -3...12)
        XCTAssertEqual(summary.maxTemperature, 12)
        XCTAssertEqual(summary.minTemperature, -3)
    }

    private func makeHour(offsetHours: Double, temperature: Double) -> HourlyWeather {
        makeTemperatureHour(date: baseDate.addingTimeInterval(offsetHours * 3600), temperature: temperature)
    }
}

// MARK: - TemperatureFormat

final class TemperatureFormatTests: XCTestCase {
    private let japan = Locale(identifier: "ja_JP")
    private let unitedStates = Locale(identifier: "en_US")

    func test_short_japan_usesCelsius() {
        XCTAssertEqual(TemperatureFormat.short(18, locale: japan), "18°")
    }

    func test_short_unitedStates_convertsToFahrenheit() {
        XCTAssertEqual(TemperatureFormat.short(18, locale: unitedStates), "64°")
    }

    func test_short_negativeValue() {
        XCTAssertEqual(TemperatureFormat.short(-3, locale: japan), "-3°")
        XCTAssertEqual(TemperatureFormat.short(-3, locale: unitedStates), "27°")
    }

    func test_short_roundsHalfAwayFromZero() {
        XCTAssertEqual(TemperatureFormat.short(12.5, locale: japan), "13°")
        XCTAssertEqual(TemperatureFormat.short(12.4, locale: japan), "12°")
        XCTAssertEqual(TemperatureFormat.short(-2.5, locale: japan), "-3°")
    }

    func test_short_smallNegativeValue_doesNotShowNegativeZero() {
        XCTAssertEqual(TemperatureFormat.short(-0.3, locale: japan), "0°")
        // -17.9℃ ≒ -0.2℉
        XCTAssertEqual(TemperatureFormat.short(-17.9, locale: unitedStates), "0°")
    }

    func test_range_formatsHighThenLow() {
        XCTAssertEqual(TemperatureFormat.range(high: 12, low: 6, locale: japan), "12°/6°")
        XCTAssertEqual(TemperatureFormat.range(high: 12, low: -3, locale: japan), "12°/-3°")
        XCTAssertEqual(TemperatureFormat.range(high: 18, low: -3, locale: unitedStates), "64°/27°")
    }

    func test_spoken_includesUnitName() {
        XCTAssertEqual(TemperatureFormat.spoken(18, locale: unitedStates), "64 degrees Fahrenheit")
        XCTAssertEqual(TemperatureFormat.spoken(18, locale: japan), "摂氏18度")
    }
}

// MARK: - ForecastCardPresentation.temperatureRangeText

final class ForecastTemperaturePresentationTests: XCTestCase {
    func test_temperatureRangeText_reliableWeather_returnsHighAndLow() {
        let weather = DayWeatherSummary(date: Date(), nighttimeHours: [
            makeTemperatureHour(date: Date(), temperature: 12),
            makeTemperatureHour(date: Date().addingTimeInterval(3600), temperature: 6)
        ])
        let sut = makePresentation(weather: weather, isReliableWeather: true)
        XCTAssertEqual(sut.temperatureRangeText, TemperatureFormat.range(high: 12, low: 6))
    }

    func test_temperatureRangeText_partialWeather_returnsNil() {
        let sut = makePresentation(
            weather: makeDayWeatherSummary(),
            isReliableWeather: false,
            hasPartialWeather: true
        )
        XCTAssertNil(sut.temperatureRangeText)
    }

    func test_temperatureRangeText_outOfRange_returnsNil() {
        let sut = makePresentation(weather: nil, isReliableWeather: false, isForecastOutOfRange: true)
        XCTAssertNil(sut.temperatureRangeText)
    }

    func test_temperatureRangeText_loadError_returnsNil() {
        let sut = makePresentation(weather: nil, isReliableWeather: false, hasWeatherLoadError: true)
        XCTAssertNil(sut.temperatureRangeText)
    }

    private func makePresentation(
        weather: DayWeatherSummary?,
        isReliableWeather: Bool,
        hasPartialWeather: Bool = false,
        isForecastOutOfRange: Bool = false,
        hasWeatherLoadError: Bool = false
    ) -> ForecastCardPresentation {
        let night = makeNightSummary()
        return ForecastCardPresentation(
            night: night,
            weather: weather,
            timeZone: night.timeZone,
            isReliableWeather: isReliableWeather,
            hasPartialWeather: hasPartialWeather,
            isForecastOutOfRange: isForecastOutOfRange,
            hasWeatherLoadError: hasWeatherLoadError
        )
    }
}

// MARK: - 夜間天気カードの風速行

@MainActor
final class NightWeatherCardTemperatureTests: XCTestCase {
    func test_formatWindAndTemperature_appendsNightRangeToWindLine() {
        let vm = NightWeatherCardViewModel()
        let weather = DayWeatherSummary(date: Date(), nighttimeHours: [
            makeTemperatureHour(date: Date(), temperature: 12),
            makeTemperatureHour(date: Date().addingTimeInterval(3600), temperature: 6)
        ])
        XCTAssertEqual(
            vm.formatWindAndTemperature(wind: 8, weather: weather),
            L10n.format("%@ ・ %@", vm.formatWindSpeed(8), TemperatureFormat.range(high: 12, low: 6))
        )
    }

    func test_accessibilityDescription_includesNightTemperature() {
        let vm = NightWeatherCardViewModel()
        let weather = DayWeatherSummary(date: Date(), nighttimeHours: [
            makeTemperatureHour(date: Date(), temperature: 12),
            makeTemperatureHour(date: Date().addingTimeInterval(3600), temperature: 6)
        ])
        let description = vm.accessibilityDescription(
            weather: weather,
            isLoading: false,
            isForecastOutOfRange: false,
            isCoverageIncomplete: false
        )
        XCTAssertTrue(description.contains(TemperatureFormat.accessibilityRange(high: 12, low: 6)))
    }
}

// MARK: - WeatherKitService の現在気温キャッシュ

@MainActor
final class WeatherKitServiceCurrentTemperatureTests: XCTestCase {
    private let tokyo = TestTimeZones.tokyo
    private let keyA = "35.0000,135.0000|Asia/Tokyo"
    private let keyB = "34.0000,135.0000|Asia/Tokyo"

    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_750_000_000)
    }

    func test_initialState_hasNoCurrentTemperature() {
        XCTAssertNil(WeatherKitService().currentTemperatureCelsius)
    }

    func test_locationSwitch_swapsCurrentTemperature() {
        let clock = Clock()
        let service = WeatherKitService(now: { clock.now })

        service.applyFetchResult(makeResult(locationKey: keyA, celsius: 10, observedAt: clock.now))
        XCTAssertEqual(service.currentTemperatureCelsius, 10)

        service.applyFetchResult(makeResult(locationKey: keyB, celsius: 20, observedAt: clock.now))
        XCTAssertEqual(service.currentTemperatureCelsius, 20)

        service.prepareForLocationChange(latitude: 35, longitude: 135, timeZone: tokyo)
        XCTAssertEqual(service.currentTemperatureCelsius, 10)
    }

    func test_locationSwitch_toUnfetchedLocation_clearsCurrentTemperature() {
        let clock = Clock()
        let service = WeatherKitService(now: { clock.now })
        service.applyFetchResult(makeResult(locationKey: keyA, celsius: 10, observedAt: clock.now))

        service.prepareForLocationChange(latitude: 1, longitude: 2, timeZone: tokyo)

        XCTAssertNil(service.currentTemperatureCelsius)
    }

    func test_observationOlderThan90Minutes_isHidden() {
        let clock = Clock()
        let service = WeatherKitService(now: { clock.now })

        service.applyFetchResult(
            makeResult(locationKey: keyA, celsius: 10, observedAt: clock.now.addingTimeInterval(-91 * 60))
        )

        XCTAssertNil(service.currentTemperatureCelsius)
    }

    func test_observationWithin90Minutes_isShown() {
        let clock = Clock()
        let service = WeatherKitService(now: { clock.now })

        service.applyFetchResult(
            makeResult(locationKey: keyA, celsius: 10, observedAt: clock.now.addingTimeInterval(-89 * 60))
        )

        XCTAssertEqual(service.currentTemperatureCelsius, 10)
    }

    func test_cachedValue_becomesHiddenAfter90MinutesOnReturn() {
        let clock = Clock()
        let service = WeatherKitService(now: { clock.now })
        service.applyFetchResult(makeResult(locationKey: keyA, celsius: 10, observedAt: clock.now))
        service.applyFetchResult(makeResult(locationKey: keyB, celsius: 20, observedAt: clock.now))

        clock.now = clock.now.addingTimeInterval(91 * 60)
        service.prepareForLocationChange(latitude: 35, longitude: 135, timeZone: tokyo)

        XCTAssertNil(service.currentTemperatureCelsius)
    }

    func test_failedFetch_keepsFreshCachedTemperature() {
        let clock = Clock()
        let service = WeatherKitService(now: { clock.now })
        service.applyFetchResult(makeResult(locationKey: keyA, celsius: 10, observedAt: clock.now))

        service.applyFetchResult(WeatherFetchResult(
            weatherByDate: [:],
            errorMessage: "network",
            lastModifiedDate: nil,
            locationKey: keyA,
            timeZoneIdentifier: tokyo.identifier
        ))

        XCTAssertEqual(service.currentTemperatureCelsius, 10)
    }

    func test_snapshotCacheHit_carriesCurrentTemperature() async {
        let clock = Clock()
        let service = WeatherKitService(now: { clock.now })
        let observedAt = clock.now
        service.applyFetchResult(makeResult(locationKey: keyA, celsius: 10, observedAt: observedAt))

        let snapshot = await service.fetchWeatherSnapshot(latitude: 35, longitude: 135, timeZone: tokyo)

        XCTAssertEqual(snapshot.currentTemperatureCelsius, 10)
        XCTAssertEqual(snapshot.currentObservedAt, observedAt)
    }

    func test_publisher_emitsCurrentTemperature() {
        let clock = Clock()
        let service = WeatherKitService(now: { clock.now })
        var received: [Double?] = []
        let cancellable = service.currentTemperaturePublisher.sink { received.append($0) }

        service.applyFetchResult(makeResult(locationKey: keyA, celsius: 10, observedAt: clock.now))

        XCTAssertEqual(received.last ?? nil, 10)
        cancellable.cancel()
    }

    // MARK: 再取得なしでの失効

    /// 待機を外から再開できる sleep の代役。要求された待ち時間も記録する。
    private final class ManualSleeper {
        private(set) var requestedDelays: [TimeInterval] = []
        private var continuations: [CheckedContinuation<Void, Never>] = []

        func sleep(_ delay: TimeInterval) async {
            requestedDelays.append(delay)
            await withCheckedContinuation { continuations.append($0) }
        }

        func resumeAll() {
            let pending = continuations
            continuations.removeAll()
            pending.forEach { $0.resume() }
        }

        func resumeFirst() {
            guard !continuations.isEmpty else { return }
            continuations.removeFirst().resume()
        }
    }

    func test_currentTemperature_expiresAfterMaxAge_withoutRefetch() async {
        let clock = Clock()
        let sleeper = ManualSleeper()
        let service = WeatherKitService(now: { clock.now }, sleep: { await sleeper.sleep($0) })
        let expired = expectation(description: "現在気温が消える")
        let cancellable = service.currentTemperaturePublisher.dropFirst().sink { value in
            if value == nil { expired.fulfill() }
        }

        service.applyFetchResult(
            makeResult(locationKey: keyA, celsius: 10, observedAt: clock.now.addingTimeInterval(-30 * 60))
        )
        XCTAssertEqual(service.currentTemperatureCelsius, 10)
        await waitForSleepRequest(sleeper, count: 1)
        XCTAssertEqual(sleeper.requestedDelays, [60 * 60], "観測から 90 分の時点まで待つ")

        sleeper.resumeAll()
        await fulfillment(of: [expired], timeout: 1)
        XCTAssertNil(service.currentTemperatureCelsius)
        cancellable.cancel()
    }

    func test_expiry_doesNotClearNewerReading() async {
        let clock = Clock()
        let sleeper = ManualSleeper()
        let service = WeatherKitService(now: { clock.now }, sleep: { await sleeper.sleep($0) })

        service.applyFetchResult(makeResult(locationKey: keyA, celsius: 10, observedAt: clock.now))
        await waitForSleepRequest(sleeper, count: 1)
        service.applyFetchResult(makeResult(locationKey: keyB, celsius: 20, observedAt: clock.now))
        await waitForSleepRequest(sleeper, count: 2)

        // 地点 A の古い予約だけを起こしても、表示中の地点 B の値は残る
        sleeper.resumeFirst()
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(service.currentTemperatureCelsius, 20)
    }

    private func waitForSleepRequest(_ sleeper: ManualSleeper, count: Int) async {
        for _ in 0..<100 where sleeper.requestedDelays.count < count {
            await Task.yield()
        }
        XCTAssertEqual(sleeper.requestedDelays.count, count)
    }

    /// キャッシュ TTL の判定を通すため、天気データは 1 夜分入れておく。
    private func makeResult(locationKey: String, celsius: Double, observedAt: Date) -> WeatherFetchResult {
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        return WeatherFetchResult(
            weatherByDate: ["2025-06-15": DayWeatherSummary(date: date, nighttimeHours: [
                makeTemperatureHour(date: date, temperature: celsius)
            ])],
            errorMessage: nil,
            lastModifiedDate: nil,
            locationKey: locationKey,
            timeZoneIdentifier: tokyo.identifier,
            currentTemperatureCelsius: celsius,
            currentObservedAt: observedAt
        )
    }
}

// MARK: - DetailViewModel の現在気温

@MainActor
final class DetailViewModelCurrentTemperatureTests: XCTestCase {
    func test_currentTemperatureText_followsServicePublisher() {
        let weatherService = WeatherKitService()
        let appController = AppController(
            weatherService: weatherService,
            calculationService: MockNightCalculationService()
        )
        let vm = DetailViewModel(appController: appController)
        XCTAssertNil(vm.currentTemperatureText)

        weatherService.currentTemperatureCelsius = 18
        XCTAssertEqual(vm.currentTemperatureText, TemperatureFormat.short(18))
        XCTAssertEqual(
            vm.currentTemperatureAccessibilityLabel,
            L10n.format("現在の気温 %@", TemperatureFormat.spoken(18))
        )

        weatherService.currentTemperatureCelsius = nil
        XCTAssertNil(vm.currentTemperatureText)
        XCTAssertNil(vm.currentTemperatureAccessibilityLabel)
    }
}

// MARK: - ダッシュボードのセル読み上げ

@MainActor
final class DashboardTemperatureAccessibilityTests: XCTestCase {
    func test_weatherAccessibilityDescription_includesSpokenNightLow() {
        let weather = DayWeatherSummary(date: Date(), nighttimeHours: [
            makeTemperatureHour(date: Date(), temperature: 12),
            makeTemperatureHour(date: Date().addingTimeInterval(3600), temperature: 6)
        ])
        XCTAssertEqual(
            DashboardViewModel.weatherAccessibilityDescription(for: weather),
            L10n.format("%@、夜間の最低気温 %@", weather.weatherLabel, TemperatureFormat.spoken(6))
        )
    }

    func test_weatherAccessibilityDescription_emptyHours_omitsTemperature() {
        let weather = DayWeatherSummary(date: Date(), nighttimeHours: [])
        XCTAssertEqual(DashboardViewModel.weatherAccessibilityDescription(for: weather), weather.weatherLabel)
    }

    func test_weatherAccessibilityDescription_noWeather_returnsUnknown() {
        XCTAssertEqual(DashboardViewModel.weatherAccessibilityDescription(for: nil), L10n.tr("不明"))
    }
}

// MARK: - Helpers

private func makeTemperatureHour(date: Date, temperature: Double) -> HourlyWeather {
    HourlyWeather(
        date: date,
        temperatureCelsius: temperature,
        cloudCoverPercent: 10,
        precipitationMM: 0,
        windSpeedKmh: 5,
        humidityPercent: 50,
        dewpointCelsius: temperature - 5,
        weatherCode: 0,
        visibilityMeters: nil,
        windGustsKmh: nil,
        windSpeedKmh500hpa: nil
    )
}
