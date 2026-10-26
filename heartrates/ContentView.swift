//
//  ContentView.swift
//  heartrates
//
//  Created by mazzahaker on 17/8/25.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var vm = AppViewModel()
    @StateObject private var esp = ESP32Manager()
    @StateObject private var xiao = XIAOManager()    
    enum Tab { case watch, esp32, xiao }
    @State private var tab: Tab = .watch

    var body: some View {
        TabView(selection: $tab) {

            // MARK: — Вкладка 1: Apple Watch
            WatchPane()
                .tabItem {
                    Label("Apple Watch", systemImage: "heart.text.square")
                }
                .tag(Tab.watch)

            // MARK: — Вкладка 2: ESP32 (AD8232)
            ESP32Pane(esp: esp, title: "ESP32 (AD8232)")
                .tabItem {
                    Label("ESP32", systemImage: "antenna.radiowaves.left.and.right")
                }
                .tag(Tab.esp32)

            // MARK: — Вкладка 3: XIAO / MAX30003
            XIAOView(xiao: xiao)
                .tabItem {
                    Image(systemName: "waveform.path.ecg.rectangle")
                    Text("XIAO")
                }
                .tag(Tab.xiao)
        }
    }
}

// MARK: - Панель Apple Watch (как было)

private struct WatchPane: View {
    @StateObject private var vm = AppViewModel()
    @State private var mode: ECGChartView.Mode = .last10s
    @State private var showRaw = false
    @State private var showFiltered = false
    @State private var showPT = false
    @State private var showDetect = false
    private var rawPoints: [ECGPoint] { vm.ecg }
//    private var filteredPoints: [ECGPoint] { vm.ecg }
    private func movingAverageZeroPhase(_ x: [Double], window w: Int) -> [Double] {
        func ma(_ a: [Double]) -> [Double] {
            guard w > 1, a.count > 2 else { return a }
            var out = [Double](repeating: 0, count: a.count)
            var sum = 0.0
            for i in 0..<a.count {
                sum += a[i]
                if i >= w { sum -= a[i - w] }
                out[i] = sum / Double(min(i + 1, w))
            }
            return out
        }

        let fwd = ma(x)
        let rev = ma(Array(fwd.reversed()))
        return Array(rev.reversed())
    }

    private func lowpassMovingAverage(_ x: [Double], fs: Double, fc: Double) -> [Double] {
        let w = max(3, Int(round(fs / max(1.0, fc))))
        return movingAverageZeroPhase(x, window: w)
    }

    private func medianFilter(_ x: [Double], window w: Int = 5) -> [Double] {
        guard w >= 3, w % 2 == 1, x.count > w else { return x }
        let r = w / 2
        var out = x

        for i in r..<(x.count - r) {
            var buf: [Double] = []
            buf.reserveCapacity(w)
            for k in (i - r)...(i + r) {
                buf.append(x[k])
            }
            buf.sort()
            out[i] = buf[r]
        }

        return out
    }
    private var filteredPoints: [ECGPoint] {
        let pts = vm.ecg
        guard pts.count > 10 else { return pts }

        let fs = max(1.0, ECGAnalysis.estimateFs(pts))
        var y = pts.map { $0.mV }

        // 1. baseline removal
        let win = max(3, Int(round(0.3 * fs)))
        let baseline = movingAverageZeroPhase(y, window: win)
        for i in y.indices { y[i] -= baseline[i] }

        // 2. low-pass (~40 Hz)
        y = lowpassMovingAverage(y, fs: fs, fc: 40.0)

        // 3. median (убрать выбросы)
        y = medianFilter(y, window: 3)

        return zip(pts, y).map { (p, v) in
            ECGPoint(t: p.t, mV: v)
        }
    }
    @State private var showSignalDetect = false
    
    private var fsFull: Double {
        if let a = vm.analytics, a.sampleRate > 0 { return a.sampleRate }
        return max(1.0, ECGAnalysis.estimateFs(vm.ecg))
    }

    private var ySmooth: [Double] {
        let y = filteredPoints.map { $0.mV }
        return smooth5(y)
    }

    // график 3: MWI
    private var mwiPts: [ECGPoint] {
        let mwi = PTStages.mwiSignal(from: ySmooth, fs: fsFull)
        return mwi.enumerated().map { i, v in
            ECGPoint(t: Double(i) / fsFull, mV: v)
        }
    }

    // график 4: MWI детектора + порог + пики
    private var detMWIPts: [ECGPoint] {
        let dbg = ECGAnalysis.detectRPeaksDebug(signal: ySmooth, fs: fsFull)
        return dbg.integ.enumerated().map { i, v in
            ECGPoint(t: Double(i) / fsFull, mV: v)
        }
    }

    private var detThr: Double {
        ECGAnalysis.detectRPeaksDebug(signal: ySmooth, fs: fsFull).thr
    }
    private func makeMarkerPoints(from indices: [Int], in points: [ECGPoint]) -> [ECGPoint] {
        guard !points.isEmpty, !indices.isEmpty else { return [] }

        return indices.compactMap { idx in
            guard idx >= 0, idx < points.count else { return nil }
            return points[idx]
        }
    }
    private var detSignalMarkerPoints: [ECGPoint] {
        makeMarkerPoints(from: detPeakIndices, in: filteredPoints)
    }
    private var detPeakIndices: [Int] {
        ECGAnalysis.detectRPeaksDebug(signal: ySmooth, fs: fsFull).peaks
    }
    private var detPeakTimes: [Double] {
        let dbg = ECGAnalysis.detectRPeaksDebug(signal: ySmooth, fs: fsFull)
        return dbg.peaks.map { Double($0) / fsFull }
    }
    // PDF экспорт
    @State private var pdfDoc: PDFFile?
    @State private var showExporter = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Часы → Графики").font(.largeTitle.bold())
                    Text("ЭКГ").font(.title2.bold())

                    if vm.ecg.isEmpty {
                        Text("Сделайте запись в приложении «ЭКГ» на Apple Watch. Мы автоматически подхватим последнюю запись из HealthKit.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Режим", selection: $mode) {
                            Text("5 с").tag(ECGChartView.Mode.last10s)
                            Text("Вся запись").tag(ECGChartView.Mode.full)
                        }
                        .pickerStyle(.segmented)

                        // 1) RAW (HealthKit)
                        CollapsibleECGSection(
                            title: "1) Исходный сигнал (HealthKit)",
                            points: rawPoints,
                            markerPoints: [],
                            isExpanded: $showRaw,
                            mode: mode,
                            height: 220
                        )

                        // 2) Filtered (для AW совпадает с исходным)
                        CollapsibleECGSection(
                            title: "2) Отфильтрованные данные",
                            points: filteredPoints,
                            markerPoints: [],
                            isExpanded: $showFiltered,
                            mode: mode,
                            height: 220
                        )

                        // 3) MWI
                        CollapsibleECGSection(
                            title: "3) Метод Пан–Томпкинса (MWI)",
                            points: mwiPts,
                            markerPoints: [],
                            isExpanded: $showPT,
                            mode: mode,
                            height: 220
                        )

                        // 4) Detection (MWI + порог + пики)
                        CollapsiblePTDetectionSection(
                            title: "4) Детектирование (MWI + порог + R-пики)",
                            mwi: detMWIPts,
                            thr: detThr,
                            peakTimes: detPeakTimes,
                            isExpanded: $showDetect,
                            mode: mode,
                            height: 220
                        )
                        CollapsibleECGSection(
                            title: "5) Детектирование по сигналу",
                            points: filteredPoints,
                            markerPoints: detSignalMarkerPoints,
                            isExpanded: $showSignalDetect,
                            mode: mode,
                            height: 220
                        )
                        if let a = vm.analytics { analyticsBlock(a) }

                        Button("Экспорт в PDF") {
                            let fs = fsFull
                            let pdfAnalytics = ECGAnalysis.analyticsFromRPeaks(
                                sampleRate: fs,
                                rPeaksSec: detPeakTimes,
                                classification: vm.analytics?.classification,
                                appleAvgHR: vm.analytics?.appleAvgHR,
                                symptoms: vm.analytics?.symptoms
                            )
                            if let data = PDFExporter.makePDF(
                                raw: rawPoints,
                                filtered: filteredPoints,
                                mwi: mwiPts,
                                detMWI: detMWIPts,
                                detThr: detThr,
                                detPeakTimes: detPeakTimes,
                                signalMarkerPoints: detSignalMarkerPoints,
                                analytics: pdfAnalytics,
                                source: .appleWatch
                            ),
                            !data.isEmpty {
                                pdfDoc = PDFFile(data: data)
                                showExporter = true
                                vm.status = "PDF готов: \(data.count) байт"
                            } else {
                                vm.status = "PDF: нет данных для экспорта"
                            }
                        }
                        .buttonStyle(.bordered)
                        .fileExporter(
                            isPresented: $showExporter,
                            document: pdfDoc,
                            contentType: .pdf,
                            defaultFilename: "ECG"
                        ) { result in
                            switch result {
                            case .success(let url):
                                vm.status = "PDF сохранён: \(url.lastPathComponent)"
                            case .failure(let err):
                                vm.status = "Экспорт: \(err.localizedDescription)"
                            }
                        }
                    }

                    Divider().padding(.vertical, 4)

                    Text(vm.status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    HStack {
                        Button("Выгрузить последнее ЭКГ") {
                            Task {
                                await vm.requestAuthorization()
                                vm.startECGObserver()
                                vm.fetchLatestECGFull()
                            }
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Очистить") { vm.reset() }
                            .buttonStyle(.bordered)
                    }
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }
// 5-точечное скользящее среднее
private func smooth5(_ x: [Double]) -> [Double] {
    guard x.count >= 5 else { return x }
    var y = x
    for i in 2..<(x.count - 2) {
        y[i] = (x[i-2] + x[i-1] + x[i] + x[i+1] + x[i+2]) / 5.0
    }
    y[0] = x[0]; y[1] = x[1]
    y[y.count-2] = x[x.count-2]
    y[y.count-1] = x[x.count-1]
    return y
}
    // общий блок метрик
    @ViewBuilder
    private func analyticsBlock(_ a: ECGAnalytics) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let cls = a.classification {
                Text(cls).font(.headline)
            }
            let d = ECGAnalysis.deriveFromRPeaks(rPeaksSec: detPeakTimes) // ВАЖНО: именно detPeakTimes!

            // 1) RR из rPeaksSec
            let rrAllMs = d.rrAllMs

            // 2) NN-фильтр (обязательно!)
            let rrMs = d.rrMs

            // 3) Средний RR и HR согласованно
            let meanRR = d.meanRRms ?? .nan
            let meanHR = d.meanHR ?? .nan

            // 4) SDNN/RMSSD по тем же NN (ms)
            let sdnnVal = d.sdnnMs ?? 0
            let rmssdVal = d.rmssdMs ?? 0

            // 5) Остальные метрики по тем же NN (sec)
            let rrSec = rrMs.map { $0 / 1000.0 }
            let hrv = d.hrv

            // 6) Стресс по тем же NN
            let si = d.stressIndex ?? .nan
            // --- UI ---
            HStack {
                Text("Средний ЧСС: \(meanHR.isFinite ? String(format: "%.0f", meanHR) : "—") bpm")
                    .font(.headline)
                Spacer()
                Text("Частота: \(Int(a.sampleRate)) Гц")
                    .font(.subheadline)
                Text(a.snrDb.map { String(format: "SNR: %.1f dB", $0) } ?? "SNR: —")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("R-пиков: \(detPeakTimes.count)")
                Spacer()
                Text(String(format: "SDNN: %.0f мс", sdnnVal))
                Spacer()
                Text(String(format: "RMSSD: %.0f мс", rmssdVal))
            }
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
        }
    }

    private func fmt0(_ v: Double?) -> String {
        v.map { String(format: "%.0f", $0) } ?? "—"
    }
}

// MARK: - Панель для ESP-совместимых устройств (переиспользуем для ESP32 и XIAO)

private struct ESP32Pane: View {
    @ObservedObject var esp: ESP32Manager
    @State private var espMode: ECGChartView.Mode = .last10s
    @State private var pdfDoc: PDFFile?
    @State private var showExporter = false
    @State private var showRaw = false
    @State private var showFiltered = false
    @State private var showPT = false
    @State private var showDetect = false
    @State private var showSignalDetect = false
    
    let title: String
    private func makeMarkerPoints(from times: [Double], in points: [ECGPoint]) -> [ECGPoint] {
        guard !points.isEmpty, !times.isEmpty else { return [] }

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

        return times.compactMap { t in
            guard let idx = nearestIndexByTime(points, t) else { return nil }
            return points[idx]
        }
    }
    private var espSignalMarkerPoints: [ECGPoint] {
        makeMarkerPoints(from: esp.espDetPeakTimes, in: esp.espFilteredPoints)
    }
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(title).font(.title2.bold())

                    if !esp.espLast.isEmpty {
                        Picker("", selection: $espMode) {
                            Text("5 с").tag(ECGChartView.Mode.last10s)
                            Text("Вся запись").tag(ECGChartView.Mode.full)
                        }
                        .pickerStyle(.segmented)

                        // 3 графика “шторкой”
                        CollapsibleECGSection(
                            title: "1) Сырые данные (RAW)",
                            points: esp.espRawPoints,
                            markerPoints: [],
                            isExpanded: $showRaw,
                            mode: espMode,
                            height: 220
                        )

                        CollapsibleECGSection(
                            title: "2) Отфильтрованные данные",
                            points: esp.espFilteredPoints,
                            markerPoints: [],
                            isExpanded: $showFiltered,
                            mode: espMode,
                            height: 220
                        )

                        CollapsibleECGSection(
                            title: "3) Метод Пан–Томпкинса (MWI)",
                            points: esp.espPTPoints,
                            markerPoints: [],
                            isExpanded: $showPT,
                            mode: espMode,
                            height: 220
                        )
                        
                        CollapsiblePTDetectionSection(
                            title: "4) Детектирование (MWI + порог + R-пики)",
                            mwi: esp.espDetMWIPoints,
                            thr: esp.espDetThr,
                            peakTimes: esp.espDetPeakTimes,
                            isExpanded: $showDetect,
                            mode: espMode,
                            height: 220
                        )
                        CollapsibleECGSection(
                            title: "5) Детектирование по сигналу",
                            points: esp.espFilteredPoints,
                            markerPoints: espSignalMarkerPoints,
                            isExpanded: $showSignalDetect,
                            mode: espMode,
                            height: 220
                        )
                        let basePoints = !esp.espFilteredPoints.isEmpty ? esp.espFilteredPoints : esp.espLast
                        if let ea = ECGAnalysis.compute(points: basePoints) {
                            analyticsBlock(ea, basePoints: basePoints)

                            Button("Экспорт в PDF") {

                                guard basePoints.count > 1 else {
                                    esp.espStatus = "PDF: нет данных"
                                    return
                                }

                                let fs = max(1.0, esp.espFs > 0 ? esp.espFs : ea.sampleRate)

                                // analytics ДОЛЖЕН быть из тех же R-пиков, что UI
                                let pdfAnalytics = ECGAnalysis.analyticsFromRPeaks(
                                    sampleRate: fs,
                                    rPeaksSec: esp.espDetPeakTimes
                                )
                                if let data = PDFExporter.makePDF(
                                    raw: esp.espRawPoints,
                                    filtered: basePoints,
                                    mwi: esp.espPTPoints,
                                    detMWI: esp.espDetMWIPoints,
                                    detThr: esp.espDetThr,
                                    detPeakTimes: esp.espDetPeakTimes,
                                    signalMarkerPoints: espSignalMarkerPoints,
                                    analytics: pdfAnalytics,
                                    source: .esp32
                                ), !data.isEmpty {
                                    pdfDoc = PDFFile(data: data)
                                    showExporter = true
                                    esp.espStatus = "PDF готов"
                                } else {
                                    esp.espStatus = "PDF: ошибка генерации"
                                }
                            }
                            .buttonStyle(.bordered)
                            .fileExporter(
                                isPresented: $showExporter,
                                document: pdfDoc,
                                contentType: .pdf,
                                defaultFilename: "ECG_ESP32"
                            ) { result in
                                switch result {
                                case .success(let url):
                                    esp.espStatus = "PDF сохранён: \(url.lastPathComponent)"
                                case .failure(let err):
                                    esp.espStatus = "Экспорт: \(err.localizedDescription)"
                                }
                            }
                        }
                    } else {
                        Text("Нет данных. Подключитесь к устройству и начните запись.")
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 12) {
                        Button("Подключиться") { esp.connect() }
                            .buttonStyle(.bordered)

                        Button("Начать 30 с") { esp.startCapture30s() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!esp.isReady)

                        Button("Из файла") { esp.loadFromFile() }
                            .buttonStyle(.bordered)

                        Button("Очистить") { esp.resetESP() }
                            .buttonStyle(.bordered)
                    }

                    Text(esp.espStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if !esp.espLast.isEmpty {
                        Text("Fs (оценка): \(Int(ECGAnalysis.estimateFs(esp.espLast))) Гц")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private func analyticsBlock(_ a: ECGAnalytics, basePoints: [ECGPoint]) -> some View {

        // Fs берём из менеджера (он у тебя живёт снаружи), иначе fallback из analytics
        let fsFull = max(1.0, esp.espFs > 0 ? esp.espFs : a.sampleRate)

        // 1) пики берём из детектора (как в XIAO)
        let rPeaksSec = esp.espDetPeakTimes          // [Double] в секундах
        let rFound = rPeaksSec.count

        // 2) RR из пиков
        let rrAllMs = ECGAnalysis.rrFromRPeaks(rPeaksSec)     // обычно rFound-1
        let rrMs = ECGAnalysis.filterRRms(rrAllMs)            // NN после фильтра

        let rrAllCount = rrAllMs.count
        let rrUsedCount = rrMs.count
        let nnPairs = max(0, rrUsedCount - 1)

        // 3) meanRR/meanHR по rrMs
        let meanRR = ECGAnalysis.meanRR(rrMs: rrMs) ?? .nan
        let meanHR = meanRR.isFinite ? Int(round(60000.0 / meanRR)) : 0

        // 4) SDNN/RMSSD по rrMs
        let sdnnVal = sdnn(rrMs)
        let rmssdVal = rmssd(rrMs)

        // 5) HRV-метрики + стресс
        let rrSec = rrMs.map { $0 / 1000.0 }
        let hrv = ECGAnalysis.computeHRVMetrics(rr: rrSec)
        let si = ECGAnalysis.baevskyStress(rrMs: rrMs)
        let d = ECGAnalysis.deriveFromRPeaks(rPeaksSec: rPeaksSec)
        let it = d.interpretation
        
        VStack(alignment: .leading, spacing: 8) {

            HStack {
                Text("Средний ЧСС: \(meanHR) bpm")
                    .font(.headline)
                Spacer()
                Text(String(format: "Частота: %.0f Гц", fsFull))
                    .font(.subheadline)
                Text(esp.espSNRdB.map { String(format: "SNR: %.1f dB", $0) } ?? "SNR: —")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("R-пиков (найдено): \(rFound)")
                Spacer()
                Text(String(format: "SDNN: %.0f мс", sdnnVal))
                Spacer()
                Text(String(format: "RMSSD: %.0f мс", rmssdVal))
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            HStack {
                Text("RR: \(rrUsedCount) из \(rrAllCount), пары: \(nnPairs)")
                Spacer()
                Text(String(format: "pNN50: %.1f %%", hrv?.pnn50 ?? 0))
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

            if let it {
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
        }
    }

    private func fmt0(_ v: Double?) -> String {
        v.map { String(format: "%.0f", $0) } ?? "—"
    }
}

// MARK: – FileDocument для PDF (без изменений)

struct PDFFile: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
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
