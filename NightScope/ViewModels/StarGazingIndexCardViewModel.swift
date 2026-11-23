import SwiftUI
import Combine

/// 光害取得状態を星空指数カードへ伝える ViewModel。
@MainActor
@Observable
final class StarGazingIndexCardViewModel {
    private(set) var isLoading: Bool = false
    private(set) var fetchFailed: Bool = false
    private(set) var isOutOfCoverage: Bool = false

    @ObservationIgnored private let lightPollutionService: LightPollutionService
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()

    init(lightPollutionService: LightPollutionService) {
        self.lightPollutionService = lightPollutionService
        setupBindings()
    }

    /// 光害サービスの状態をそのままカードの表示状態へ反映する。
    private func setupBindings() {
        lightPollutionService.$isLoading
            .sink { [weak self] in self?.isLoading = $0 }
            .store(in: &cancellables)

        lightPollutionService.$fetchFailed
            .sink { [weak self] in self?.fetchFailed = $0 }
            .store(in: &cancellables)

        lightPollutionService.$isOutOfCoverage
            .sink { [weak self] in self?.isOutOfCoverage = $0 }
            .store(in: &cancellables)
    }
}
