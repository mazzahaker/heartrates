import SwiftUI

struct PTDetectionChartView: View {

    let mwi: [ECGPoint]
    let thr: Double
    let peakTimes: [Double]   // времена R-пиков в секундах

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            let xs = mwi.map { $0.t }
            let ys = mwi.map { $0.mV }

            let minX = xs.min() ?? 0
            let maxX = xs.max() ?? 1

            let minY0 = ys.min() ?? 0
            let maxY0 = ys.max() ?? 1

            // учитываем порог, чтобы линия порога не “вылезала” за график
            let minY = min(minY0, thr)
            let maxY = max(maxY0, thr)

            let dx = (maxX - minX)
            let dy = (maxY - minY)

            // ВАЖНО: без guard-return
            let xMap: (Double) -> CGFloat = { x in
                dx <= 0 ? 0 : CGFloat((x - minX) / dx) * w
            }
            let yMap: (Double) -> CGFloat = { y in
                dy <= 0 ? h/2 : (h - CGFloat((y - minY) / dy) * h)
            }

            ZStack {

                // 1) линия MWI
                Path { p in
                    guard let first = mwi.first else { return }
                    p.move(to: CGPoint(x: xMap(first.t), y: yMap(first.mV)))
                    for pt in mwi.dropFirst() {
                        p.addLine(to: CGPoint(x: xMap(pt.t), y: yMap(pt.mV)))
                    }
                }
                .stroke(.primary, lineWidth: 1.2)

                // 2) линия порога
                Path { p in
                    p.move(to: CGPoint(x: 0, y: yMap(thr)))
                    p.addLine(to: CGPoint(x: w, y: yMap(thr)))
                }
                .stroke(.red.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))

                // 3) маркеры R-пиков
                ForEach(peakTimes, id: \.self) { t in
                    if let peakPt = localMWIPeak(near: t, in: mwi) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 7, height: 7)
                            .position(x: xMap(peakPt.t), y: yMap(peakPt.mV))
                    } else {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 7, height: 7)
                            .position(x: xMap(t), y: yMap(thr))
                    }
                }
            }
        }
    }

    private func localMWIPeak(near t: Double, in pts: [ECGPoint]) -> ECGPoint? {
        guard !pts.isEmpty else { return nil }

        guard let idx0 = nearestIndexByTime(pts, t) else { return nil }

        let fs = estimateFs(from: pts)
        let halfWindowSec = 0.06
        let halfN = max(1, Int(round(halfWindowSec * fs)))

        let i1 = max(0, idx0 - halfN)
        let i2 = min(pts.count - 1, idx0 + halfN)

        var bestI = idx0
        var bestV = pts[idx0].mV

        if i1 <= i2 {
            for i in i1...i2 {
                let v = pts[i].mV
                if v > bestV {
                    bestV = v
                    bestI = i
                }
            }
        }

        return pts[bestI]
    }
    
    private func estimateFs(from pts: [ECGPoint]) -> Double {
        guard pts.count > 1 else { return 512.0 }

        let n = min(pts.count - 1, 1024)
        var sumDt = 0.0
        for i in 1...n {
            sumDt += (pts[i].t - pts[i - 1].t)
        }

        let dt = sumDt / Double(n)
        if dt <= 0 { return 512.0 }
        return 1.0 / dt
    }
    
    private func nearestIndexByTime(_ pts: [ECGPoint], _ t: Double) -> Int? {
        guard !pts.isEmpty else { return nil }
        var best = 0
        var bestD = abs(pts[0].t - t)
        for i in 1..<pts.count {
            let d = abs(pts[i].t - t)
            if d < bestD { bestD = d; best = i }
        }
        return best
    }
}
