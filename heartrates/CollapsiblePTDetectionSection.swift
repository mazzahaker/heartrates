import SwiftUI

struct CollapsiblePTDetectionSection: View {

    let title: String
    let mwi: [ECGPoint]
    let thr: Double
    let peakTimes: [Double]          // секунды
    @Binding var isExpanded: Bool
    let mode: ECGChartView.Mode
    var height: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            DisclosureGroup(isExpanded: $isExpanded) {

                if mwi.isEmpty {
                    Text("Нет данных для отображения")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    let viewMWI = sliceByMode(points: mwi, mode: mode)
                    let viewPeaks = slicePeaksByMode(peakTimes: peakTimes, points: mwi, mode: mode)

                    PTDetectionChartView(
                        mwi: viewMWI,
                        thr: thr,
                        peakTimes: viewPeaks
                    )
                    .frame(height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .allowsHitTesting(false)
                }

            } label: {
                HStack {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .contentShape(Rectangle())
                .zIndex(10)
                .padding(.vertical, 4)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemGray6))
        )
    }
}
private func windowSec(for mode: ECGChartView.Mode) -> Double? {
    switch mode {
    case .last10s: return 5.0   // у тебя кнопка "5 с" тегается last10s — оставляю как есть
    case .full:    return nil
    }
}

private func sliceByMode(points: [ECGPoint], mode: ECGChartView.Mode) -> [ECGPoint] {
    guard let w = windowSec(for: mode), let tEnd = points.last?.t else { return points }
    let t0 = max(0, tEnd - w)
    return points.filter { $0.t >= t0 }
}

private func slicePeaksByMode(peakTimes: [Double], points: [ECGPoint], mode: ECGChartView.Mode) -> [Double] {
    guard let w = windowSec(for: mode), let tEnd = points.last?.t else { return peakTimes }
    let t0 = max(0, tEnd - w)
    return peakTimes.filter { $0 >= t0 }
}
