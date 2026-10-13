import Foundation
import Combine

/// 月齢カレンダー画面の表示月・選択夜・月相データを管理する ViewModel。
@MainActor
final class LunarCalendarViewModel: ObservableObject {
    /// 表示中の月（観測地 TZ の、その月内の任意の日の 0 時）
    @Published private(set) var displayMonth: Date
    /// 日曜始まりのグリッド用。先頭の空セルは nil。
    @Published private(set) var days: [LunarDay?] = []
    @Published private(set) var selectedNight: Date
    @Published private(set) var isSouthernHemisphere: Bool
    @Published private(set) var timeZone: TimeZone

    private let currentObservationDate: () -> Date
    private let onOpenNight: (Date) -> Void
    private var cancellables = Set<AnyCancellable>()

    /// - Parameters:
    ///   - currentObservationDate: 「今日」とみなす観測夜を返す。
    ///   - onOpenNight: 「この夜の空模様を見る」で選んだ夜を受け取る。
    convenience init(
        location: any LocationProviding,
        currentObservationDate: @escaping () -> Date,
        onOpenNight: @escaping (Date) -> Void
    ) {
        self.init(
            latitude: location.selectedLocation.latitude,
            timeZone: location.selectedTimeZone,
            latitudePublisher: location.selectedLocationPublisher.map(\.latitude).eraseToAnyPublisher(),
            timeZonePublisher: location.selectedTimeZonePublisher,
            currentObservationDate: currentObservationDate,
            onOpenNight: onOpenNight
        )
    }

    init(
        latitude: Double,
        timeZone: TimeZone,
        latitudePublisher: AnyPublisher<Double, Never> = Empty().eraseToAnyPublisher(),
        timeZonePublisher: AnyPublisher<TimeZone, Never> = Empty().eraseToAnyPublisher(),
        currentObservationDate: @escaping () -> Date,
        onOpenNight: @escaping (Date) -> Void = { _ in }
    ) {
        self.currentObservationDate = currentObservationDate
        self.onOpenNight = onOpenNight
        let today = ObservationTimeZone.startOfDay(for: currentObservationDate(), timeZone: timeZone)
        self.timeZone = timeZone
        self.displayMonth = today
        self.selectedNight = today
        self.isSouthernHemisphere = latitude < 0
        recompute()

        latitudePublisher
            .map { $0 < 0 }
            .removeDuplicates()
            .sink { [weak self] in self?.isSouthernHemisphere = $0 }
            .store(in: &cancellables)
        timeZonePublisher
            .removeDuplicates()
            .sink { [weak self] in self?.updateTimeZone($0) }
            .store(in: &cancellables)
    }

    private var calendar: Calendar {
        ObservationTimeZone.gregorianCalendar(timeZone: timeZone)
    }

    var today: Date {
        ObservationTimeZone.startOfDay(for: currentObservationDate(), timeZone: timeZone)
    }

    var selectedDay: LunarDay? {
        days.lazy.compactMap { $0 }.first { $0.date == self.selectedNight }
    }

    /// 表示月の各夜に割り当てられた主要月相（時刻順）。
    var phaseEvents: [LunarPhaseEvent] {
        days.compactMap { $0?.principalEvent }
    }

    var canShiftBackward: Bool { shiftedMonth(by: -1) != nil }
    var canShiftForward: Bool { shiftedMonth(by: 1) != nil }

    func shiftMonth(by value: Int) {
        guard let month = shiftedMonth(by: value) else { return }
        displayMonth = month
        recompute()
        // 詳細パネルが消えないよう、選択も新しい月の同じ日（なければ月末）へ移す。
        let dayOfMonth = calendar.component(.day, from: selectedNight)
        let monthDays = days.compactMap { $0 }
        if let night = monthDays.first(where: { calendar.component(.day, from: $0.date) == dayOfMonth }) ?? monthDays.last {
            selectedNight = night.date
        }
    }

    func goToToday() {
        let today = today
        selectedNight = today
        if !calendar.isDate(today, equalTo: displayMonth, toGranularity: .month) {
            displayMonth = today
            recompute()
        }
    }

    func select(_ night: Date) {
        selectedNight = calendar.startOfDay(for: night)
    }

    func openNight(_ night: Date) {
        select(night)
        onOpenNight(selectedNight)
    }

    private func shiftedMonth(by value: Int) -> Date? {
        guard let month = calendar.date(byAdding: .month, value: value, to: displayMonth),
              LunarCalendar.supportedYears.contains(calendar.component(.year, from: month)) else { return nil }
        return calendar.startOfDay(for: month)
    }

    private func updateTimeZone(_ newTimeZone: TimeZone) {
        guard newTimeZone != timeZone else { return }
        let oldTimeZone = timeZone
        displayMonth = ObservationTimeZone.preservingCalendarDay(displayMonth, from: oldTimeZone, to: newTimeZone)
        selectedNight = ObservationTimeZone.preservingCalendarDay(selectedNight, from: oldTimeZone, to: newTimeZone)
        timeZone = newTimeZone
        recompute()
    }

    private func recompute() {
        let monthDays = LunarCalendar.month(containing: displayMonth, timeZone: timeZone)
        guard let first = monthDays.first else {
            days = []
            return
        }
        let leadingBlankCount = calendar.component(.weekday, from: first.date) - 1  // 1=日
        days = Array(repeating: nil, count: leadingBlankCount) + monthDays.map(Optional.some)
    }
}
