//
//  ESP32Manager.swift
//  heartrates
//
//  Created by mazzahaker on 17/8/25.
//

import Foundation
import CoreBluetooth

@MainActor
final class ESP32Manager: NSObject, ObservableObject {

    // UI-состояние
    @Published var espStatus: String = "ESP: не подключен"
    private var countdownTimer: Timer?
    @Published var showOverlayESP: Bool = false
    @Published var espLast: [ECGPoint] = []        // отфильтрованные 30 c
    @Published var espRawLast: [Int16] = []        // сырые точки последнего сеанса
    @Published var isReady: Bool = false           // готов к START (нашли сервис + подписались)
    @Published var espFs: Double = 0
    @Published var espRawPoints: [ECGPoint] = []
    @Published var espFilteredPoints: [ECGPoint] = []
    @Published var espPTPoints: [ECGPoint] = []
    @Published var espMWIPoints: [ECGPoint] = []     // p.3 (MWI)
    @Published var espDetThr: Double = 0             // p.4 порог
    @Published var espDetPoints: [ECGPoint] = []      // MWI/integ used for detection
    @Published var espDetThreshold: Double = 0
    @Published var espDetRPeaksSec: [Double] = []
    @Published var espDetPeakTimes: [Double] = []
    @Published var espDetMWIPoints: [ECGPoint] = []
    @Published var espSNRdB: Double? = nil
    @Published var espDetPeakIndices: [Int] = []
    @Published var espAnalytics: ECGAnalytics? = nil
    private let ECG_HP_CUTOFF: Double = 5    // было 0.5 — делаем мягче, вернём T/P
    private let ECG_LP_CUTOFF: Double = 15.0   // верх как у AW
    private let ECG_HP_Q: Double = 0.7071         // мягче срез, меньше искажения
    private let ECG_LP_Q: Double = 0.7071
    private let ECG_USE_NOTCH = true           // сетевой фон
    private let ECG_NOTCH_Q: Double = 30.0     // помягче, меньше звон
    private let ECG_ZERO_PHASE = true          // прямой+обратный (filtfilt)
    
    // BLE (только кастомный сервис прошивки)
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var ecgCmdChar: CBCharacteristic?
    private var ecgStreamChar: CBCharacteristic?

    private let ECG_SVC     = CBUUID(string: "ec000001-0000-4000-8000-00000000ec01")
    private let ECG_CHR_CMD = CBUUID(string: "ec000002-0000-4000-8000-00000000ec01") // write
    private let ECG_CHR_STR = CBUUID(string: "ec000003-0000-4000-8000-00000000ec01") // notify
    
    // Сбор пакетов
    private var isCapturing = false
    private var captureStartedAt: CFAbsoluteTime = 0
    private var captureBuf: [Int16] = []
    private var captureFs: Double = 200            // Гц (дефолт)
    private let captureSecs: Double = 30           // сек

    // MARK: - Публичные API

    func connect() {
        isReady = false
        if central == nil {
            central = CBCentralManager(delegate: self, queue: nil)
            espStatus = "ESP: инициализация BLE…"
        } else {
            central.scanForPeripherals(withServices: [ECG_SVC], options: nil)
            espStatus = "ESP: сканирование…"
        }
    }
    
    @MainActor
    func resetESP() {
        isCapturing = false
        countdownTimer?.invalidate()
        countdownTimer = nil
        captureBuf.removeAll(keepingCapacity: true)
        espRawLast.removeAll(keepingCapacity: true)
        espLast.removeAll(keepingCapacity: true)
        espRawPoints.removeAll(keepingCapacity: true)
        espFilteredPoints.removeAll(keepingCapacity: true)
        espPTPoints.removeAll(keepingCapacity: true)
        espDetMWIPoints.removeAll(keepingCapacity: true)
        espDetPeakTimes.removeAll(keepingCapacity: true)
        espDetPeakIndices.removeAll(keepingCapacity: true)
        espDetThr = 0
        espFs = 0
        espStatus = "ESP: очищено"
    }
    
    func startCapture30s() {
        guard isReady else { espStatus = "ESP: не подключен"; return }   // ← В НУЖНОМ МЕСТЕ
        guard peripheral != nil, let c = ecgCmdChar else {
            espStatus = "ESP: нет характеристик"
            return
        }

        espStatus = "ESP: получение данных…"
        var remaining = 30
        espStatus = "ESP: осталось \(remaining) c"
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
            guard let self = self else { return }
            remaining -= 1
            if remaining > 0 {
                self.espStatus = "ESP: осталось \(remaining) c"
            } else {
                t.invalidate()
                self.countdownTimer = nil

                // НЕ считаем аналитику тут — finishCapture() сделает всё корректно
                self.espStatus = "ESP: завершение…"
            }
        }
        isCapturing = true
        captureBuf.removeAll(keepingCapacity: true)
        captureStartedAt = CFAbsoluteTimeGetCurrent()
        espRawLast.removeAll(keepingCapacity: true)
        espLast.removeAll(keepingCapacity: true)

        // Отправляем команду START
        peripheral?.writeValue(Data("START".utf8), for: c, type: .withResponse)
    }

    private func buildPoints(_ y: [Double], fs: Double) -> [ECGPoint] {
        let dt = 1.0 / fs
        var t = 0.0
        var pts: [ECGPoint] = []
        pts.reserveCapacity(y.count)
        for v in y {
            pts.append(ECGPoint(t: t, mV: v))
            t += dt
        }
        return pts
    }
    
    private func processRawESP(_ raw: [Int16], fs: Double) -> [ECGPoint] {
        // 1) нормализация в мВ
        let doubles = normalize(raw: raw)

        // 2) фильтрация
        let y: [Double]
        if ECG_ZERO_PHASE {
            y = bpZeroPhase(doubles, fs: fs,
                            hpFc: ECG_HP_CUTOFF, lpFc: ECG_LP_CUTOFF,
                            hpQ: ECG_HP_Q,        lpQ: ECG_LP_Q,
                            notchOn: ECG_USE_NOTCH, notchQ: ECG_NOTCH_Q)
        } else {
            y = bpCascadeOnce(doubles, fs: fs,
                              hpFc: ECG_HP_CUTOFF, lpFc: ECG_LP_CUTOFF,
                              hpQ: ECG_HP_Q,        lpQ: ECG_LP_Q,
                              notchOn: ECG_USE_NOTCH, notchQ: ECG_NOTCH_Q)
        }

        // 3) точки
        let dt = 1.0 / fs
        var t = 0.0
        var pts: [ECGPoint] = []
        pts.reserveCapacity(y.count)
        for v in y {
            pts.append(ECGPoint(t: t, mV: v))
            t += dt
        }
        return pts
    }
    
    private func processAllESP(_ raw: [Int16], fs: Double)
    -> (rawPts: [ECGPoint],
        filtPts: [ECGPoint],
        mwiPts: [ECGPoint],
        detMWIPts: [ECGPoint],
        detThr: Double,
        detPeakIndices: [Int],
        detPeakTimes: [Double]) {

        // 1) RAW (мВ)
        let rawMV  = normalize(raw: raw)
        let rawPts = buildPoints(rawMV, fs: fs)

        // 2) FILTERED ECG (после фильтров)
        let y: [Double]
        if ECG_ZERO_PHASE {
            y = bpZeroPhase(rawMV, fs: fs,
                            hpFc: ECG_HP_CUTOFF, lpFc: ECG_LP_CUTOFF,
                            hpQ: ECG_HP_Q,        lpQ: ECG_LP_Q,
                            notchOn: ECG_USE_NOTCH, notchQ: ECG_NOTCH_Q)
        } else {
            y = bpCascadeOnce(rawMV, fs: fs,
                              hpFc: ECG_HP_CUTOFF, lpFc: ECG_LP_CUTOFF,
                              hpQ: ECG_HP_Q,        lpQ: ECG_LP_Q,
                              notchOn: ECG_USE_NOTCH, notchQ: ECG_NOTCH_Q)
        }
        let filtPts = buildPoints(y, fs: fs)

        // 3) + 4) Pan-Tompkins debug: MWI + порог + пики
        let ySmooth = smooth5(y)

        let mwi = PTStages.mwiSignal(from: ySmooth, fs: fs)
        let mwiPts = buildPoints(mwi, fs: fs)
        let dbg = ECGAnalysis.detectRPeaksDebug(signal: ySmooth, fs: fs)
        let detMWIPts = buildPoints(dbg.integ, fs: fs)
        let detThr = dbg.thr
        let detPeakIndices = dbg.peaks
        let detPeakTimes = dbg.peaks.map { Double($0) / fs }

        return (rawPts, filtPts, mwiPts, detMWIPts, detThr, detPeakIndices, detPeakTimes)
    }
    
    private func finishCapture() {
        isCapturing = false
        countdownTimer?.invalidate()
        countdownTimer = nil
        let raw = captureBuf
        espRawLast = raw

        // оценка Fs
        var fs = captureFs
        if captureSecs > 0, !raw.isEmpty {
            let measuredFs = Double(raw.count) / captureSecs
            if measuredFs.isFinite, measuredFs > 10 { fs = measuredFs }
        }
        captureFs = fs
        espFs = fs

        let all = processAllESP(raw, fs: fs)
        let rPeaksSec = all.detPeakTimes
        let rawMV = all.rawPts.map { $0.mV }
        let sigMV = ECGSNR.signalForSNR(rawMV, fs: fs)
        let snr = ECGSNR.snrDb(raw: rawMV, signal: sigMV)
        let base = ECGAnalysis.analyticsFromRPeaks(sampleRate: fs, rPeaksSec: rPeaksSec)

        espAnalytics = base.map {
            ECGAnalytics(
                sampleRate: $0.sampleRate,
                rPeaksSec: $0.rPeaksSec,
                avgHR: $0.avgHR,
                sdnn: $0.sdnn,
                rmssd: $0.rmssd,
                appleAvgHR: $0.appleAvgHR,
                classification: $0.classification,
                symptoms: $0.symptoms,
                interpretation: $0.interpretation,
                snrDb: snr
            )
        }
        espSNRdB = snr
        
        espRawPoints = all.rawPts
        espFilteredPoints = all.filtPts
        espPTPoints = all.mwiPts                 // (3) MWI

        espDetMWIPoints = all.detMWIPts          // (4) MWI для детекции
        espDetThr = all.detThr
        espDetPeakTimes = all.detPeakTimes       // секунды
        espDetPeakIndices = all.detPeakIndices
        // базовый сигнал для аналитики
        espLast = all.filtPts

        // Финальный статус — уже после обработки и детекции
        let rrAllMs = ECGAnalysis.rrFromRPeaks(espDetPeakTimes)
        let rrMs = ECGAnalysis.filterRRms(rrAllMs)
        let meanRR = ECGAnalysis.meanRR(rrMs: rrMs) ?? .nan
        let meanHR = meanRR.isFinite ? Int(round(60000.0 / meanRR)) : 0

        espStatus = String(format: "ESP: готово (%d точек, %.0f Гц, %.0f c), HR≈%d bpm, peaks=%d",
                           all.filtPts.count, fs, captureSecs, meanHR, espDetPeakTimes.count)
        saveRawToFileESP(raw: raw, fs: fs)
    }

    private func saveRawToFileESP(raw: [Int16], fs: Double) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = docs.appendingPathComponent("esp-ecg-raw.tsv")

        // 1-я строка — частота
        var out = "fs\t\(fs)\n"
        // дальше по одному значению
        out += raw.map { String($0) }.joined(separator: "\n")

        do {
            try out.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            print("Save raw error: \(error)")
        }
    }

    func loadFromFile() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = docs.appendingPathComponent("esp-ecg-raw.tsv")

        do {
            let s = try String(contentsOf: url, encoding: .utf8)
            let lines = s.split(whereSeparator: \.isNewline)

            guard !lines.isEmpty else {
                espStatus = "Ошибка: файл пуст"
                return
            }

            // header: "fs\t500"
            var fs: Double = 500
            let header = lines[0].split(separator: "\t")
            if header.count == 2, header[0] == "fs", let v = Double(header[1]) {
                fs = v
            }

            var raw: [Int16] = []
            raw.reserveCapacity(max(0, lines.count - 1))

            for line in lines.dropFirst() {
                if let v = Int16(line.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    raw.append(v)
                }
            }

            guard raw.count > 5 else {
                espStatus = "Ошибка: мало данных в файле"
                return
            }

            // сохраняем raw
            espRawLast = raw
            espFs = fs

            // прогоняем фильтры каждый раз
            let all = processAllESP(raw, fs: fs)
            espRawPoints = all.rawPts
            espFilteredPoints = all.filtPts
            espPTPoints = all.mwiPts
            espDetMWIPoints = all.detMWIPts
            espDetThr = all.detThr
            espDetPeakTimes = all.detPeakTimes
            espDetPeakIndices = all.detPeakIndices

            espLast = all.filtPts
            // ---------- SNR (file load) ----------
            let rawMV = all.rawPts.map { $0.mV }
            let sigMV = ECGSNR.signalForSNR(rawMV, fs: fs)
            let snr = ECGSNR.snrDb(raw: rawMV, signal: sigMV)
            espSNRdB = snr

            // если хочешь, чтобы оно было и в espAnalytics:
            let base = ECGAnalysis.analyticsFromRPeaks(sampleRate: fs, rPeaksSec: all.detPeakTimes)
            espAnalytics = base.map {
                ECGAnalytics(
                    sampleRate: $0.sampleRate,
                    rPeaksSec: $0.rPeaksSec,
                    avgHR: $0.avgHR,
                    sdnn: $0.sdnn,
                    rmssd: $0.rmssd,
                    appleAvgHR: $0.appleAvgHR,
                    classification: $0.classification,
                    symptoms: $0.symptoms,
                    interpretation: $0.interpretation,
                    snrDb: snr
                )
            }
            // -------------------------------------
            espStatus = "Загружено RAW (\(raw.count)), обработано → \(all.filtPts.count)"
        } catch {
            espStatus = "Ошибка загрузки: \(error.localizedDescription)"
        }
    }

    private func normalize(raw: [Int16]) -> [Double] {
        if raw.isEmpty { return [] }
        let ints = raw.map { Int($0) }
        let mean = Double(ints.reduce(0, +)) / Double(ints.count)
        let vRef = 3.3
        let fwGain = 8.0                  // тот самый множитель из прошивки
        let scaleVperTick = (vRef / 4095.0) / fwGain
        return ints.map { (Double($0) - mean) * scaleVperTick * 1000.0 } // мВ
    }
}

// MARK: - CBCentralManagerDelegate / CBPeripheralDelegate

extension ESP32Manager: CBCentralManagerDelegate, CBPeripheralDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            espStatus = "ESP: BLE включён, сканирую…"
            central.scanForPeripherals(withServices: [ECG_SVC], options: nil)
        case .poweredOff: espStatus = "ESP: BLE выключен"
        case .unsupported: espStatus = "ESP: BLE не поддерживается"
        default: espStatus = "ESP: состояние \(central.state.rawValue)"
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber) {
        self.peripheral = peripheral
        central.stopScan()
        espStatus = "ESP: подключаюсь к \(peripheral.name ?? "ESP32")…"
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        espStatus = "ESP: подключён. Поиск сервисов…"
        peripheral.discoverServices([ECG_SVC])
    }

    // <<< ВОТ ТУТ БЫЛА ОШИБКА: этот метод должен быть В ЭТОМ extension, а не внутри другого метода >>>
    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        isReady = false
        espStatus = "ESP: отключён"
        // при желании автопоиск:
        // central.scanForPeripherals(withServices: [ECG_SVC], options: nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            espStatus = "ESP: ошибка сервисов: \(error!.localizedDescription)"
            return
        }
        guard let svcs = peripheral.services else { return }
        for s in svcs where s.uuid == ECG_SVC {
            peripheral.discoverCharacteristics([ECG_CHR_CMD, ECG_CHR_STR], for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard error == nil else {
            espStatus = "ESP: ошибка характеристик: \(error!.localizedDescription)"
            return
        }
        guard let chars = service.characteristics else { return }
        for c in chars {
            if c.uuid == ECG_CHR_CMD { ecgCmdChar = c }
            if c.uuid == ECG_CHR_STR {
                ecgStreamChar = c
                peripheral.setNotifyValue(true, for: c)
            }
        }
        isReady = true
        espStatus = "ESP: готов к START"
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard error == nil else { return }
        guard let data = characteristic.value,
              characteristic.uuid == ECG_CHR_STR,
              isCapturing else { return }

        data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            let cnt = ptr.count / 2
            let base = ptr.bindMemory(to: Int16.self)
            for i in 0..<cnt {
                let sLE = Int16(littleEndian: base[i])
                if sLE == .min { continue } // NO SIGNAL
                captureBuf.append(sLE)
            }
        }

        if CFAbsoluteTimeGetCurrent() - captureStartedAt >= captureSecs {
            finishCapture()
        }
    }
}

// MARK: - Biquad (RBJ) и фабрики

/// Второй порядок: y[n] = b0*x[n] + b1*x[n-1] + b2*x[n-2] - a1*y[n-1] - a2*y[n-2]
struct Biquad {
    var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    private var z1: Double = 0, z2: Double = 0   // состояние

    init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    mutating func process(_ x: [Double]) -> [Double] {
        var out = Array(repeating: 0.0, count: x.count)
        var z1 = self.z1, z2 = self.z2
        let b0 = self.b0, b1 = self.b1, b2 = self.b2, a1 = self.a1, a2 = self.a2
        for i in 0..<x.count {
            let w = x[i] - a1*z1 - a2*z2
            let y = b0*w + b1*z1 + b2*z2
            z2 = z1; z1 = w
            out[i] = y
        }
        self.z1 = z1; self.z2 = z2
        return out
    }
}

private enum BQType { case lowpass, highpass, notch }

/// RBJ-формулы; возвращает biquad с нормированными коэф-тами (a0=1)
private func makeBiquad(_ type: BQType, fc: Double, fs: Double, Q: Double) -> Biquad {
    let omega = 2.0 * .pi * max(1e-9, fc) / max(1.0, fs)
    let sn = sin(omega), cs = cos(omega)
    let alpha = sn / (2.0 * Q)

    var b0 = 0.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0

    switch type {
    case .lowpass:
        b0 = (1 - cs) / 2
        b1 = (1 - cs)
        b2 = (1 - cs) / 2
        a0 = 1 + alpha
        a1 = -2 * cs
        a2 = 1 - alpha

    case .highpass:
        b0 = (1 + cs) / 2
        b1 = -(1 + cs)
        b2 = (1 + cs) / 2
        a0 = 1 + alpha
        a1 = -2 * cs
        a2 = 1 - alpha

    case .notch:
        b0 = 1
        b1 = -2 * cs
        b2 = 1
        a0 = 1 + alpha
        a1 = -2 * cs
        a2 = 1 - alpha
    }

    return Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
}
// Каскад HP×2 + LP×2 (один проход)
private func bpCascadeOnce(_ x: [Double], fs: Double,
                           hpFc: Double, lpFc: Double,
                           hpQ: Double, lpQ: Double,
                           notchOn: Bool, notchQ: Double) -> [Double]
{
    var y = x
    if notchOn {
        var nz = makeBiquad(.notch, fc: 50.0, fs: fs, Q: notchQ)
        y = nz.process(y)
    }
    var hp1 = makeBiquad(.highpass, fc: hpFc, fs: fs, Q: hpQ)
    var hp2 = makeBiquad(.highpass, fc: hpFc, fs: fs, Q: hpQ)
    var lp1 = makeBiquad(.lowpass,  fc: lpFc, fs: fs, Q: lpQ)
    var lp2 = makeBiquad(.lowpass,  fc: lpFc, fs: fs, Q: lpQ)
    y = hp1.process(y)
    y = hp2.process(y)
    y = lp1.process(y)
    y = lp2.process(y)
    return y
}

// 5-точечное скользящее среднее (очень мягкое сглаживание)
private func smooth5(_ x: [Double]) -> [Double] {
    guard x.count >= 5 else { return x }
    var y = x
    for i in 2..<(x.count - 2) {
        y[i] = (x[i-2] + x[i-1] + x[i] + x[i+1] + x[i+2]) / 5.0
    }
    // края оставим как есть (или можно копировать ближайшие)
    y[0] = x[0]; y[1] = x[1]
    y[y.count-2] = x[x.count-2]
    y[y.count-1] = x[x.count-1]
    return y
}

// Нуль-фазовый вариант: прямой → reverse → тот же каскад → reverse
private func bpZeroPhase(_ x: [Double], fs: Double,
                         hpFc: Double, lpFc: Double,
                         hpQ: Double, lpQ: Double,
                         notchOn: Bool, notchQ: Double) -> [Double]
{
    let y1 = bpCascadeOnce(x, fs: fs, hpFc: hpFc, lpFc: lpFc, hpQ: hpQ, lpQ: lpQ, notchOn: notchOn, notchQ: notchQ)
    let y1r = Array(y1.reversed())
    let y2r = bpCascadeOnce(y1r, fs: fs, hpFc: hpFc, lpFc: lpFc, hpQ: hpQ, lpQ: lpQ, notchOn: notchOn, notchQ: notchQ)
    return Array(y2r.reversed())
}
extension ECGAnalysis {

    struct RPeakDebug {
        let integ: [Double]      // это и будет MWI
        let thr: Double          // порог (пока константа)
        let peaks: [Int]         // индексы R-пиков в исходном signal
    }

    static func detectRPeaksDebug(signal: [Double], fs: Double) -> RPeakDebug {
        guard signal.count > 4, fs > 0 else {
            return .init(integ: [], thr: 0, peaks: [])
        }

        // 1) Дифференциальный отклик (~40 мс)
        let w = max(3, Int(max(0.04 * fs, 3)))
        var diff = [Double](repeating: 0, count: signal.count)
        for i in w..<signal.count {
            diff[i] = signal[i] - signal[i - w]
        }

        // 2) Интегратор (~120 мс) с диодом (только положит.)
        let m = max(1, Int(0.12 * fs))
        var integ = [Double](repeating: 0, count: signal.count)
        var sum = 0.0
        for i in 0..<signal.count {
            let v = max(0, diff[i])
            sum += v
            if i >= m { sum -= max(0, diff[i - m]) }
            integ[i] = sum / Double(min(i + 1, m))
        }

        // 3) Порог: mean + k*std
        let mean = integ.reduce(0, +) / Double(integ.count)
        let std  = sqrt(integ.reduce(0) { $0 + pow($1 - mean, 2) } / Double(integ.count))
        let k: Double = 0.75
        let thr = mean + k * std

        // 3b) Амплитудный порог по “сырым” мВ
        let meanSig = signal.reduce(0, +) / Double(signal.count)
        let stdSig  = sqrt(signal.reduce(0) { $0 + pow($1 - meanSig, 2) } / Double(signal.count))
        let ampThr  = 0.35 * stdSig

        // 4) Рефрактер 300 мс (как у тебя)
        let refr = Int(0.30 * fs)

        // 5) Поиск локальных максимумов интегратора, привязка к R-пику
        var peaks: [Int] = []
        var i = 1
        while i < integ.count - 1 {
            if integ[i] > thr, integ[i] > integ[i - 1], integ[i] >= integ[i + 1] {
                let win = max(1, Int(0.05 * fs))     // ±50 мс
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

                let ampOK = (vmax - vmin) >= ampThr
                if ampOK && (peaks.isEmpty || imax - peaks.last! > refr) {
                    peaks.append(imax)
                    i = imax + refr
                    continue
                }
            }
            i += 1
        }

        return .init(integ: integ, thr: thr, peaks: peaks)
    }
}
