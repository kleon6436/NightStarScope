import SwiftUI

enum LayoutMacOS {
    /// ウィンドウ最小幅
    static let windowMinWidth: CGFloat = 820
    /// ウィンドウ最小高
    static let windowMinHeight: CGFloat = 750
    /// サイドバー最小幅
    static let sidebarMinWidth: CGFloat = 260
    /// サイドバー理想幅
    static let sidebarIdealWidth: CGFloat = 280
    /// サイドバー最大幅（コンテンツ300pt + 左右余白16pt）
    static let sidebarMaxWidth: CGFloat = 332
    /// 要約カード4枚の共通最小幅
    static let summaryCardMinWidth: CGFloat = 220
    /// 予報テーブル「夜」列の幅（日付 + 今夜/明夜のラベルが英語でも収まる幅）
    static let forecastDateColumn: CGFloat = 150
    /// 予報テーブル「雲量」列の幅
    static let forecastCloudColumn: CGFloat = 64
    /// 予報テーブル「天気」列の幅（天気ラベル + 夜間の最高/最低気温が収まる幅）
    static let forecastWeatherColumn: CGFloat = 190
    /// 予報テーブル「月」列の幅（月相名 + 月明かり注記が英語でも収まる幅）
    static let forecastMoonColumn: CGFloat = 210
    /// 予報テーブル「暗夜開始」列の幅
    static let forecastDarkColumn: CGFloat = 120
    /// 予報テーブル「天の川ピーク」列の幅
    static let forecastMilkyWayColumn: CGFloat = 130
    /// 予報テーブル「星空指数」列の最小幅（可変列）
    static let forecastIndexColumnMinWidth: CGFloat = 150
    /// 予報テーブル「星空指数」列の最大幅。広いウィンドウで列が離れすぎないよう上限を置く。
    static let forecastIndexColumnMaxWidth: CGFloat = 240
    /// 予報テーブルの行の高さ
    static let forecastRowHeight: CGFloat = 40
}
