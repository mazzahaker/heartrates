//
//  XIAOManager.swift
//  heartrates
//
//  Created by mazzahaker on 3/10/25.
//

import Foundation
import CoreBluetooth

@MainActor
final class XIAOManager: NSObject, ObservableObject {
    
    // MARK: Published state (XIAO-only)
    @Published var xiaoStatus: String = "XIAO: не подключён"
    @Published var xiaoLast: [ECGPoint] = []
    @Published var xiaoRawLast: [Int16] = []
    @Published var xiaoFs: Double = 512
    @Published var isReady: Bool = false
    @Published var xiaoRawPoints: [ECGPoint] = []
    @Published var xiaoFilteredPoints: [ECGPoint] = []
    @Published var xiaoPTPoints: [ECGPoint] = []
    @Published var xiaoSignalPeakIndices: [Int] = []
    @Published var xiaoDetMWIPoints: [ECGPoint] = []
    @Published var xiaoDetThr: Double = 0
    @Published var xiaoDetPeakTimes: [Double] = []
    @Published var xiaoSNRdB: Double? = nil
    @Published var xiaoAnalytics: ECGAnalytics? = nil
    @Published var xiaoDetPeakIndices: [Int] = []
    
    // MARK: BLE
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var ecgCmdChar: CBCharacteristic?
    private var ecgStreamChar: CBCharacteristic?
    
    // UUID — те же, что у ESP, прошивка XIAO шлёт их же
    private let ECG_SVC     = CBUUID(string: "ec000001-0000-4000-8000-00000000ec01")
    private let ECG_CHR_CMD = CBUUID(string: "ec000002-0000-4000-8000-00000000ec01") // write
    private let ECG_CHR_STR = CBUUID(string: "ec000003-0000-4000-8000-00000000ec01") // notify
    private let XIAO_NAME_PREFIX = "XIAO-ECG"
    
    // MARK: capture
    private var isCapturing = false
    private var captureStartedAt: CFAbsoluteTime = 0
    private var captureBuf: [Int16] = []
    private var captureSecs: Double = 30
    private var captureFs: Double = 512
    private var countdownTimer: Timer?
    
    
    // MARK: фильтры (настройки — как у ESP)
    private let ZERO_PHASE  = true       // как у ESP
    private let USE_NOTCH   = true
    private let NOTCH_Q     = 30.0
    
    private let HP_FC       = 3.0        // Гц (у ESP ~0.5–0.7)
    private let LP_FC       = 15.0       // Гц (у ESP ~35–40)
    private let HP_Q        = 0.7071
    private let LP_Q        = 0.7071
    
    // MARK: Public API
    
    func connect() {
        isReady = false
        if central == nil {
            central = CBCentralManager(delegate: self, queue: nil)
            xiaoStatus = "XIAO: инициализация BLE…"
        } else {
            central.scanForPeripherals(withServices: nil,
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            xiaoStatus = "XIAO: сканирование…"
        }
    }
    
    func startCapture5s() {
        guard isReady else { xiaoStatus = "XIAO: не подключён"; return }
        guard let c = ecgCmdChar else { xiaoStatus = "XIAO: нет характеристик"; return }
        
        xiaoStatus = "XIAO: получение данных (\(Int(captureSecs)) с)…"
        isCapturing = true
        captureBuf.removeAll(keepingCapacity: true)
        captureStartedAt = CFAbsoluteTimeGetCurrent()
        xiaoRawLast.removeAll(keepingCapacity: true)
        xiaoLast.removeAll(keepingCapacity: true)
        
        if let s = ecgStreamChar, s.isNotifying != true {
            peripheral?.setNotifyValue(true, for: s)
        }
        
        // start hard countdown to avoid "endless capture" if no notifications arrive
        countdownTimer?.invalidate()
        let startedAt = CFAbsoluteTimeGetCurrent()
        captureStartedAt = startedAt
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] t in
            Task { @MainActor [weak self] in
                guard let self = self else { t.invalidate(); return }
                let elapsed = CFAbsoluteTimeGetCurrent() - startedAt
                if elapsed >= self.captureSecs {
                    t.invalidate()
                    self.finishCapture()
                } else {
                    let left = Int(ceil(self.captureSecs - elapsed))
                    self.xiaoStatus = "XIAO: получение данных (\(left) с)…"
                }
            }
        }
        
        let payload = Data("START".utf8)
        let writeType: CBCharacteristicWriteType = c.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        peripheral?.writeValue(payload, for: c, type: writeType)    }
    
    func reset() {
        countdownTimer?.invalidate()
        isCapturing = false
        captureBuf.removeAll(keepingCapacity: true)
        xiaoDetPeakIndices.removeAll(keepingCapacity: true)
        xiaoSignalPeakIndices.removeAll(keepingCapacity: true)
        xiaoRawLast.removeAll(keepingCapacity: true)
        xiaoLast.removeAll(keepingCapacity: true)

        xiaoRawPoints.removeAll(keepingCapacity: true)
        xiaoFilteredPoints.removeAll(keepingCapacity: true)
        xiaoPTPoints.removeAll(keepingCapacity: true)
        xiaoDetMWIPoints.removeAll(keepingCapacity: true)
        xiaoDetThr = 0
        xiaoDetPeakTimes.removeAll(keepingCapacity: true)
        xiaoStatus = "XIAO: очищено"
    }
    
    private func processAllXIAO(_ raw: [Int16], fs: Double)
    -> (
        rawPts: [ECGPoint],
        filtPts: [ECGPoint],
        ptPts: [ECGPoint],
        detMWI: [ECGPoint],
        detThr: Double,
        detPeakIndices: [Int],
        detPeakTimes: [Double],
        signalPeakIndices: [Int]
    )
    {
        
        let rawMV = normalize(raw: raw)
        let rawPts = buildPoints(rawMV, fs: fs)
        
        let y = bpZeroPhaseX(rawMV, fs: fs,
                             hpFc: HP_FC, lpFc: LP_FC,
                             hpQ:  HP_Q,  lpQ:  LP_Q,
                             notchOn: USE_NOTCH, notchQ: NOTCH_Q)
        
        let ySmooth = smooth5(y)
        let filtPts = buildPoints(ySmooth, fs: fs)
        let mwi = PTStages.mwiSignal(from: ySmooth, fs: fs)
        let ptPts = buildPoints(mwi, fs: fs)
        
        // detection (MWI+thr+peaks)
        let mwiSignal = mwi
        let (peakIdx, thrSeries) = ECGAnalysis.detectRPeaksPT(mwi: mwiSignal, fs: fs)

        let detMWI = buildPoints(mwiSignal, fs: fs)
        // для графика
        let detPeakIndices = peakIdx

        // для аналитики
        let refinedPeakIdx = ECGAnalysis.refineRPeakIndices(peakIdx, on: ySmooth, fs: fs)
        let detPeakTimes = refinedPeakIdx.map { Double($0) / fs }
        let displayPeakIdx = ECGAnalysis.refineDisplayPeakIndices(peakIdx, on: ySmooth, fs: fs)
        let detThr = thrSeries.last ?? 0.0
        let signalPeakIndices = displayPeakIdx
        
        return (
            rawPts,
            filtPts,
            ptPts,
            detMWI,
            detThr,
            detPeakIndices,
            detPeakTimes,
            signalPeakIndices
        )
    }
    
    func loadFromFileXIAO() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = docs.appendingPathComponent("xiao-ecg-raw.tsv")

        do {
            let s = try String(contentsOf: url, encoding: .utf8)
            let lines = s.split(whereSeparator: \.isNewline)
            guard !lines.isEmpty else { xiaoStatus = "XIAO: файл пуст"; return }

            // header fs
            var fs: Double = 512
            let header = lines[0].split(separator: "\t")
            if header.count == 2, header[0] == "fs", let v = Double(header[1]) {
                fs = v
            }

            // raw
            var raw: [Int16] = []
            raw.reserveCapacity(max(0, lines.count - 1))
            for line in lines.dropFirst() {
                if let v = Int16(line.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    raw.append(v)
                }
            }
            guard raw.count > 5 else { xiaoStatus = "XIAO: мало данных"; return }

            xiaoRawLast = raw
            xiaoFs = fs

            // 3 сигнала
            let all = processAllXIAO(raw, fs: fs)
            xiaoRawPoints = all.rawPts
            xiaoFilteredPoints = all.filtPts
            xiaoPTPoints = all.ptPts
            xiaoDetMWIPoints = all.detMWI
            xiaoDetThr = all.detThr
            xiaoDetPeakIndices = all.detPeakIndices
            xiaoDetPeakTimes = all.detPeakTimes
            xiaoSignalPeakIndices = all.signalPeakIndices
            xiaoLast = all.filtPts
            // ---------- SNR (file load) ----------
            let rawMV = all.rawPts.map { $0.mV }
            let sigMV = ECGSNR.signalForSNR(rawMV, fs: fs)
            let snr = ECGSNR.snrDb(raw: rawMV, signal: sigMV)
            xiaoSNRdB = snr

            // если хочешь, чтобы было и в xiaoAnalytics:
            let base = ECGAnalysis.analyticsFromRPeaks(sampleRate: fs, rPeaksSec: all.detPeakTimes)
            xiaoAnalytics = base.map {
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
            xiaoStatus = "XIAO: загружено RAW (\(raw.count)), обработано → \(all.filtPts.count), peaks → \(all.detPeakTimes.count)"
        } catch {
            xiaoStatus = "XIAO: ошибка загрузки: \(error.localizedDescription)"
        }
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
    
    private func buildPoints(from samples: [Int16], fs: Double) -> [ECGPoint] {
        let dt = 1.0 / fs
        var t = 0.0
        var out = [ECGPoint]()
        out.reserveCapacity(samples.count)
        for s in samples {
            // если у тебя есть свой коэффициент перевода в мВ — поставь его вместо Double(s)
            out.append(ECGPoint(t: t, mV: Double(s)))
            t += dt
        }
        return out
    }
    private func processRawXIAO(_ raw: [Int16], fs: Double) -> [ECGPoint] {
        let x = normalize(raw: raw)
        let y = bpZeroPhaseX(
            x, fs: fs,
            hpFc: HP_FC, lpFc: LP_FC,
            hpQ:  HP_Q,  lpQ:  LP_Q,
            notchOn: USE_NOTCH, notchQ: NOTCH_Q
        )
        let ySmooth = smooth5(y)

        var pts: [ECGPoint] = []
        pts.reserveCapacity(ySmooth.count)
        let dt = 1.0 / fs
        var t = 0.0
        for v in ySmooth {
            pts.append(ECGPoint(t: t, mV: v))
            t += dt
        }
        return pts
    }
    
    private func finishCapture() {
        countdownTimer?.invalidate()
        isCapturing = false

        let raw = captureBuf
        captureBuf.removeAll(keepingCapacity: true)

        guard !raw.isEmpty else {
            xiaoLast = []
            xiaoRawLast = []
            xiaoFs = 512
            xiaoStatus = "XIAO: пусто (0 точек, 512 Гц, 0.0 c)"
            return
        }

        let fs: Double = 512
        xiaoFs = fs
        xiaoRawLast = raw
        let all = processAllXIAO(raw, fs: fs)
        let rawMV = all.rawPts.map { $0.mV }
        let sigMV = ECGSNR.signalForSNR(rawMV, fs: fs)
        let snr = ECGSNR.snrDb(raw: rawMV, signal: sigMV)

        let rPeaksSec = all.detPeakTimes
        let base = ECGAnalysis.analyticsFromRPeaks(sampleRate: fs, rPeaksSec: rPeaksSec)
        
        xiaoAnalytics = base.map {
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
        xiaoSNRdB = snr
        xiaoDetMWIPoints = all.detMWI
        xiaoDetThr = all.detThr
        xiaoDetPeakIndices = all.detPeakIndices
        xiaoDetPeakTimes = all.detPeakTimes
        xiaoSignalPeakIndices = all.signalPeakIndices
        xiaoRawPoints = all.rawPts
        xiaoFilteredPoints = all.filtPts
        xiaoPTPoints = all.ptPts
        
        xiaoLast = all.filtPts

        xiaoStatus = String(
            format: "XIAO: готово (%d точек, %.0f Гц, %.1f c)",
            xiaoLast.count, fs, Double(xiaoLast.count) / fs
        )

        saveRawToFileXIAO(raw: raw, fs: fs)
    }
    
    private func saveRawToFileXIAO(raw: [Int16], fs: Double) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = docs.appendingPathComponent("xiao-ecg-raw.tsv")

        var out = "fs\t\(fs)\n"
        out += raw.map { String($0) }.joined(separator: "\n")
        try? out.write(to: url, atomically: true, encoding: .utf8)
    }
    
    private func saveToFileXIAO(points: [ECGPoint]) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = docs.appendingPathComponent("xiao-ecg.log")
        let lines = points.map { "\($0.t)\t\($0.mV)" }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
    
    // перевод сырья Int16 → мВ (как у ESP)
    private func normalize(raw: [Int16]) -> [Double] {
        if raw.isEmpty { return [] }
        var x = raw.map(Double.init)
        
        // 1) убрать DC
        let mean = x.reduce(0,+) / Double(x.count)
        for i in x.indices { x[i] -= mean }
        
        // 2) robust scale (MAD)
        let sorted = x.sorted()
        let m = sorted[sorted.count/2]
        var absdev = x.map { abs($0 - m) }.sorted()
        let mad = absdev[absdev.count/2] * 1.4826
        let s = (mad.isFinite && mad > 1e-9) ? mad : max(std(x), 1.0)
        
        // 3) масштабирование (без клипа, чтобы не «срезать» R-пики)
        let y = x.map { $0 / s }
        return y
    }
    
    // вспомогательная
    private func std(_ a: [Double]) -> Double {
        if a.isEmpty { return 1.0 }
        let mu = a.reduce(0,+) / Double(a.count)
        let v = a.reduce(0) { $0 + ($1 - mu)*($1 - mu) } / Double(a.count)
        return sqrt(max(v, 1e-12))
    }
}

// MARK: CoreBluetooth delegates
extension XIAOManager: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            xiaoStatus = "XIAO: BLE включён, сканирую…"
            central.scanForPeripherals(withServices: nil,
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        case .poweredOff: xiaoStatus = "XIAO: BLE выключен"
        case .unsupported: xiaoStatus = "XIAO: BLE не поддерживается"
        default: xiaoStatus = "XIAO: состояние \(central.state.rawValue)"
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber) {

        // 1) Быстрый фильтр по имени
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        var match = name.hasPrefix(XIAO_NAME_PREFIX)

        // 2) Если имени нет/не совпало — попробуем по рекламируемым UUID
        if !match {
            if let uuids = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
                match = uuids.contains(ECG_SVC)
            }
        }

        guard match else { return }

        self.peripheral = peripheral
        central.stopScan()
        xiaoStatus = "XIAO: подключаюсь к \(name.isEmpty ? "устройству" : name)…"

        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        xiaoStatus = "XIAO: подключён. Поиск сервисов…"
        peripheral.discoverServices([ECG_SVC])
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        if isCapturing { countdownTimer?.invalidate(); isCapturing = false }
        isReady = false
        xiaoStatus = "XIAO: отключён"
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            xiaoStatus = "XIAO: ошибка сервисов: \(error!.localizedDescription)"
            return
        }
        for s in (peripheral.services ?? []) where s.uuid == ECG_SVC {
            peripheral.discoverCharacteristics([ECG_CHR_CMD, ECG_CHR_STR], for: s)
        }
    }

    
    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard error == nil else {
            xiaoStatus = "XIAO: ошибка характеристик: \(error!.localizedDescription)"
            return
        }
        for c in (service.characteristics ?? []) {
            if c.uuid == ECG_CHR_CMD { ecgCmdChar = c }
            if c.uuid == ECG_CHR_STR {
                ecgStreamChar = c
                peripheral.setNotifyValue(true, for: c)
            }
        }
        isReady = true
        xiaoStatus = "XIAO: готов к START"
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let e = error {
            countdownTimer?.invalidate()
            isCapturing = false
            xiaoStatus = "XIAO: ошибка START: \(e.localizedDescription)"
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard error == nil else { return }
        guard isCapturing,
              characteristic.uuid == ECG_CHR_STR,
              let data = characteristic.value
        else { return }

        var sawEOS = false
        data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            let cnt  = ptr.count / 2
            let base = ptr.bindMemory(to: Int16.self)
            for i in 0..<cnt {
                let s = Int16(littleEndian: base[i])
                if s == .min { sawEOS = true; break } // EOS-маркер
                captureBuf.append(s)
            }
        }

        if sawEOS {
            finishCapture()
            return
        }

        if CFAbsoluteTimeGetCurrent() - captureStartedAt >= captureSecs {
            finishCapture()
        }
    }
}

// MARK: — Локальная версия biquad, чтобы не конфликтовать с ESP
private struct XBiquad {
    var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    private var z1: Double = 0, z2: Double = 0

    init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
        self.z1 = 0
        self.z2 = 0
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

private enum XBQType { case lowpass, highpass, notch }

private func makeXBiquad(_ type: XBQType, fc: Double, fs: Double, Q: Double) -> XBiquad {
    let omega = 2.0 * .pi * max(1e-9, fc) / max(1.0, fs)
    let sn = sin(omega), cs = cos(omega)
    let alpha = sn / (2.0 * Q)
    var b0=0.0, b1=0.0, b2=0.0, a0=1.0, a1=0.0, a2=0.0

    switch type {
    case .lowpass:
        b0 = (1 - cs) / 2; b1 = (1 - cs); b2 = (1 - cs) / 2
        a0 = 1 + alpha; a1 = -2 * cs; a2 = 1 - alpha
    case .highpass:
        b0 = (1 + cs) / 2; b1 = -(1 + cs); b2 = (1 + cs) / 2
        a0 = 1 + alpha; a1 = -2 * cs; a2 = 1 - alpha
    case .notch:
        b0 = 1; b1 = -2 * cs; b2 = 1
        a0 = 1 + alpha; a1 = -2 * cs; a2 = 1 - alpha
    }

    return XBiquad(b0: b0/a0, b1: b1/a0, b2: b2/a0, a1: a1/a0, a2: a2/a0)
}

private func bpCascadeOnceX(_ x: [Double], fs: Double,
                            hpFc: Double, lpFc: Double,
                            hpQ: Double, lpQ: Double,
                            notchOn: Bool, notchQ: Double) -> [Double] {
    var y = x
    if notchOn {
        var nz = makeXBiquad(.notch, fc: 50.0, fs: fs, Q: notchQ)
        y = nz.process(y)
    }
    var hp1 = makeXBiquad(.highpass, fc: hpFc, fs: fs, Q: hpQ)
    var hp2 = makeXBiquad(.highpass, fc: hpFc, fs: fs, Q: hpQ)
    var lp1 = makeXBiquad(.lowpass,  fc: lpFc, fs: fs, Q: lpQ)
    var lp2 = makeXBiquad(.lowpass,  fc: lpFc, fs: fs, Q: lpQ)
    y = hp1.process(y); y = hp2.process(y)
    y = lp1.process(y); y = lp2.process(y)
    return y
}

private func bpZeroPhaseX(_ x: [Double], fs: Double,
                          hpFc: Double, lpFc: Double,
                          hpQ: Double, lpQ: Double,
                          notchOn: Bool, notchQ: Double) -> [Double] {
    let y1  = bpCascadeOnceX(x,  fs: fs, hpFc: hpFc, lpFc: lpFc, hpQ: hpQ, lpQ: lpQ, notchOn: notchOn, notchQ: notchQ)
    let y1r = Array(y1.reversed())
    let y2r = bpCascadeOnceX(y1r, fs: fs, hpFc: hpFc, lpFc: lpFc, hpQ: hpQ, lpQ: lpQ, notchOn: notchOn, notchQ: notchQ)
    return Array(y2r.reversed())
}
private func smooth5(_ x: [Double]) -> [Double] {
    if x.count < 5 { return x }
    var out = x
    out[0] = (x[0] + x[1]) / 2
    out[1] = (x[0] + x[1] + x[2]) / 3
    for i in 2..<(x.count - 2) {
        out[i] = (x[i-2] + x[i-1] + x[i] + x[i+1] + x[i+2]) / 5
    }
    out[x.count - 2] = (x[x.count - 3] + x[x.count - 2] + x[x.count - 1]) / 3
    out[x.count - 1] = (x[x.count - 2] + x[x.count - 1]) / 2
    return out
}
