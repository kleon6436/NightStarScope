import Foundation
import os

/// Instruments の os_signpost で計測するための共有 signposter。
/// 記録していないときの begin/end は有効判定だけで戻るため、頻繁に呼ばれる計算に置いてもよい。
enum PerformanceSignposts {
    static let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "NightScope",
        category: "Performance"
    )
}
