//
//  XIAOView.swift
//  heartrates
//
//  Created by mazzahaker on 3/10/25.
//
import SwiftUI
import UniformTypeIdentifiers

struct XIAOView: View {
    @ObservedObject var xiao: XIAOManager

    @State private var pdfDoc: PDFFile?
    @State private var showExporter = false
    @State private var showDetect = false
    @State private var xiaoMode: ECGChartView.Mode = .last10s
    @State private var showRaw = false
    @State private var showFiltered = false
    @State private var showPT = false
    @State private var showSignalDetect = false
    private var xiaoSignalMarkerPoints: [ECGPoint] {
        makeMarkerPoints(from: xiao.xiaoSignalPeakIndices, in: xiao.xiaoFilteredPoints)
    }
    private func makeMarkerPoints(from indices: [Int], in points: [ECGPoint]) -> [ECGPoint] {
        guard !points.isEmpty, !indices.isEmpty else { return [] }

        return indices.compactMap { idx in
            guard idx >= 0, idx < points.count else { return nil }
            return points[idx]
        }
    }
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    Text("XIAO / MAX30003")
                        .font(.title2.bold())
                        .padding(.top, 8)

                    let hasData = !xiao.xiaoFilteredPoints.isEmpty
                               || !xiao.xiaoRawPoints.isEmpty
                               || !xiao.xiaoPTPoints.isEmpty

                    if !hasData {
                        Text("Нет данных. Подключитесь к устройству и начните запись.")
                            .foregroundStyle(.secondary)
                    } else {
                        
                        Picker("", selection: $xiaoMode) {
                            Text("10 c").tag(ECGChartView.Mode.last10s)
                            Text("Вся запись").tag(ECGChartView.Mode.full)
                        }
                        .pickerStyle(.segmented)
                        
                        CollapsibleECGSection(
                            title: "1) Сырые данные (RAW)",
                            points: xiao.xiaoRawPoints,
                            markerPoints: [],
                            isExpanded: $showRaw,
                            mode: xiaoMode,
                            height: 220
                        )
                        
                        CollapsibleECGSection(
                            title: "2) Отфильтрованные данные",
                            points: xiao.xiaoFilteredPoints,
                            markerPoints: [],
                            isExpanded: $showFiltered,
                            mode: xiaoMode,
                            height: 220
                        )
                        
                        CollapsibleECGSection(
                            title: "3) Метод Пан–Томпкинса (MWI)",
                            points: xiao.xiaoPTPoints,
                            markerPoints: [],
                            isExpanded: $showPT,
                            mode: xiaoMode,
                            height: 220
                        )
                        CollapsiblePTDetectionSection(
                            title: "4) Детектирование (MWI + порог + R-пики)",
                            mwi: xiao.xiaoDetMWIPoints,
                            thr: xiao.xiaoDetThr,
                            peakTimes: xiao.xiaoDetPeakTimes,
                            isExpanded: $showDetect,
                            mode: xiaoMode,
                            height: 220
                        )
                        CollapsibleECGSection(
                            title: "5) Детектирование по сигналу",
                            points: xiao.xiaoFilteredPoints,
                            markerPoints: xiaoSignalMarkerPoints,
                            isExpanded: $showSignalDetect,
                            mode: xiaoMode,
                            height: 220
                        )
                        // Метрики считаем по filtered (если пусто — по last)
                        let basePoints = !xiao.xiaoFilteredPoints.isEmpty ? xiao.xiaoFilteredPoints : xiao.xiaoLast
                        let fsFull = max(1.0, xiao.xiaoFs)
                        
                        let aOpt = ECGAnalysis.compute(points: basePoints)
                        
                        let rPeaksSec = xiao.xiaoDetPeakTimes
                        let d = ECGAnalysis.deriveFromRPeaks(rPeaksSec: rPeaksSec)
                        let rrAllMs = d.rrAllMs
                        let rrMs = d.rrMs

                        let meanRR = d.meanRRms ?? .nan
                        let meanHR = d.meanHR.map { Int(round($0)) } ?? 0

                        let sdnnVal  = d.sdnnMs ?? 0
                        let rmssdVal = d.rmssdMs ?? 0
                        let rrSec = rrMs.map { $0 / 1000.0 }
                        let hrv = d.hrv
                        let si = d.stressIndex ?? .nan
                        
                        let rUsed  = rrMs.isEmpty ? 0 : (rrMs.count + 1)
                        let rFound = rPeaksSec.count
                        let rrAllCount = d.rrAllMs.count                 // всего RR (если бы не фильтр)
                        let rrUsedCount = d.rrMs.count                   // RR после фильтра
                        let nnPairs = max(0, rrUsedCount - 1)          // пары для NN50/pNN50 (разности соседних RR)
                        
                        if rFound >= 3 {
                            VStack(alignment: .leading, spacing: 8) {

                                HStack {
                                    Text("Средний ЧСС: \(meanHR) bpm")
                                        .font(.headline)
                                    Spacer()
                                    Text(String(format: "Частота: %.0f Гц", fsFull))
                                        .font(.subheadline)
                                    Text(xiao.xiaoSNRdB.map { String(format: "SNR: %.1f dB", $0) } ?? "SNR: —")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("R-пиков (найдено): \(rFound)")
                                        Spacer()
                                        Text(String(format: "SDNN: %.0f мс", sdnnVal))
                                        Spacer()
                                        Text(String(format: "RMSSD: %.0f мс", rmssdVal))
                                    }
                                    HStack {
                                        Text("RR: \(rrUsedCount) из \(rrAllCount), пары: \(nnPairs)")
                                        Spacer()
                                        Text(String(format: "pNN50: %.1f %%", hrv?.pnn50 ?? 0))
                                    }
                                }
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                                if let m = hrv {
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Text("HRmin: \(String(format: "%.0f", m.hrMin)) bpm")
                                            Spacer()
                                            Text("HRmax: \(String(format: "%.0f", m.hrMax)) bpm")
                                        }

                                        HStack {
                                            Text("ΔRR: \(String(format: "%.0f", m.deltaRR * 1000.0)) мс")
                                            Spacer()
                                            Text("NN50: \(m.nn50)")
                                        }

                                        HStack {
                                            Text("pNN50: \(String(format: "%.1f", m.pnn50)) %")
                                            Spacer()
                                            Text("CV: \(String(format: "%.1f", m.cv)) %")
                                        }

                                        HStack {
                                            Text("NArr: \(String(format: "%.1f", m.narr)) %")
                                            Spacer()
                                            Text(si.isFinite ? String(format: "Стресс: %.0f", si) : "Стресс: —")
                                        }

                                        HStack {
                                            Text(meanRR.isFinite ? "Средний RR: \(Int(round(meanRR))) мс" : "Средний RR: —")
                                            Spacer()
                                        }
                                    }
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                }

                                if let it = d.interpretation {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(it.hrMinStatus)
                                        Text(it.hrMaxStatus)
                                        Text(it.deltaRRStatus)
                                        Text(it.sdnnStatus)
                                        Text(it.rmssdStatus)
                                        Text(it.pnn50Status)
                                        Text(it.cvStatus)
                                        Text(it.narrStatus)
                                        Text(it.stress)
                                    }
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                }

                                Button("Экспорт в PDF") {
                                    let filtered = !xiao.xiaoFilteredPoints.isEmpty ? xiao.xiaoFilteredPoints : basePoints

                                    guard filtered.count > 1 else {
                                        xiao.xiaoStatus = "PDF: нет данных"
                                        return
                                    }

                                    let analytics = aOpt ?? ECGAnalysis.compute(points: filtered)
                                    let fs = max(1.0, xiao.xiaoFs)
                                    let pdfAnalytics = ECGAnalysis.analyticsFromRPeaks(
                                        sampleRate: fs,
                                        rPeaksSec: xiao.xiaoDetPeakTimes
                                    )

                                    if let _ = analytics,
                                       let data = PDFExporter.makePDF(
                                           raw: xiao.xiaoRawPoints,
                                           filtered: filtered,
                                           mwi: xiao.xiaoPTPoints,
                                           detMWI: xiao.xiaoDetMWIPoints,
                                           detThr: xiao.xiaoDetThr,
                                           detPeakTimes: xiao.xiaoDetPeakTimes,
                                           signalMarkerPoints: xiaoSignalMarkerPoints,
                                           analytics: pdfAnalytics,
                                           source: .xiao
                                       ),
                                       !data.isEmpty {
                                        pdfDoc = PDFFile(data: data)
                                        showExporter = true
                                        xiao.xiaoStatus = "PDF готов"
                                    } else {
                                        xiao.xiaoStatus = "PDF: ошибка генерации"
                                    }
                                }
                                .buttonStyle(.bordered)
                                .fileExporter(
                                    isPresented: $showExporter,
                                    document: pdfDoc,
                                    contentType: .pdf,
                                    defaultFilename: "ECG_XIAO"
                                ) { result in
                                    switch result {
                                    case .success(let url):
                                        xiao.xiaoStatus = "PDF сохранён: \(url.lastPathComponent)"
                                    case .failure(let err):
                                        xiao.xiaoStatus = "Экспорт: \(err.localizedDescription)"
                                    }
                                }
                            }
                        }else {
                            Text("Недостаточно R-пиков для анализа (нужно ≥ 3).")
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 12) {
                        Button("Подключиться") { xiao.connect() }
                            .buttonStyle(.bordered)

                        Button("Начать 30 с") { xiao.startCapture5s() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!xiao.isReady)

                        Button("Из файла") { xiao.loadFromFileXIAO() }
                            .buttonStyle(.bordered)

                        Button("Очистить") { xiao.reset() }
                            .buttonStyle(.bordered)
                    }

                    Text(xiao.xiaoStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if !xiao.xiaoLast.isEmpty {
                        Text("Fs (оценка): \(Int(ECGAnalysis.estimateFs(xiao.xiaoLast))) Гц")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .padding(.bottom, 24) // чтобы низ не “упирался” в таббар
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
private struct AnalyticsBlockView: View {
    let analytics: ECGAnalytics
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let cls = analytics.classification {
                Text(cls).font(.headline)
            }
            HStack {
                Text("Средний ЧСС: \(analytics.avgHR.map{ String(format: "%.0f", $0) } ?? "—") bpm")
                Spacer()
                Text("Fs: \(Int(analytics.sampleRate)) Гц")
            }
            HStack {
                Text("R-пиков: \(analytics.rPeaksSec.count)")
                Spacer()
                Text("SDNN: \(analytics.sdnn.map{ String(format: "%.0f", $0) } ?? "—") мс")
                Spacer()
                Text("RMSSD: \(analytics.rmssd.map{ String(format: "%.0f", $0) } ?? "—") мс")
            }
            .foregroundStyle(.secondary)
        }
    }
}

// ===== локальные хелперы ТОЛЬКО для вкладки XIAO =====

private func sdnn(_ rrMs: [Double]) -> Double {
    guard rrMs.count > 1 else { return 0 }
    let mean = rrMs.reduce(0,+) / Double(rrMs.count)
    let varSum = rrMs.reduce(0) { $0 + pow($1 - mean, 2) }
    return sqrt(varSum / Double(rrMs.count - 1))
}

private func rmssd(_ rrMs: [Double]) -> Double {
    guard rrMs.count > 1 else { return 0 }
    var diffs = [Double]()
    diffs.reserveCapacity(rrMs.count - 1)
    for i in 1..<rrMs.count { diffs.append(rrMs[i] - rrMs[i-1]) }
    let meanSq = diffs.reduce(0) { $0 + $1*$1 } / Double(diffs.count)
    return sqrt(meanSq)
}

// Очень простая R-детекция: высокочастотная огибающая + адаптивный порог + рефрактерный период
private func detectRPeaks(signal x: [Double], fs: Double) -> [Int] {
    guard !x.isEmpty else { return [] }

    // 1) Высокочастотный компонент (удалим DC/медленное)
    let hp = highpassMovingAvg(x, window: max(1, Int(fs * 0.2)))   // ≈0.5 Гц

    // 2) «Энергия» (квадрат) + сглаживание коротким окном
    let energy = hp.map { $0*$0 }
    let env = movingAvg(energy, window: max(1, Int(fs * 0.04)))    // ≈40 мс

    // 3) Адаптивный порог: c * медиана
    let med = median(env)
    let thr = 5.0 * med

    // 4) Поиск максимумов с рефрактерным периодом ~200 мс
    let refractory = Int(fs * 0.2)
    var peaks: [Int] = []
    var i = 1
    while i < env.count-1 {
        if env[i] > thr && env[i] > env[i-1] && env[i] >= env[i+1] {
            peaks.append(i)
            i += refractory
        } else {
            i += 1
        }
    }
    return peaks
}

private func movingAvg(_ x: [Double], window w: Int) -> [Double] {
    guard w > 1, x.count >= w else { return x }
    var out = [Double](repeating: 0, count: x.count)
    var sum = 0.0
    for i in 0..<x.count {
        sum += x[i]
        if i >= w { sum -= x[i-w] }
        out[i] = (i >= w-1) ? sum / Double(w) : sum / Double(i+1)
    }
    return out
}

private func highpassMovingAvg(_ x: [Double], window w: Int) -> [Double] {
    let ma = movingAvg(x, window: w)
    return zip(x, ma).map { $0 - $1 }
}

private func median(_ a: [Double]) -> Double {
    guard !a.isEmpty else { return 0 }
    var b = a
    b.sort()
    let n = b.count
    return (n % 2 == 1) ? b[n/2] : 0.5*(b[n/2-1] + b[n/2])
}
