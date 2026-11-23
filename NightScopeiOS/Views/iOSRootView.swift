import SwiftUI
import UIKit

/// iOS 版の主要画面を TabView でまとめるルート View。
struct iOSRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var rootStore: AppRootStore
    @State private var selectedTab = 0
    @State private var hasHandledCurrentActiveState = false

    /// AppRootStore を外部から差し替えられるようにする。
    @MainActor
    init(dependencies: AppRootDependencies? = nil) {
        // @State の初期値は View の再生成のたびに評価されるため、アプリ本体は依存関係を一度だけ作って渡す。
        // ここで作られる AppRootStore は依存関係を参照するだけで、AppController は生成しない。
        _rootStore = State(wrappedValue: AppRootStore(dependencies: dependencies ?? .makeDefault()))
    }

    var body: some View {
        // 主要な画面遷移はタブに集約し、各画面の責務を分ける。
        TabView(selection: $selectedTab) {
            iOSTodayView(
                detailViewModel: rootStore.detailViewModel,
                observationModePreference: rootStore.observationModePreference,
                favoriteSyncReconciler: rootStore.favoriteSyncReconciler
            )
                .tabItem {
                    Label("空模様", systemImage: "moon.stars")
                }
                .tag(0)

            iOSForecastView(detailViewModel: rootStore.detailViewModel, selectedTab: $selectedTab)
                .tabItem {
                    Label("予報", systemImage: "calendar")
                }
                .tag(1)

            iOSLocationView(
                sidebarViewModel: rootStore.sidebarViewModel,
                favoriteSyncReconciler: rootStore.favoriteSyncReconciler
            )
                .tabItem {
                    Label("場所", systemImage: "mappin.circle")
                }
                .tag(2)

            iOSStarMapView(viewModel: rootStore.starMapViewModel)
                .tabItem {
                    Label("星空", systemImage: "sparkles")
                }
                .tag(3)

            iOSLunarCalendarView(viewModel: rootStore.lunarCalendarViewModel, selectedTab: $selectedTab)
                .tabItem {
                    Label("月齢", systemImage: AppIcons.Astronomy.moonPhaseWaxingCrescent)
                }
                .tag(4)
        }
        // 下方向へのスクロール中はタブバーを縮め、内容を広く見せる。
        .tabBarMinimizeBehavior(.onScrollDown)
        .onAppear {
            handleActiveSceneIfNeeded()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else {
                hasHandledCurrentActiveState = false
                rootStore.appController.stopForegroundRefresh()
                return
            }
            handleActiveSceneIfNeeded()
        }
        // SwiftUI の onReceive は Publisher を受け取る API のため、通知の Publisher をそのまま使う（Combine は import しない）。
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            // 日付境界の変化はシーン復帰とは別経路で反映する。
            guard scenePhase == .active else { return }
            rootStore.appController.handleSceneDidBecomeActive(refreshExternalData: false)
        }
    }

    private func handleActiveSceneIfNeeded() {
        guard scenePhase == .active else { return }
        guard !hasHandledCurrentActiveState else { return }
        hasHandledCurrentActiveState = true
        rootStore.appController.handleSceneDidBecomeActive()
        rootStore.appController.startForegroundRefresh()
    }
}

#Preview {
    iOSRootView()
}
