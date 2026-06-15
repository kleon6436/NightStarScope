import CoreGraphics

/// 画面座標済みの明るい星をグリッドに格納し、タップ判定を O(cells) に削減する。
/// タップのたびに再利用可能（星位置が変わったら再初期化）。
struct StarMapSpatialIndex {

    private struct Entry {
        let position: StarPosition
        let screenPoint: CGPoint
    }

    private let cellCount: Int
    private let canvasSize: CGSize
    private var grid: [[Entry]]   // [cellY * cellCount + cellX]

    init(
        stars: [StarPosition],
        projection: (Double, Double) -> CGPoint?,
        canvasSize: CGSize,
        cellCount: Int = 20,
        maxMagnitude: Double = 2.5,
        minAltitude: Double = -3
    ) {
        self.cellCount  = cellCount
        self.canvasSize = canvasSize
        self.grid = Array(repeating: [], count: cellCount * cellCount)

        for pos in stars where pos.star.magnitude <= maxMagnitude && pos.altitude > minAltitude {
            let altRad = pos.altitude * .pi / 180
            let azRad  = pos.azimuth  * .pi / 180
            guard let pt = projection(altRad, azRad) else { continue }
            let col = Int(pt.x / canvasSize.width  * Double(cellCount)).clamped(0, cellCount - 1)
            let row = Int(pt.y / canvasSize.height * Double(cellCount)).clamped(0, cellCount - 1)
            grid[row * cellCount + col].append(Entry(position: pos, screenPoint: pt))
        }
    }

    func nearest(to tapPoint: CGPoint, threshold: CGFloat) -> StarPosition? {
        let cellW = canvasSize.width  / Double(cellCount)
        let cellH = canvasSize.height / Double(cellCount)

        let colMin = max(0, Int((tapPoint.x - threshold) / cellW))
        let colMax = min(cellCount - 1, Int((tapPoint.x + threshold) / cellW))
        let rowMin = max(0, Int((tapPoint.y - threshold) / cellH))
        let rowMax = min(cellCount - 1, Int((tapPoint.y + threshold) / cellH))

        var best: StarPosition? = nil
        var bestDist: CGFloat = threshold

        for row in rowMin...rowMax {
            for col in colMin...colMax {
                for entry in grid[row * cellCount + col] {
                    let dx = entry.screenPoint.x - tapPoint.x
                    let dy = entry.screenPoint.y - tapPoint.y
                    let dist = sqrt(dx * dx + dy * dy)
                    if dist < bestDist {
                        bestDist = dist
                        best = entry.position
                    }
                }
            }
        }
        return best
    }
}

private extension Int {
    func clamped(_ lo: Int, _ hi: Int) -> Int {
        if self < lo { return lo }
        if self > hi { return hi }
        return self
    }
}
