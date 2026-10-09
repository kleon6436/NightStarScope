import SwiftUI

extension StarMapCanvasView {
    // MARK: - Drawing primitives

    func drawStar(ctx: GraphicsContext, at point: CGPoint,
                  magnitude: Double, isDark: Bool, precomputedColor: Color,
                  altitude: Double = 90,
                  moonBrightness: Double = 0,
                  scintillationTime: Double = 0,
                  starRA: Double = 0) {
        let color = precomputedColor
        let radius = max(0.8, 5 - (magnitude + 1.5) * (4 / 4.5))
        let opacity = isDark ? 1.0 : max(0.1, 0.3 - magnitude * 0.05)
        let brightness = magnitude < 0 ? 1.0 : max(0.6, 1.0 - magnitude * 0.12)
        // 大気消光: 仰角 15° 以下で徐々に減光
        let extinction = altitude < 15 ? max(0, altitude / 15.0) : 1.0
        // 月光減衰: 月が明るいとき暗い星を減光
        let moonDimming = StarMapPalette.moonDimmingFactor(
            moonBrightness: moonBrightness, starMagnitude: magnitude
        )
        // シンチレーション: 明るい星の微小な明滅
        let scintillation = StarMapPalette.scintillation(
            starRA: starRA, magnitude: magnitude, altitude: altitude,
            isDark: isDark, time: scintillationTime
        )

        let finalOpacity = opacity * brightness * extinction * moonDimming * scintillation

        let rect = CGRect(x: point.x - radius, y: point.y - radius,
                          width: radius * 2, height: radius * 2)
        ctx.fill(Circle().path(in: rect),
                 with: .color(color.opacity(finalOpacity)))

        if magnitude < 2.0 {
            let glowR = radius * 3.0
            let glowRect = CGRect(x: point.x - glowR, y: point.y - glowR,
                                  width: glowR * 2, height: glowR * 2)
            ctx.fill(Circle().path(in: glowRect),
                     with: .color(color.opacity(0.12 * (isDark ? 1 : 0.3) * scintillation)))
        }

        if magnitude < 0.5 {
            let outerGlowR = radius * 5.0
            let outerRect = CGRect(x: point.x - outerGlowR, y: point.y - outerGlowR,
                                   width: outerGlowR * 2, height: outerGlowR * 2)
            ctx.fill(Circle().path(in: outerRect),
                     with: .color(color.opacity(0.04 * (isDark ? 1 : 0.2) * scintillation)))
        }
    }

    func drawStarLabel(ctx: GraphicsContext, at point: CGPoint, name: String) {
        ctx.draw(
            Text(name)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.65)),
            at: CGPoint(x: point.x + 7, y: point.y + 5))
    }

    func drawCrosshair(ctx: GraphicsContext, cx: Double, cy: Double) {
        let r: Double = 12
        var path = Path()
        path.move(to: CGPoint(x: cx - r, y: cy))
        path.addLine(to: CGPoint(x: cx + r, y: cy))
        path.move(to: CGPoint(x: cx, y: cy - r))
        path.addLine(to: CGPoint(x: cx, y: cy + r))
        ctx.stroke(path, with: .color(.white.opacity(0.5)), lineWidth: 1)
        let circleR: Double = 5
        ctx.stroke(
            Circle().path(in: CGRect(x: cx - circleR, y: cy - circleR,
                                     width: circleR * 2, height: circleR * 2)),
            with: .color(.white.opacity(0.5)), lineWidth: 1)
    }

    /// 月を描く。`brightLimbScreenAngle`（画面座標で輝面が向く角度, rad）が nil の場合は
    /// 従来どおり満ちていく月は右、欠けていく月は左を光らせる。
    func drawMoon(ctx: GraphicsContext, at point: CGPoint, phase: Double, brightLimbScreenAngle: Double? = nil) {
        let radius: Double = 10
        let rect = CGRect(x: point.x - radius, y: point.y - radius,
                          width: radius * 2, height: radius * 2)
        // 欠け際の暗部（地球照程度にうっすら見せる）
        ctx.fill(Circle().path(in: rect), with: .color(Color(white: 0.35).opacity(0.35)))

        let litPolygon = Self.moonLitPolygon(
            center: point,
            radius: radius,
            phase: phase,
            brightLimbScreenAngle: brightLimbScreenAngle
        )
        if litPolygon.count >= 3 {
            var litPath = Path()
            litPath.move(to: litPolygon[0])
            for vertex in litPolygon.dropFirst() {
                litPath.addLine(to: vertex)
            }
            litPath.closeSubpath()
            ctx.fill(litPath, with: .color(.white.opacity(0.9)))
        }

        let glowR = radius * 1.8
        let glowOpacity = 0.06 * max(0.2, Self.moonIlluminatedFraction(phase: phase))
        ctx.fill(Circle().path(in: CGRect(x: point.x - glowR, y: point.y - glowR,
                                           width: glowR * 2, height: glowR * 2)),
                 with: .color(.white.opacity(glowOpacity)))
    }

    /// 月相（0=新月, 0.25=上弦, 0.5=満月, 0.75=下弦）から輝面比 (0〜1) を返す。
    nonisolated static func moonIlluminatedFraction(phase: Double) -> Double {
        (1 - cos(2 * .pi * phase)) / 2
    }

    /// 月の輝面が画面上で向く角度 (rad, 画面座標: +x から +y（下）方向へ測る) を返す。
    /// - Parameters:
    ///   - zenithAngleDegrees: 天頂方向を 0° とし観測者から見て左回りに測った輝面の向き
    ///     （`MilkyWayCalculator.moonBrightLimbZenithAngle`）。
    ///   - project: 地平座標 (高度・方位角, rad) → 画面座標の投影。
    /// 月の位置から輝面の方向へ少しずらした点を同じ投影で写し、その差分の向きを使う。
    /// 天頂方向の画面上の向きや投影の鏡像・ロールを別途仮定しないため、どの視点・投影でも空の向きと一致する。
    /// 投影できない場合は nil。
    nonisolated static func moonBrightLimbScreenAngle(
        zenithAngleDegrees: Double,
        altitudeDegrees: Double,
        azimuthDegrees: Double,
        project: (_ altitudeRadians: Double, _ azimuthRadians: Double) -> CGPoint?
    ) -> Double? {
        let degreesToRadians = Double.pi / 180
        let offsetDegrees = 0.5
        let theta = zenithAngleDegrees * degreesToRadians
        // 方位角方向の 1° は高度が上がるほど天球上で短くなるため cos(高度) で割る（天頂付近は上限を設ける）
        let azimuthScale = 1 / max(cos(altitudeDegrees * degreesToRadians), 0.05)
        guard let origin = project(altitudeDegrees * degreesToRadians, azimuthDegrees * degreesToRadians) else {
            return nil
        }
        // 輝面側の点が投影できなければ反対側の点から向きを求める
        for sign in [1.0, -1.0] {
            // 観測者から見た左は方位角が減る向き
            let altitude = altitudeDegrees + sign * offsetDegrees * cos(theta)
            let azimuth = azimuthDegrees - sign * offsetDegrees * sin(theta) * azimuthScale
            guard let target = project(altitude * degreesToRadians, azimuth * degreesToRadians) else { continue }
            let dx = Double(target.x - origin.x) * sign
            let dy = Double(target.y - origin.y) * sign
            guard dx * dx + dy * dy > 1e-12 else { continue }
            return atan2(dy, dx)
        }
        return nil
    }

    /// 月の輝面を表す多角形（画面座標）を返す。
    /// `brightLimbScreenAngle`（rad, 画面座標で +x から +y 方向へ測る）を渡すと輝面の縁の中点がその向きになる。
    /// nil の場合は北半球の見え方に合わせ、満ちていく月（phase < 0.5）は右側、欠けていく月は左側が光る。
    /// 欠け際（ターミネーター）は楕円弧で表し、輝面方向の半径は radius × cos(2π·phase)。
    nonisolated static func moonLitPolygon(
        center: CGPoint,
        radius: Double,
        phase: Double,
        brightLimbScreenAngle: Double? = nil,
        segments: Int = 24
    ) -> [CGPoint] {
        let normalizedPhase = phase - floor(phase)
        let fraction = moonIlluminatedFraction(phase: normalizedPhase)
        guard fraction > 0.005, segments > 1 else { return [] }

        // 光っている側: 向きの指定があれば +x 側に作って回転する。
        // 指定がなければ満ちていく月は右 (+1)、欠けていく月は左 (-1)
        let litSide: Double
        if brightLimbScreenAngle != nil {
            litSide = 1
        } else {
            litSide = normalizedPhase < 0.5 ? 1 : -1
        }
        // ターミネーターの x 方向の比率。新月で +1（縁と一致）、上弦/下弦で 0、満月で -1。
        let terminatorScale = cos(2 * .pi * normalizedPhase)

        var points: [CGPoint] = []
        points.reserveCapacity((segments + 1) * 2)
        // 光っている側の縁（上 → 下）
        for step in 0...segments {
            let theta = -Double.pi / 2 + Double.pi * Double(step) / Double(segments)
            points.append(CGPoint(
                x: center.x + litSide * radius * cos(theta),
                y: center.y + radius * sin(theta)
            ))
        }
        // ターミネーター（下 → 上）
        for step in stride(from: segments, through: 0, by: -1) {
            let theta = -Double.pi / 2 + Double.pi * Double(step) / Double(segments)
            points.append(CGPoint(
                x: center.x + litSide * terminatorScale * radius * cos(theta),
                y: center.y + radius * sin(theta)
            ))
        }
        guard let brightLimbScreenAngle else { return points }
        let cosAngle = cos(brightLimbScreenAngle)
        let sinAngle = sin(brightLimbScreenAngle)
        return points.map { point in
            let dx = Double(point.x - center.x)
            let dy = Double(point.y - center.y)
            return CGPoint(
                x: center.x + dx * cosAngle - dy * sinAngle,
                y: center.y + dx * sinAngle + dy * cosAngle
            )
        }
    }

    func drawGalacticCenter(ctx: GraphicsContext, at point: CGPoint) {
        let r: Double = 8
        ctx.fill(
            Ellipse().path(in: CGRect(x: point.x - r*2, y: point.y - r,
                                       width: r*4, height: r*2)),
            with: .color(Color(red: 0.6, green: 0.4, blue: 1.0).opacity(0.25)))
        ctx.fill(
            Circle().path(in: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)),
            with: .color(Color(red: 0.8, green: 0.6, blue: 1.0).opacity(0.85)))
    }

    // MARK: Planet

    func planetColor(name: String) -> Color {
        switch name {
        case "水星": return Color(red: 0.75, green: 0.72, blue: 0.68)
        case "金星": return Color(red: 1.00, green: 0.95, blue: 0.80)
        case "火星": return Color(red: 1.00, green: 0.45, blue: 0.25)
        case "木星": return Color(red: 1.00, green: 0.90, blue: 0.70)
        case "土星": return Color(red: 0.95, green: 0.85, blue: 0.60)
        default:     return .white
        }
    }

    func drawPlanet(ctx: GraphicsContext, at point: CGPoint, planet: PlanetPosition) {
        let color = planetColor(name: planet.name)
        // magnitude → radius (bigger = brighter)
        let mag    = max(-5.5, min(3.0, planet.magnitude))
        let radius = max(2.0, 8.0 - (mag + 2.0) * (5.0 / 5.0))

        // Core disk
        let rect = CGRect(x: point.x - radius, y: point.y - radius,
                          width: radius * 2, height: radius * 2)
        ctx.fill(Circle().path(in: rect), with: .color(color.opacity(0.95)))

        // Glow for bright planets
        if mag < 0 {
            let gr = radius * 3.5
            ctx.fill(
                Circle().path(in: CGRect(x: point.x - gr, y: point.y - gr,
                                          width: gr * 2, height: gr * 2)),
                with: .color(color.opacity(0.15)))
        }

        // Label
        ctx.draw(
            Text(planet.localizedName)
                .font(.system(size: 11))
                .foregroundColor(color.opacity(0.75)),
            at: CGPoint(x: point.x + radius + 5, y: point.y + 4))
    }

    // MARK: Meteor Shower Radiant

    func drawMeteorShowerRadiant(ctx: GraphicsContext, at point: CGPoint, shower: MeteorShower) {
        let color = StarMapPalette.meteorAccent
        let radius: CGFloat = 10
        // 放射アイコン（円 + 矢印風の短線）
        let circleRect = CGRect(x: point.x - radius, y: point.y - radius,
                                width: radius * 2, height: radius * 2)
        ctx.stroke(Circle().path(in: circleRect),
                   with: .color(color.opacity(0.7)), lineWidth: 1.2)
        // 中心点
        ctx.fill(Circle().path(in: CGRect(x: point.x - 2, y: point.y - 2,
                                          width: 4, height: 4)),
                 with: .color(color.opacity(0.9)))
        // 放射線（4方向）
        let rays: [(CGFloat, CGFloat)] = [(0,-1),(0,1),(-1,0),(1,0)]
        for (dx, dy) in rays {
            var ray = Path()
            ray.move(to: CGPoint(x: point.x + dx * (radius + 2),
                                  y: point.y + dy * (radius + 2)))
            ray.addLine(to: CGPoint(x: point.x + dx * (radius + 7),
                                     y: point.y + dy * (radius + 7)))
            ctx.stroke(ray, with: .color(color.opacity(0.6)), lineWidth: 1)
        }
        // ラベル
        ctx.draw(
            Text(shower.localizedName)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(color.opacity(0.85)),
            at: CGPoint(x: point.x + radius + 4, y: point.y + 4))
    }

    // MARK: - Gnomonic Milky Way Band

    /// 天の川バンドを心射図法に描画する。
    /// 各バンドポイント間をトラペゾイドスラブで塗りつぶす。
    func drawGnomonicMilkyWayBand(ctx: GraphicsContext,
                                   project: (Double, Double) -> CGPoint?) {
        let bandPoints = viewModel.milkyWayBandPoints
        guard bandPoints.count > 1 else { return }

        // マルチレイヤー定義: (幅倍率, 不透明度倍率)
        // 外側から描画し、中心ほど狭く明るくすることでガウシアン的フォールオフを再現
        let layers: [(widthScale: Double, opacityScale: Double)] = [
            (1.4, 0.25),   // 外側グロー — 広く薄い
            (1.0, 0.50),   // 中間層
            (0.6, 1.00),   // コア — 狭く明るい
        ]

        // 天の川レイヤーをサブコンテキストに描画し、ブラーで柔らかくする
        var milkyWayCtx = ctx
        milkyWayCtx.addFilter(.blur(radius: 6))

        // 銀経 355° → 0°（銀河中心隣接）の区間も含め、銀経で隣接する点同士だけをつなぐ。
        let segmentPairs = StarMapComputation.milkyWayBandSegmentIndexPairs(for: bandPoints)

        for layer in layers {
            for pair in segmentPairs {
                let bp0 = bandPoints[pair.start]
                let bp1 = bandPoints[pair.end]

                // ラップアラウンドの不連続をスキップ
                let azDiff = atan2(
                    sin((bp0.az - bp1.az) * .pi / 180),
                    cos((bp0.az - bp1.az) * .pi / 180)
                ) * 180 / .pi
                guard abs(azDiff) < 40 else { continue }

                let a0 = bp0.alt * .pi / 180
                let z0 = bp0.az * .pi / 180
                let h0 = bp0.halfH * .pi / 180 * layer.widthScale
                let a1 = bp1.alt * .pi / 180
                let z1 = bp1.az * .pi / 180
                let h1 = bp1.halfH * .pi / 180 * layer.widthScale

                guard let p0Top = project(a0 + h0, z0),
                      let p0Bot = project(a0 - h0, z0),
                      let p1Top = project(a1 + h1, z1),
                      let p1Bot = project(a1 - h1, z1) else { continue }

                // スクリーン上の大きなジャンプをスキップ（投影の不連続対策）
                let maxJump: Double = 800
                guard abs(p0Top.x - p1Top.x) < maxJump,
                      abs(p0Top.y - p1Top.y) < maxJump,
                      abs(p0Bot.x - p1Bot.x) < maxJump,
                      abs(p0Bot.y - p1Bot.y) < maxJump else { continue }

                var slab = Path()
                slab.move(to: p0Top)
                slab.addLine(to: p1Top)
                slab.addLine(to: p1Bot)
                slab.addLine(to: p0Bot)
                slab.closeSubpath()

                // 銀河中心（銀経 0°/360°）からの角距離で輝度を計算
                let lDeg = bp0.li <= 180 ? bp0.li : 360 - bp0.li
                let tCenter = 1.0 - lDeg / 180.0  // 1.0 = 銀河中心, 0.0 = 反銀心

                // 銀河中心付近: 暖色（淡いアンバー/ゴールド）
                // 反銀心付近: 冷色（淡いブルー）
                let red   = 0.55 + 0.30 * tCenter
                let green = 0.55 + 0.15 * tCenter
                let blue  = 0.85 - 0.35 * tCenter
                let slabColor = Color(red: red, green: green, blue: blue)

                // 銀河中心方向を明るくし、反銀心は暗くする
                let brightnessBoost = 0.6 + 0.4 * tCenter
                let baseOpacity = 0.08 * layer.opacityScale * brightnessBoost

                milkyWayCtx.fill(slab, with: .color(slabColor.opacity(baseOpacity)))
            }
        }
    }

    // MARK: - Gnomonic Terrain Silhouette

    /// 地形シルエットを心射図法に描画する。
    /// カメラの FOV より広い方位角範囲をスイープし、投影可能な点のみ描画する。
    func drawGnomonicTerrainSilhouette(ctx: GraphicsContext,
                                        project: (Double, Double) -> CGPoint?,
                                        centerAz: Double, fov: Double,
                                        size: CGSize,
                                        terrain: TerrainProfile) {
        let sweepRange = max(fov * 1.5, 90.0)
        let steps = 120

        var ridgePoints: [CGPoint] = []
        ridgePoints.reserveCapacity(steps + 1)

        for i in 0...steps {
            let fraction = Double(i) / Double(steps)
            var az = centerAz + (fraction - 0.5) * sweepRange
            az = az.truncatingRemainder(dividingBy: 360)
            if az < 0 { az += 360 }

            let hAngle = terrain.horizonAngle(forAzimuth: az)
            let altRad = max(hAngle, 0) * .pi / 180
            let azRad = (centerAz + (fraction - 0.5) * sweepRange) * .pi / 180

            if let pt = project(altRad, azRad) {
                guard pt.x > -200 && pt.x < size.width + 200 &&
                      pt.y > -200 && pt.y < size.height + 200 else { continue }
                ridgePoints.append(pt)
            }
        }

        guard ridgePoints.count > 1 else { return }

        var path = Path()
        path.move(to: ridgePoints[0])
        for i in 1..<ridgePoints.count {
            path.addLine(to: ridgePoints[i])
        }
        path.addLine(to: CGPoint(x: ridgePoints[ridgePoints.count - 1].x, y: size.height + 10))
        path.addLine(to: CGPoint(x: ridgePoints[0].x, y: size.height + 10))
        path.closeSubpath()
        ctx.fill(
            path,
            with: .color(
                horizonOverlayStyle.terrainFillColor.opacity(horizonOverlayStyle.terrainFillOpacity)
            )
        )

        var ridgePath = Path()
        ridgePath.move(to: ridgePoints[0])
        for i in 1..<ridgePoints.count {
            ridgePath.addLine(to: ridgePoints[i])
        }
        ctx.stroke(ridgePath,
                   with: .color(horizonOverlayStyle.terrainStrokeColor),
                   lineWidth: 1.5)
    }
}
