import SwiftUI

struct CollapsibleECGSection: View {

    let title: String
    let points: [ECGPoint]
    let markerPoints: [ECGPoint]
//    let peakTimes: [Double]?
    @Binding var isExpanded: Bool
    let mode: ECGChartView.Mode
    var height: CGFloat = 220
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            DisclosureGroup(isExpanded: $isExpanded) {

                // CONTENT
                if points.isEmpty {
                    Text("Нет данных для отображения")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ECGChartView(
                        points: points,
                        mode: mode,
                        markerPoints: markerPoints
                    )
                    .frame(height: height)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        // ВАЖНО: чтобы график не перехватывал касания карточки
                        .allowsHitTesting(false)
                }

            } label: {
                // HEADER
                HStack {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                }
                // делаем кликабельной всю строку
                .contentShape(Rectangle())
                // фикс “перекрытия” (если вдруг график рисуется выше)
                .zIndex(10)
                .padding(.vertical, 4)
            }
            .disclosureGroupStyle(.automatic)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemGray6))
        )
    }
}
