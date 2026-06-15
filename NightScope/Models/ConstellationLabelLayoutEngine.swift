import CoreGraphics
#if os(macOS)
import AppKit
private typealias PlatformFont = NSFont
#elseif os(iOS)
import UIKit
private typealias PlatformFont = UIFont
#endif

// MARK: - Shared label types

struct ConstellationLabelCandidate: Equatable {
    let name: String
    let anchor: CGPoint
    let priority: Double
}

struct ConstellationLabelPlacement: Equatable {
    let name: String
    let anchor: CGPoint
    let origin: CGPoint
    let size: CGSize

    var bounds: CGRect {
        CGRect(origin: origin, size: size)
    }
}

// MARK: - Layout engine

/// 星座名ラベルの配置を最適化するグリーディアルゴリズム。
/// SwiftUI / AppKit / UIKit の描画には依存しない pure static functions のみ。
struct ConstellationLabelLayoutEngine {

    static func optimizedPlacements(
        candidates: [ConstellationLabelCandidate],
        canvasSize: CGSize,
        reservedBottomInset: Double = 0,
        fontSize: Double = 11
    ) -> [ConstellationLabelPlacement] {
        let sorted = candidates.sorted {
            $0.priority == $1.priority
                ? $0.name.count < $1.name.count
                : $0.priority > $1.priority
        }
        let reservedH = max(0, min(reservedBottomInset, canvasSize.height - 8))
        let availableH = max(0, canvasSize.height - reservedH - 8)
        let canvasRect = CGRect(x: 4, y: 4, width: max(0, canvasSize.width - 8), height: availableH)
        guard canvasRect.width > 0, canvasRect.height > 0 else { return [] }

        var accepted: [ConstellationLabelPlacement] = []
        for candidate in sorted {
            let sz = estimateLabelSize(text: candidate.name, fontSize: fontSize)
            for origin in candidateOrigins(anchor: candidate.anchor, labelSize: sz) {
                let fitted = clampOrigin(origin, labelSize: sz, canvasRect: canvasRect)
                let placement = ConstellationLabelPlacement(
                    name: candidate.name, anchor: candidate.anchor, origin: fitted, size: sz
                )
                let padded = placement.bounds.insetBy(dx: -4, dy: -2)
                let overlaps = accepted.contains { padded.intersects($0.bounds.insetBy(dx: -4, dy: -2)) }
                if !overlaps {
                    accepted.append(placement)
                    break
                }
            }
        }
        return accepted
    }

    static func estimateLabelSize(text: String, fontSize: Double = 11) -> CGSize {
        let measured = NSString(string: text).size(
            withAttributes: [.font: PlatformFont.systemFont(ofSize: fontSize)]
        )
        return CGSize(
            width:  ceil(max(measured.width,  fontSize * 2.6)),
            height: ceil(max(measured.height, fontSize + 4))
        )
    }

    static func candidateOrigins(anchor: CGPoint, labelSize: CGSize) -> [CGPoint] {
        let hOff = 8.0
        let vOff = 6.0
        return [
            CGPoint(x: anchor.x + hOff,                        y: anchor.y - labelSize.height - vOff),
            CGPoint(x: anchor.x + hOff,                        y: anchor.y + vOff),
            CGPoint(x: anchor.x - labelSize.width - hOff,      y: anchor.y - labelSize.height - vOff),
            CGPoint(x: anchor.x - labelSize.width - hOff,      y: anchor.y + vOff),
            CGPoint(x: anchor.x - labelSize.width / 2,         y: anchor.y - labelSize.height - 10),
            CGPoint(x: anchor.x - labelSize.width / 2,         y: anchor.y + 8)
        ]
    }

    static func clampOrigin(
        _ origin: CGPoint,
        labelSize: CGSize,
        canvasRect: CGRect
    ) -> CGPoint {
        CGPoint(
            x: min(max(origin.x, canvasRect.minX), canvasRect.maxX - labelSize.width),
            y: min(max(origin.y, canvasRect.minY), canvasRect.maxY - labelSize.height)
        )
    }
}
