import SwiftUI
import MapKit
import CoreLocation
import Foundation

struct DetailErrorOverlay: View {
    let weatherErrorMessage: String?
    let hasLightPollutionError: Bool
    let retryWeatherAction: () -> Void
    let retryLightPollutionAction: () -> Void

    var body: some View {
        VStack(spacing: Spacing.xs) {
            if hasLightPollutionError {
                DetailErrorBanner(
                    message: L10n.tr("光害データの取得に失敗しました"),
                    retryAction: retryLightPollutionAction
                )
            }
            if let weatherErrorMessage {
                DetailErrorBanner(
                    message: weatherErrorMessage,
                    retryAction: retryWeatherAction
                )
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.bottom, Spacing.sm)
    }
}

private struct DetailErrorBanner: View {
    let message: String
    let retryAction: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // 横並びでは本文も「再試行」も 1〜2 文字ずつに折れるため、ボタンを本文の下へ回す。
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                        warningIcon
                        messageText
                    }
                    retryButton
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                HStack(spacing: Spacing.xs) {
                    warningIcon
                    messageText
                    Spacer()
                    retryButton
                }
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .glassEffectCompat(in: RoundedRectangle(cornerRadius: Layout.smallCornerRadius))
        .shadow(radius: 4)
        .accessibilityLabel(L10n.format("エラー: %@", message))
    }

    private var warningIcon: some View {
        Image(systemName: AppIcons.Status.warning)
            .foregroundStyle(.orange)
            .accessibilityHidden(true)
    }

    private var messageText: some View {
        Text(message)
            .font(.body)
            // 既定より大きな文字サイズでは 2 行に収まらないため 1 行増やす。
            .lineLimit(dynamicTypeSize > .large ? 3 : 2)
            // 下端のインセットでは縦幅が詰められて 1 行に省略されるため、必要な行数ぶんの高さを確保する。
            .fixedSize(horizontal: false, vertical: true)
    }

    private var retryButton: some View {
        Button("再試行", action: retryAction)
            .glassButtonStyle()
            .controlSize(.small)
            .fixedSize()
    }
}

struct LocationSearchResultContent: View {
    let item: MKMapItem
    let iconSystemName: String
    let titleFont: Font
    let subtitleFont: Font
    let lineSpacing: CGFloat
    let titleFallback: String
    let iconWidth: CGFloat?

    init(
        item: MKMapItem,
        iconSystemName: String = "mappin.circle.fill",
        titleFont: Font = .body,
        subtitleFont: Font = .body,
        lineSpacing: CGFloat = 0,
        titleFallback: String = L10n.tr("不明"),
        iconWidth: CGFloat? = nil
    ) {
        self.item = item
        self.iconSystemName = iconSystemName
        self.titleFont = titleFont
        self.subtitleFont = subtitleFont
        self.lineSpacing = lineSpacing
        self.titleFallback = titleFallback
        self.iconWidth = iconWidth
    }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: iconSystemName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: iconWidth)

            VStack(alignment: .leading, spacing: lineSpacing) {
                Text(item.name ?? titleFallback)
                    .font(titleFont)
                    .foregroundStyle(.primary)

                if #available(iOS 26, macOS 26, *),
                   let address = item.address,
                   let subtitle = address.shortAddress ?? address.fullAddress.nilIfEmpty {
                    Text(subtitle)
                        .font(subtitleFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    let subtitle = [item.placemark.locality, item.placemark.administrativeArea]
                        .compactMap { $0 }.joined(separator: ", ")
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(subtitleFont)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SelectedLocationSummaryContent: View {
    let locationName: String
    let coordinate: CLLocationCoordinate2D
    let titleFont: Font
    let coordinateFont: Font
    let showsAccentIcon: Bool

    init(
        locationName: String,
        coordinate: CLLocationCoordinate2D,
        titleFont: Font = .headline,
        coordinateFont: Font = .body,
        showsAccentIcon: Bool = true
    ) {
        self.locationName = locationName
        self.coordinate = coordinate
        self.titleFont = titleFont
        self.coordinateFont = coordinateFont
        self.showsAccentIcon = showsAccentIcon
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
                if showsAccentIcon {
                    Image(systemName: AppIcons.Navigation.locationPinPlain)
                        .foregroundStyle(Color.accentColor)
                        .font(.body)
                        .accessibilityHidden(true)
                }

                Text(locationName)
                    .font(titleFont)
            }

            Text(String(format: "%.4f°, %.4f°", coordinate.latitude, coordinate.longitude))
                .font(coordinateFont)
                .foregroundStyle(.secondary)
                .accessibilityLabel(
                    L10n.format("緯度%.4f度、経度%.4f度", coordinate.latitude, coordinate.longitude)
                )
        }
    }
}

