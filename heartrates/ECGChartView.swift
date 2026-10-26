//
//  ECGChartView.swift
//  heartrates
//
//  Created by mazzahaker on 17/8/25.
//

import SwiftUI

struct ECGChartView: View {
    enum Mode { case last10s, full }

    let points: [ECGPoint]
    let mode: Mode
//    let peakTimes: [Double]
    let markerPoints: [ECGPoint]
    // окно просмотра (сек) — актуально для .last10s
    @State private var windowStart: Double = 0
    private let windowWidth: Double = 10.0

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let rect = geo.frame(in: .local)
                ZStack {
                    GridBackground()
                    ChartLayer(
                        points: points,
                        markerPoints: markerPoints,
                        mode: mode,
                        rect: rect,
                        windowStart: currentWindowStart(duration: duration),
                        windowWidth: windowWidth
                    )
                }
            }
            .frame(height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())

            if mode == .last10s, duration > windowWidth {
                OverviewStrip(points: points,
                              windowStart: currentWindowStart(duration: duration),
                              windowWidth: windowWidth,
                              onDrag: { newStart in
                                  windowStart = clamp(newStart, 0, max(0, duration - windowWidth))
                              })
                .frame(height: 44)
                .padding(.horizontal, 4) // больше не клипуем снаружи — фон рисуем внутри Canvas
            }
        }
        .onAppear {
            if mode == .last10s {
                windowStart = max(0, duration - windowWidth) // стартуем с конца
            }
        }
        .animation(.easeOut(duration: 0.2), value: windowStart)
    }

    private var duration: Double { points.last?.t ?? 0 }

    private func currentWindowStart(duration: Double) -> Double {
        guard mode == .last10s else { return 0 }
        return clamp(windowStart, 0, max(0, duration - windowWidth))
    }
    private func clamp(_ x: Double, _ a: Double, _ b: Double) -> Double { min(max(x, a), b) }
}

// MARK: - Сетка (экранные 1/5 мм)

private struct GridBackground: View {
    var body: some View {
        GeometryReader { geo in
            let rect = geo.frame(in: .local)
            Canvas { ctx, size in
                let mm1: CGFloat = 5

                var x: CGFloat = 0; var i = 0
                while x <= size.width + 0.5 {
                    let isBig = i % 5 == 0
                    let color = isBig ? UIColor(red: 1, green: 0.32, blue: 0.32, alpha: 0.9)
                                      : UIColor(white: 0.86, alpha: 1.0)
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: 0))
                    p.addLine(to: CGPoint(x: x, y: size.height))
                    ctx.stroke(p, with: .color(Color(color)), lineWidth: 0.5)
                    x += mm1; i += 1
                }

                var y: CGFloat = 0; var j = 0
                while y <= size.height + 0.5 {
                    let isBig = j % 5 == 0
                    let color = isBig ? UIColor(red: 1, green: 0.32, blue: 0.32, alpha: 0.9)
                                      : UIColor(white: 0.86, alpha: 1.0)
                    var p = Path()
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: size.width, y: y))
                    ctx.stroke(p, with: .color(Color(color)), lineWidth: 0.5)
                    y += mm1; j += 1
                }

                var border = Path(roundedRect: rect, cornerRadius: 12)
                ctx.stroke(border, with: .color(.black.opacity(0.08)), lineWidth: 0.8)
            }
        }
    }
}

// MARK: - Основной слой (детренд + центрирование + импульс 1 mV)

private struct ChartLayer: View {
    let points: [ECGPoint]
    let markerPoints: [ECGPoint]
//    let peakTimes: [Double]
    let mode: ECGChartView.Mode
    let rect: CGRect
    let windowStart: Double
    let windowWidth: Double

    var body: some View {
        Canvas { ctx, size in
            guard points.count > 1 else { return }

            let t0: Double, t1: Double
            if mode == .last10s {
                t0 = windowStart; t1 = windowStart + windowWidth
            } else {
                t0 = 0; t1 = points.last?.t ?? 0
            }
            guard t1 > t0 else { return }

            let slice = points.inTimeRange(t0: t0, t1: t1)
            guard slice.count > 1 else { return }

            let xScale = size.width / CGFloat(t1 - t0)

            // Детренд скользящим средним ~0.5 c (устранение дрейфа/DC)
            let sr = estimateSampleRate(slice: slice)
            let winSamples = max(1, Int((sr * 0.5).rounded()))
            let detrended = detrend(slice, window: winSamples) // [Double] значений mV без DC

            // Масштаб по Y + 15% «воздуха» по краям
            let pad: CGFloat = 12
            let maxAbs = (detrended.map { abs($0) }.max() ?? 1.0)
            let yScale = ((size.height/2) - pad) / (CGFloat(maxAbs) * 1.15)
            let midY = size.height / 2

            // Калибровочный импульс 1 mV
            drawCalibrationPulse(ctx: &ctx,
                                 heightMV: 1.0, widthSec: 0.2,
                                 xScale: xScale, yScale: yScale, midY: midY)

            // Линия ЭКГ
            var path = Path()
            var started = false
            for (idx, p) in slice.enumerated() {
                let x = CGFloat(p.t - t0) * xScale
                let y = midY - CGFloat(detrended[idx]) * yScale
                let yClamped = min(max(y, pad), size.height - pad)
                if !started { path.move(to: CGPoint(x: x, y: yClamped)); started = true }
                else { path.addLine(to: CGPoint(x: x, y: yClamped)) }
            }
            ctx.stroke(path, with: .color(.blue), lineWidth: 1.25)
            // Маркеры R-пиков на filtered signal
            let visibleMarkers = markerPoints.filter { $0.t >= t0 && $0.t <= t1 }

            func nearestIndexByTime(_ pts: [ECGPoint], _ t: Double) -> Int? {
                guard !pts.isEmpty else { return nil }
                var best = 0
                var bestD = abs(pts[0].t - t)

                for i in 1..<pts.count {
                    let d = abs(pts[i].t - t)
                    if d < bestD {
                        bestD = d
                        best = i
                    }
                }
                return best
            }

            for marker in visibleMarkers {
                guard let iPeak = nearestIndexByTime(slice, marker.t) else { continue }

                let p = slice[iPeak]
                let x = CGFloat(p.t - t0) * xScale
                let y = midY - CGFloat(detrended[iPeak]) * yScale
                let yClamped = min(max(y, pad), size.height - pad)

                let r: CGFloat = 4.0
                let markerRect = CGRect(x: x - r, y: yClamped - r, width: 2 * r, height: 2 * r)
                ctx.fill(Path(ellipseIn: markerRect), with: .color(.red.opacity(0.9)))
            }
//            let visiblePeakTimes = peakTimes.filter { $0 >= t0 && $0 <= t1 }
//
//            func nearestIndexByTime(_ pts: [ECGPoint], _ t: Double) -> Int? {
//                guard !pts.isEmpty else { return nil }
//                var best = 0
//                var bestD = abs(pts[0].t - t)
//
//                for i in 1..<pts.count {
//                    let d = abs(pts[i].t - t)
//                    if d < bestD {
//                        bestD = d
//                        best = i
//                    }
//                }
//                return best
//            }
//
//            func localPeakIndex(near t: Double) -> Int? {
//                guard let idx0 = nearestIndexByTime(slice, t) else { return nil }
//
//                let halfWindowSec = 0.05
//                let halfN = max(1, Int(round(halfWindowSec * sr)))
//
//                let i1 = max(0, idx0 - halfN)
//                let i2 = min(slice.count - 1, idx0 + halfN)
//
//                var bestI = idx0
//                var bestV = detrended[idx0]
//
//                for i in i1...i2 {
//                    if detrended[i] > bestV {
//                        bestV = detrended[i]
//                        bestI = i
//                    }
//                }
//                return bestI
//            }
//
//            for tPeak in visiblePeakTimes {
//                guard let iPeak = localPeakIndex(near: tPeak) else { continue }
//
//                let p = slice[iPeak]
//                let x = CGFloat(p.t - t0) * xScale
//                let y = midY - CGFloat(detrended[iPeak]) * yScale
//                let yClamped = min(max(y, pad), size.height - pad)
//
//                let r: CGFloat = 4.0
//                let markerRect = CGRect(x: x - r, y: yClamped - r, width: 2 * r, height: 2 * r)
//                ctx.fill(Path(ellipseIn: markerRect), with: .color(.red.opacity(0.9)))
//            }
        }
    }

    private func drawCalibrationPulse(ctx: inout GraphicsContext,
                                      heightMV: Double,
                                      widthSec: Double,
                                      xScale: CGFloat,
                                      yScale: CGFloat,
                                      midY: CGFloat)
    {
        let h = CGFloat(heightMV) * yScale
        let w = CGFloat(widthSec) * xScale
        let x0: CGFloat = 10
        let y0 = midY

        var p = Path()
        p.move(to: CGPoint(x: x0, y: y0))
        p.addLine(to: CGPoint(x: x0, y: y0 - h))
        p.addLine(to: CGPoint(x: x0 + w, y: y0 - h))
        p.addLine(to: CGPoint(x: x0 + w, y: y0))
        ctx.stroke(p, with: .color(.red), lineWidth: 1.0)
    }

    // Оценка частоты дискретизации (медианный шаг)
    private func estimateSampleRate(slice: [ECGPoint]) -> Double {
        guard slice.count > 2 else { return 512 } // дефолт
        var dts: [Double] = []; dts.reserveCapacity(slice.count - 1)
        for i in 1..<slice.count { dts.append(slice[i].t - slice[i-1].t) }
        let mdt = dts.sorted()[dts.count/2]
        return mdt > 0 ? 1.0 / mdt : 512
    }

    // Скользящее среднее и вычитание (двустороннее)
    private func detrend(_ slice: [ECGPoint], window: Int) -> [Double] {
        let n = slice.count
        let w = max(1, window)
        var out = Array(repeating: 0.0, count: n)
        var prefix = [0.0]; prefix.reserveCapacity(n+1)
        for p in slice { prefix.append(prefix.last! + p.mV) }
        for i in 0..<n {
            let a = max(0, i - w/2)
            let b = min(n - 1, i + w/2)
            let sum = prefix[b+1] - prefix[a]
            let avg = sum / Double(b - a + 1)
            out[i] = slice[i].mV - avg
        }
        return out
    }
}

// MARK: - Мини-обзор (фон/скругления внутри Canvas, окно строго clamp’ится)

private struct OverviewStrip: View {
    let points: [ECGPoint]
    var windowStart: Double
    let windowWidth: Double
    let onDrag: (Double) -> Void

    @GestureState private var dragDX: CGFloat = 0
    @State private var startAtGestureBegan: Double = 0

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let insetX: CGFloat = 6
            let insetY: CGFloat = 6
            let inner = CGRect(x: insetX, y: insetY,
                               width: size.width - insetX*2,
                               height: size.height - insetY*2)

            Canvas { ctx, _ in
                // фон со скруглением — внутри Canvas, чтобы ничего не резалось
                let bg = Path(roundedRect: inner, cornerRadius: 8)
                ctx.fill(bg, with: .color(.gray.opacity(0.07)))
                ctx.stroke(bg, with: .color(.black.opacity(0.06)), lineWidth: 0.8)

                guard points.count > 1 else { return }
                let duration = points.last?.t ?? 0
                guard duration > 0 else { return }

                let xScale = inner.width / CGFloat(duration)
                let maxAbs = points.map { abs($0.mV) }.max() ?? 1
                let yScale = (inner.height/2 - 4) / CGFloat(maxAbs)
                let midY = inner.midY

                var p = Path(); var started = false
                for pt in points {
                    let x = inner.minX + CGFloat(pt.t) * xScale
                    let y = midY - CGFloat(pt.mV) * yScale
                    if !started { p.move(to: CGPoint(x: x, y: y)); started = true }
                    else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
                ctx.stroke(p, with: .color(.blue.opacity(0.7)), lineWidth: 0.9)

                // окно просмотра — строго внутри inner
                let ws = clamp(windowStart, 0, max(0, duration - windowWidth))
                let startX = inner.minX + CGFloat(ws / duration) * inner.width
                let w = CGFloat(windowWidth / duration) * inner.width
                let clampedStartX = min(max(startX, inner.minX), inner.maxX - w)
                let winRect = CGRect(x: clampedStartX, y: inner.minY, width: w, height: inner.height)

                ctx.fill(Path(roundedRect: winRect.insetBy(dx: 2, dy: 2), cornerRadius: 4),
                         with: .color(.blue.opacity(0.08)))
                ctx.stroke(Path(roundedRect: winRect.insetBy(dx: 1, dy: 1), cornerRadius: 4),
                           with: .color(.blue), lineWidth: 1)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($dragDX) { value, state, _ in
                        state = value.translation.width
                        let duration = points.last?.t ?? 0
                        guard duration > windowWidth else { return }
                        let pxToSec = duration / inner.width
                        let proposed = startAtGestureBegan + Double(state) * pxToSec
                        onDrag(proposed)
                    }
                    .onChanged { value in
                        if value.startLocation == value.location {
                            startAtGestureBegan = windowStart
                        }
                    }
            )
        }
        .frame(maxWidth: .infinity)
    }

    private func clamp(_ x: Double, _ a: Double, _ b: Double) -> Double { min(max(x, a), b) }
}

// MARK: - Утилиты

private extension Array where Element == ECGPoint {
    func inTimeRange(t0: Double, t1: Double) -> [ECGPoint] {
        guard let s = firstIndex(where: { $0.t >= t0 }) else { return [] }
        var e = s
        while e < count && self[e].t <= t1 { e += 1 }
        return Array(self[s..<e])
    }
}
