import SwiftUI

@main
struct NightScopeiOSApp: App {
    @StateObject private var weatherAttributionService = WeatherAttributionService()
    /// AppController を含むルート依存関係。アプリ起動時に一度だけ作る。
    private let rootDependencies = AppRootDependencies.makeDefault()

    var body: some Scene {
        WindowGroup {
            iOSRootView(dependencies: rootDependencies)
                .environmentObject(weatherAttributionService)
        }
    }
}
