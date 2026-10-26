//
//  ECGAnalysis.swift
//  heartrates
//
//  Created by mazzahaker on 17/8/25.
//

import Foundation

enum PTStages {
    static func mwiSignal(from filtered: [Double], fs: Double) -> [Double] {
        guard filtered.count > 4 else { return filtered }

        // 1) derivative (простая 5-точечная как в классике)
        // y[n] = (1/8T) * ( -x[n-2] -2x[n-1] +2x[n+1] + x[n+2] )
        let T = 1.0 / max(fs, 1.0)
        var d = [Double](repeating: 0, count: filtered.count)
        if filtered.count >= 5 {
            for n in 2..<(filtered.count-2) {
                d[n] = (-filtered[n-2] - 2*filtered[n-1] + 2*filtered[n+1] + filtered[n+2]) / (8*T)
            }
        }

        // 2) square
        let sq = d.map { $0 * $0 }

        // 3) moving window integration ~150 ms
        let w = max(1, Int(round(0.150 * fs)))
        var out = [Double](repeating: 0, count: sq.count)
        var sum = 0.0
        for i in 0..<sq.count {
            sum += sq[i]
            if i >= w { sum -= sq[i-w] }
            out[i] = sum / Double(min(i+1, w))
        }
        return out
    }
}

struct ECGAnalysis {
    static func compute(points: [ECGPoint]) -> ECGAnalytics? {
        guard points.count > 5 else { return nil }

        // Оценка частоты дискретизации
        let n = min(points.count - 1, 2048)
        var sumDt = 0.0
        for i in 1...n { sumDt += points[i].t - points[i-1].t }
        let dt = max(sumDt / Double(n), 1.0 / 512.0)
        let fs = 1.0 / dt

        let high = points.map { $0.mV }

        // Производная + квадрат
        var diffSq = Array(repeating: 0.0, count: high.count)
        for i in 1..<high.count {
            let d = high[i] - high[i-1]
            diffSq[i] = d * d
        }

        // Интегрирование окном ~150 мс
        let winInt = Int(max(1, (0.15 * fs).rounded()))
        var integ = Array(repeating: 0.0, count: diffSq.count)
        var acc2 = 0.0
        for i in 0..<diffSq.count {
            acc2 += diffSq[i]
            if i >= winInt { acc2 -= diffSq[i - winInt] }
            integ[i] = acc2 / Double(min(i + 1, winInt))
        }

        // Порог + рефрактер 250 мс, локальный максимум
//        let thr = (integ.max() ?? 0) * 0.5
        let thr = (integ.max() ?? 0) * 0.6
//        let refr = Int(0.25 * fs)
        let refr = Int(0.32 * fs)
        var last = -refr
        var rIdx: [Int] = []
        for i in 0..<integ.count where integ[i] > thr && i - last > refr {
            last = i
            let rad = Int(0.04 * fs)
            let lo = max(0, i - rad), hi = min(high.count - 1, i + rad)
            let k = (lo...hi).max(by: { high[$0] < high[$1] }) ?? i
            rIdx.append(k)
        }

        let rTimes = rIdx.map { points[$0].t }
        let rr = zip(rTimes.dropFirst(), rTimes).map { $0 - $1 } // сек
        let avgHR = rr.isEmpty ? nil : 60.0 / (rr.reduce(0,+) / Double(rr.count))
        let meanRR = rr.isEmpty ? nil : rr.reduce(0,+) / Double(rr.count)
        let sdnn = (meanRR == nil) ? nil : {
            let m = meanRR!
            return sqrt(rr.map { pow(($0 - m) * 1000.0, 2) }.reduce(0,+) / Double(rr.count))
        }()
        let diffs = zip(rr.dropFirst(), rr).map { $0 - $1 }
        let rmssd = diffs.isEmpty ? nil : sqrt(diffs.map { pow($0 * 1000.0, 2) }.reduce(0,+) / Double(diffs.count))
        // --- дополнительные метрики для интерпретации ---
        let hrv = computeHRVMetrics(rr: rr)   // rr в секундах
        let rrMs = rr.map { $0 * 1000.0 }
        let si = baevskyStress(rrMs: rrMs)

        let interp = buildInterpretation(
            hrMin: hrv?.hrMin,
            hrMax: hrv?.hrMax,
            deltaRRms: hrv.map { $0.deltaRR * 1000.0 },
            sdnnMs: sdnn,
            rmssdMs: rmssd,
            pnn50Pct: hrv?.pnn50,
            cvPct: hrv?.cv,
            narrPct: hrv?.narr,
            stressIndex: si.isFinite ? si : nil
        )
        return ECGAnalytics(
            sampleRate: fs,
            rPeaksSec: rTimes,
            avgHR: avgHR,
            sdnn: sdnn,
            rmssd: rmssd,
            appleAvgHR: nil,
            classification: nil,
            symptoms: nil,
            interpretation: interp,
            snrDb: nil
        )
    }
    /// Быстрая оценка частоты дискретизации по ряду точек
        static func estimateSampleRate(points: [ECGPoint]) -> Double {
            let n = min(points.count - 1, 2048)
            guard n >= 1 else { return 0 }
            var sumDt = 0.0
            for i in 1...n {
                sumDt += points[i].t - points[i - 1].t
            }
            let dt = sumDt / Double(n)
            return dt > 0 ? 1.0 / dt : 0
        }
    
    static func computeHRVMetrics(rr: [Double]) -> HRVMetrics? {
        guard rr.count > 2 else { return nil }

        let hrValues = rr.map { 60.0 / $0 }

        let hrMin = hrValues.min() ?? 0
        let hrMax = hrValues.max() ?? 0

        let rrMin = rr.min() ?? 0
        let rrMax = rr.max() ?? 0
        let deltaRR = rrMax - rrMin

        // pNN50
        var nn50 = 0
        for i in 1..<rr.count {
            if abs(rr[i] - rr[i - 1]) > 0.05 {
                nn50 += 1
            }
        }
        let pnn50 = Double(nn50) / Double(rr.count - 1) * 100.0

        let meanRR = rr.reduce(0, +) / Double(rr.count)

        // NArr: доля NN-интервалов, отклоняющихся от среднего более чем на 10%
        let nAp = rr.filter { abs($0 - meanRR) > 0.10 * meanRR }.count
        let narr = Double(nAp) / Double(rr.count) * 100.0

        // SDNN — в той же логике, что и deriveFromRPeaks()
        let sdnn: Double = {
            guard rr.count > 1 else { return 0 }
            let varSum = rr.map { pow($0 - meanRR, 2) }.reduce(0, +)
            return sqrt(varSum / Double(rr.count - 1))
        }()

        // CV
        let cv = (sdnn / meanRR) * 100.0

        let meanHR = 60.0 / meanRR
        let isTachy = meanHR > 100
        let isBrady = meanHR < 60

        return HRVMetrics(
            hrMin: hrMin,
            hrMax: hrMax,
            deltaRR: deltaRR,
            nn50: nn50,
            pnn50: pnn50,
            cv: cv,
            narr: narr,
            isTachy: isTachy,
            isBrady: isBrady
        )
    }
    static func filterRRms(_ rr: [Double]) -> [Double] {
        guard rr.count > 2 else { return rr }

        // 1) физиологический диапазон (пример)
        let rr1 = rr.filter { $0 >= 300 && $0 <= 2000 }

        guard rr1.count > 2 else { return rr1 }

        // 2) убрать “скачки” относительно медианы
        let med = rr1.sorted()[rr1.count / 2]
        let rr2 = rr1.filter { abs($0 - med) <= 0.3 * med }
        return rr2.count >= 2 ? rr2 : rr1
    }
}

// Оценка частоты дискретизации по метке времени точек (устойчиво к выбросам)
extension ECGAnalysis {
    static func estimateFs(_ points: [ECGPoint]) -> Double {
        guard points.count > 1 else { return 0 }

        // Берём до ~4K шагов, чтобы не трогать всю длинную запись
        let n = min(points.count - 1, 4096)
        var dts = [Double]()
        dts.reserveCapacity(n)

        for i in 1...n {
            let dt = points[i].t - points[i-1].t
            if dt.isFinite, dt > 0, dt < 1.0 { // отсекаем мусор
                dts.append(dt)
            }
        }
        guard !dts.isEmpty else { return 0 }

        dts.sort()
        // Медиана шага во времени → Fs = 1/median(dt)
        let medianDt = dts[dts.count / 2]
        let fs = 1.0 / medianDt
        return fs.isFinite ? fs : 0
    }
}
// === RR helpers (универсальные) ===
extension ECGAnalysis {
    struct DerivedFromRPeaks {
            let rrAllMs: [Double]
            let rrMs: [Double]           // после filterRRms
            let meanRRms: Double?
            let meanHR: Double?          // bpm
            let sdnnMs: Double?
            let rmssdMs: Double?
            let hrv: HRVMetrics?
            let stressIndex: Double?
            let interpretation: ECGInterpretation?
        }

        static func deriveFromRPeaks(rPeaksSec: [Double]) -> DerivedFromRPeaks {

            let rrAllMs = rrFromRPeaks(rPeaksSec)
            let rrMs = filterRRms(rrAllMs)

            // meanRR / meanHR
            let meanRR = meanRR(rrMs: rrMs)
            let meanHR = (meanRR != nil && meanRR!.isFinite && meanRR! > 0) ? (60000.0 / meanRR!) : nil

            // SDNN (как у тебя в UI helper: деление на N-1)
            let sdnnMs: Double? = {
                guard rrMs.count > 1 else { return nil }
                let m = rrMs.reduce(0, +) / Double(rrMs.count)
                let varSum = rrMs.reduce(0) { $0 + pow($1 - m, 2) }
                return sqrt(varSum / Double(rrMs.count - 1))
            }()

            // RMSSD (как у тебя в UI helper)
            let rmssdMs: Double? = {
                guard rrMs.count > 1 else { return nil }
                var diffs: [Double] = []
                diffs.reserveCapacity(rrMs.count - 1)
                for i in 1..<rrMs.count { diffs.append(rrMs[i] - rrMs[i-1]) }
                let meanSq = diffs.reduce(0) { $0 + $1*$1 } / Double(diffs.count)
                return sqrt(meanSq)
            }()

            // HRV metrics (computeHRVMetrics ждёт rr в секундах)
            let rrSec = rrMs.map { $0 / 1000.0 }
            let hrv = computeHRVMetrics(rr: rrSec)

            // SI
            let si = baevskyStress(rrMs: rrMs)
            let siOpt = si.isFinite ? si : nil

            let interp = buildInterpretation(
                hrMin: hrv?.hrMin,
                hrMax: hrv?.hrMax,
                deltaRRms: hrv.map { $0.deltaRR * 1000.0 },
                sdnnMs: sdnnMs,
                rmssdMs: rmssdMs,
                pnn50Pct: hrv?.pnn50,
                cvPct: hrv?.cv,
                narrPct: hrv?.narr,
                stressIndex: siOpt
            )

            return .init(
                rrAllMs: rrAllMs,
                rrMs: rrMs,
                meanRRms: meanRR,
                meanHR: meanHR,
                sdnnMs: sdnnMs,
                rmssdMs: rmssdMs,
                hrv: hrv,
                stressIndex: siOpt,
                interpretation: interp
            )
        }
    // --- R-peak detector (простой и быстрый, без внешних зависимостей) ---
    static func detectRPeaks(signal: [Double], fs: Double) -> [Int] {
        guard signal.count > 4, fs > 0 else { return [] }
        // === ПАРАМЕТРЫ ДЕТЕКТОРА ===
        let MIN_RR_MS: Double = 300
        let THR_QRS_Q: Double = 0.40
        // 1) Дифференциальный отклик (~40 мс)
        let w = max(3, Int(max(0.04 * fs, 3)))
        var diff = [Double](repeating: 0, count: signal.count)
        for i in w..<signal.count {
            diff[i] = signal[i] - signal[i - w]
        }

        // 2) Прямоуг. интегратор (~120 мс) с диодом (только положит. часть)
        let m = max(1, Int(0.12 * fs))
        var integ = [Double](repeating: 0, count: signal.count)
        var sum = 0.0
        for i in 0..<signal.count {
            let v = max(0, diff[i])
            sum += v
            if i >= m { sum -= max(0, diff[i - m]) }
            integ[i] = sum / Double(min(i + 1, m))
        }

        // 3) Порог: mean + k*std (чуть жёстче, чтобы не ловить Q/S)
        let mean = integ.reduce(0, +) / Double(integ.count)
        let std  = sqrt(integ.reduce(0) { $0 + pow($1 - mean, 2) } / Double(integ.count))
        let k: Double = 0.75           // было 0.5
        let thr = mean + k * std

        // 3b) Амплитудный порог по «сырым» мВ (пик-впадина должна быть заметной)
        let meanSig = signal.reduce(0, +) / Double(signal.count)
        let stdSig  = sqrt(signal.reduce(0) { $0 + pow($1 - meanSig, 2) } / Double(signal.count))
        let ampThr  = 0.35 * stdSig    // эмпирически устойчиво для XIAO/ESP

        // 4) Рефрактерный интервал 250 мс
        let refr = Int(0.30 * fs)
        
        // 5) Поиск локальных максимумов интегр. сигнала, привязка к пику R
        var peaks: [Int] = []
        var i = 1
        while i < integ.count - 1 {
            if integ[i] > thr, integ[i] > integ[i - 1], integ[i] >= integ[i + 1] {
                let win = max(1, Int(0.05 * fs))            // ±50 мс
                let start = max(i - win, 0)
                let end   = min(i + win, signal.count - 1)

                var imax = start
                var vmax = signal[start]
                var vmin = signal[start]
                if start < end {
                    for j in (start + 1)...end {
                        let s = signal[j]
                        if s > vmax { vmax = s; imax = j }
                        if s < vmin { vmin = s }
                    }
                }

                // Требуем достаточную амплитуду комплекса относительно локальной впадины
                let ampOK = (vmax - vmin) >= ampThr

                if ampOK && (peaks.isEmpty || imax - peaks.last! > refr) {
                    peaks.append(imax)
                    i = imax + refr
                    continue
                }
            }
            i += 1
        }
        return peaks
    }
    /// RR из массива R-пиков в секундах (как в analytics.rPeaksSec) -> миллисекунды
    static func rrFromRPeaks(_ rPeaksSec: [Double]) -> [Double] {
        guard rPeaksSec.count >= 2 else { return [] }
        return zip(rPeaksSec.dropFirst(), rPeaksSec).map { ($0 - $1) * 1000.0 }
    }

    /// RR из массива точек (t в секундах) и Fs
    static func rrFrom(points: [ECGPoint], fs: Double) -> [Double] {
        guard points.count >= 2 else { return [] }
        // Берём R-пики существующим детектором
        let sig = points.map { $0.mV }
        let idx = ECGAnalysis.detectRPeaks(signal: sig, fs: fs)
        guard idx.count >= 2 else { return [] }
        return zip(idx.dropFirst(), idx).map { Double($0 - $1) * 1000.0 / fs }
    }

    /// Индекс стресса Баевского по RR в мс
    static func baevskyStress(rrMs: [Double]) -> Double {
        guard rrMs.count >= 2 else { return .nan }
        let mean = rrMs.reduce(0,+) / Double(rrMs.count)
        let sdnn = sqrt( rrMs.reduce(0) { $0 + pow($1 - mean, 2) } / Double(rrMs.count) )
        if sdnn <= 1e-6 || !sdnn.isFinite { return .nan }
        return 1000.0 / sdnn
    }

    /// Средний RR (мс)
    static func meanRR(rrMs: [Double]) -> Double? {
        guard !rrMs.isEmpty else { return nil }
        return rrMs.reduce(0,+) / Double(rrMs.count)
    }
}

struct HRVMetrics {
    var hrMin: Double
    var hrMax: Double
    var deltaRR: Double
    var nn50: Int
    var pnn50: Double
    var cv: Double
    var narr: Double
    var isTachy: Bool
    var isBrady: Bool
}
extension ECGAnalysis {

    struct MWIDetectionDebug {
        let mwi: [Double]        // что рисуем
        let thr: Double          // порог
        let peaksIdx: [Int]      // индексы R-пиков
        let peaksSec: [Double]   // времена R-пиков (сек)
    }
    static func refineRPeakIndices(_ peaks: [Int], on ecg: [Double], fs: Double) -> [Int] {
        guard !peaks.isEmpty, !ecg.isEmpty, fs > 0 else { return peaks }

        let win = max(1, Int(0.04 * fs))   // ±40 мс
        var refined: [Int] = []
        refined.reserveCapacity(peaks.count)

        for p in peaks {
            let start = max(0, p - win)
            let end = min(ecg.count - 1, p + win)

            var best = p
            var bestVal = ecg[p]

            if start <= end {
                for i in start...end {
                    if abs(ecg[i]) > abs(bestVal) {
                        bestVal = ecg[i]
                        best = i
                    }
                }
            }

            refined.append(best)
        }

        return refined
    }
    static func refineDisplayPeakIndices(_ peaks: [Int], on ecg: [Double], fs: Double) -> [Int] {
        guard !peaks.isEmpty, !ecg.isEmpty, fs > 0 else { return peaks }

        let win = max(1, Int(0.08 * fs))   // ±80 мс
        var refined: [Int] = []
        refined.reserveCapacity(peaks.count)

        for p in peaks {
            let start = max(0, p - win)
            let end = min(ecg.count - 1, p + win)

            var best = p
            var bestVal = ecg[p]

            if start <= end {
                for i in start...end {
                    if ecg[i] > bestVal {
                        bestVal = ecg[i]
                        best = i
                    }
                }
            }

            refined.append(best)
        }

        return refined
    }
    /// Pan-Tompkins style R-peak detection over MWI signal.
    /// Returns peak sample indices and threshold series (for debug plot).
    static func detectRPeaksPT(mwi: [Double], fs: Double) -> (peaks: [Int], thr: [Double]) {
        guard mwi.count > 3 else { return ([], Array(repeating: 0, count: mwi.count)) }

        // 1) Find local maxima candidates
        var cand: [(i: Int, v: Double)] = []
        cand.reserveCapacity(mwi.count / 4)

        for i in 1..<(mwi.count - 1) {
            let v = mwi[i]
            if v >= mwi[i - 1] && v > mwi[i + 1] { // локальный максимум
                cand.append((i, v))
            }
        }
        if cand.isEmpty { return ([], Array(repeating: 0, count: mwi.count)) }

        // 2) Init SPKI/NPKI from first seconds
        let initN = min(Int(fs * 2.0), cand.count) // ~2 сек кандидатов
        let initVals = cand.prefix(initN).map { $0.v }
        let initMax = initVals.max() ?? 0
        let initMed = initVals.sorted()[initVals.count / 2]

        var spki = initMax * 0.25          // стартовая оценка "сигнала"
        var npki = initMed * 0.50          // стартовая оценка "шума"

        func th1() -> Double { npki + 0.25 * (spki - npki) }
        func th2() -> Double { 0.5 * th1() }

        // refractory (не принимать пики слишком близко)
        let refr = Int(0.180 * fs) // 200 мс (лучше чем 0.32с для MWI)
        var peaks: [Int] = []
        peaks.reserveCapacity(64)

        // RR history for missed-beat logic (в секундах)
        var rrHist: [Double] = []
        rrHist.reserveCapacity(8)
        func rrAvg() -> Double {
            if rrHist.isEmpty { return 0.8 } // fallback 75 bpm
            return rrHist.reduce(0, +) / Double(rrHist.count)
        }

        // threshold trace for plotting (пер-индекс)
        var thrSeries = Array(repeating: 0.0, count: mwi.count)
        var lastAccepted = -10_000

        // helper: update rr history
        func pushRR(_ rr: Double) {
            rrHist.append(rr)
            if rrHist.count > 8 { rrHist.removeFirst() }
        }

        // 3) main loop over candidates
        for k in 0..<cand.count {
            let (i, v) = cand[k]
            let thrMain = th1()
            thrSeries[i] = thrMain

            // ignore too close peaks
            if i - lastAccepted < refr {
                // treat as noise peak (or you can keep bigger one, но оставим просто noise)
                npki = 0.875 * npki + 0.125 * v
                continue
            }

            if v >= thrMain {
                // Accept as R-peak candidate
                peaks.append(i)
                if peaks.count >= 2 {
                    let rr = Double(peaks[peaks.count - 1] - peaks[peaks.count - 2]) / fs
                    pushRR(rr)

                    // 4) MISSED BEAT CHECK (search-back)
                    let rrA = rrAvg()
                    let rrMissed = 1.66 * rrA
                    if rr > rrMissed {
                        // search for missed peak between previous and current
                        let left = peaks[peaks.count - 2] + refr
                        let right = peaks[peaks.count - 1] - refr
                        if right > left + 2 {
                            var bestI = -1
                            var bestV = -Double.infinity
                            let thrSB = th2()

                            // scan candidates in that window
                            // (можно быстрее: бинарным поиском по cand, но так проще)
                            for (j, vv) in cand {
                                if j < left { continue }
                                if j > right { break }
                                if vv > bestV && vv >= thrSB {
                                    bestV = vv
                                    bestI = j
                                }
                            }

                            if bestI > 0 {
                                // insert missed peak before current peak
                                peaks.insert(bestI, at: peaks.count - 1)
                                // update rr history around insertion (пересчитать два RR)
                                if peaks.count >= 3 {
                                    let a = Double(peaks[peaks.count - 2] - peaks[peaks.count - 3]) / fs
                                    let b = Double(peaks[peaks.count - 1] - peaks[peaks.count - 2]) / fs
                                    // перезапишем последние значения (упрощённо)
                                    rrHist.removeAll(keepingCapacity: true)
                                    // можно пересчитать все rrHist по peaks, но для простоты — оставим 2 последних
                                    pushRR(a); pushRR(b)
                                }
                            }
                        }
                    }
                }

                spki = 0.875 * spki + 0.125 * v
                lastAccepted = i
            } else {
                // Noise peak
                npki = 0.875 * npki + 0.125 * v
            }
        }

        // fill thrSeries for all points (чтобы линия была непрерывной в графике)
        // просто растянем последнее значение
        var last = th1()
        for i in 0..<thrSeries.count {
            if thrSeries[i] != 0 { last = thrSeries[i] }
            thrSeries[i] = last
        }

        return (peaks, thrSeries)
    }
    
    /// Пункт 4: MWI + порог + R-пики (R ищем в исходном filtered ECG)
    static func detectRPeaksOnMWIDebug(filteredECG y: [Double], fs: Double) -> MWIDetectionDebug {
        guard y.count > 10, fs > 0 else {
            return .init(mwi: [], thr: 0, peaksIdx: [], peaksSec: [])
        }

        // 1) MWI (как в пункте 3)
        let mwi = PTStages.mwiSignal(from: y, fs: fs)

        // 2) Порог по MWI (простой, стабильный вариант)
        let mean = mwi.reduce(0,+) / Double(mwi.count)
        let std  = sqrt(mwi.reduce(0) { $0 + pow($1 - mean, 2) } / Double(mwi.count))
        let k: Double = 0.8
        let thr = mean + k * std

        // 3) Поиск локальных максимумов MWI выше порога
        let refr = Int(0.30 * fs) // 300 мс рефрактер
        var peaksIdx: [Int] = []
        var i = 1

        while i < mwi.count - 1 {
            if mwi[i] > thr, mwi[i] > mwi[i-1], mwi[i] >= mwi[i+1] {

                // 4) Привязка к настоящему R в filtered ECG около этого момента (±60 мс)
                let win = max(1, Int(0.06 * fs))
                let start = max(0, i - win)
                let end   = min(y.count - 1, i + win)

                var imax = start
                var vmax = y[start]
                for j in (start+1)...end {
                    if y[j] > vmax {
                        vmax = y[j]
                        imax = j
                    }
                }

                if peaksIdx.isEmpty || (imax - peaksIdx.last!) > refr {
                    peaksIdx.append(imax)
                    i = imax + refr
                    continue
                }
            }
            i += 1
        }

        let peaksSec = peaksIdx.map { Double($0) / fs }
        return .init(mwi: mwi, thr: thr, peaksIdx: peaksIdx, peaksSec: peaksSec)
    }
}
struct ECGInterpretation {
    let hrMinStatus: String
    let hrMaxStatus: String
    let deltaRRStatus: String
    let sdnnStatus: String
    let rmssdStatus: String
    let pnn50Status: String
    let cvStatus: String
    let narrStatus: String
    let stress: String
}
extension ECGAnalysis {

    static func buildInterpretation(
        hrMin: Double?,
        hrMax: Double?,
        deltaRRms: Double?,
        sdnnMs: Double?,
        rmssdMs: Double?,
        pnn50Pct: Double?,
        cvPct: Double?,
        narrPct: Double?,
        stressIndex: Double?
    ) -> ECGInterpretation {

        let hrMinStatus: String = {
            guard let hr = hrMin, hr.isFinite else { return "HRmin: недостаточно данных" }
            if hr < 60 { return "HRmin: эпизод брадикардии" }
            if hr > 100 { return "HRmin: эпизод тахикардии" }
            return "HRmin: в норме"
        }()

        let hrMaxStatus: String = {
            guard let hr = hrMax, hr.isFinite else { return "HRmax: недостаточно данных" }
            if hr < 60 { return "HRmax: эпизод брадикардии" }
            if hr > 100 { return "HRmax: эпизод тахикардии" }
            return "HRmax: в норме"
        }()

        let deltaRRStatus: String = {
            guard let d = deltaRRms, d.isFinite else { return "ΔRR: недостаточно данных" }
            if d < 50 { return "ΔRR: низкая вариабельность" }
            if d < 100 { return "ΔRR: сниженная вариабельность" }
            if d <= 200 { return "ΔRR: ритм здорового человека" }
            if d <= 300 { return "ΔRR: значительная вариабельность" }
            return "ΔRR: значительная вариабельность"
        }()

        let sdnnStatus: String = {
            guard let s = sdnnMs, s.isFinite else { return "SDNN: недостаточно данных" }
            if s < 20 { return "SDNN: оченьнизкая вариабельность" }
            if s < 50 { return "SDNN: сниженная вариабельность" }
            if s <= 100 { return "SDNN: физиологическая норма" }
            return "SDNN: повышенная вариабельность"
        }()

        let rmssdStatus: String = {
            guard let r = rmssdMs, r.isFinite else { return "RMSSD: недостаточно данных" }
            if r < 20 { return "RMSSD: низкая вариабельность" }
            if r < 40 { return "RMSSD: сниженная вариабельность" }
            if r <= 80 { return "RMSSD: физиологическая норма" }
            return "RMSSD: высокая вариабельность"
        }()

        let pnn50Status: String = {
            guard let p = pnn50Pct, p.isFinite else { return "pNN50: недостаточно данных" }
            if p < 3 { return "pNN50: низкая вариабельность" }
            if p < 10 { return "pNN50: сниженная вариабельность" }
            if p <= 30 { return "pNN50: физиологическая норма" }
            return "pNN50: повышенная вариабельность"
        }()

        let cvStatus: String = {
            guard let cv = cvPct, cv.isFinite else { return "CV: недостаточно данных" }
            if cv < 3 { return "CV: низкая вариабельность" }
            if cv < 6 { return "CV: сниженная вариабельность" }
            if cv <= 12 { return "CV: физиологическая норма" }
            return "CV: повышенная вариабельность"
        }()

        let narrStatus: String = {
            guard let n = narrPct, n.isFinite else { return "NArr: недостаточно данных" }
            if n < 5 { return "NArr: стабильный ритм" }
            if n <= 15 { return "NArr: умеренная вариабельность" }
            return "NArr: выраженная нерегулярность"
        }()

        let stress: String = {
            guard let si = stressIndex, si.isFinite else { return "Вегетативный статус: недостаточно данных" }
            if si < 10 { return "Вегетативный статус: низкий уровень стресса" }
            if si < 20 { return "Вегетативный статус: умеренный уровень стресса" }
            if si <= 50 { return "Вегетативный статус: повышенный уровень стресса" }
            return "Вегетативный статус: высокий уровень стресса"
        }()

        return ECGInterpretation(
            hrMinStatus: hrMinStatus,
            hrMaxStatus: hrMaxStatus,
            deltaRRStatus: deltaRRStatus,
            sdnnStatus: sdnnStatus,
            rmssdStatus: rmssdStatus,
            pnn50Status: pnn50Status,
            cvStatus: cvStatus,
            narrStatus: narrStatus,
            stress: stress
        )
    }
}
extension ECGAnalysis {

    static func analyticsFromRPeaks(
        sampleRate fs: Double,
        rPeaksSec: [Double],
        classification: String? = nil,
        appleAvgHR: Double? = nil,
        symptoms: String? = nil
    ) -> ECGAnalytics? {

        guard rPeaksSec.count >= 3 else { return nil }

        let d = deriveFromRPeaks(rPeaksSec: rPeaksSec)

        return ECGAnalytics(
            sampleRate: fs,
            rPeaksSec: rPeaksSec,
            avgHR: d.meanHR,
            sdnn: d.sdnnMs,
            rmssd: d.rmssdMs,
            appleAvgHR: appleAvgHR,
            classification: classification,
            symptoms: symptoms,
            interpretation: d.interpretation,
            snrDb: nil
        )
    }
}
extension ECGAnalysis {

    static func analyticsFromRPeaks(sampleRate fs: Double,
                                    rPeaksSec: [Double]) -> ECGAnalytics? {
        guard fs > 0, rPeaksSec.count >= 3 else { return nil }

        let d = deriveFromRPeaks(rPeaksSec: rPeaksSec)

        return ECGAnalytics(
            sampleRate: fs,
            rPeaksSec: rPeaksSec,          // ВАЖНО: те же пики, что на экране
            avgHR: d.meanHR,
            sdnn: d.sdnnMs,
            rmssd: d.rmssdMs,
            appleAvgHR: nil,
            classification: nil,
            symptoms: nil,
            interpretation: d.interpretation,
            snrDb: nil
        )
    }
}
