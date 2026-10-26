//
//  AppViewModel.swift
//  heartrates
//
//  Created by mazzahaker on 17/8/25.
//

import Foundation
import HealthKit

@MainActor
final class AppViewModel: NSObject, ObservableObject {

    @Published var ecg: [ECGPoint] = []
    @Published var hr:  [HRPoint] = []
    @Published var analytics: ECGAnalytics?
    @Published var status: String = "Готово"

    private let store = HKHealthStore()
    
    // MARK: - Simple smoothing for SNR (Apple Watch)
    private func smooth5(_ x: [Double]) -> [Double] {
        guard x.count >= 5 else { return x }

        var y = x
        for i in 2..<(x.count - 2) {
            y[i] = (x[i-2] + x[i-1] + x[i] + x[i+1] + x[i+2]) / 5.0
        }

        return y
    }
    // MARK: Auth
    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            status = "HealthKit недоступен"
            return
        }
        do {
            let types: Set = [
                HKObjectType.electrocardiogramType(),
                HKObjectType.quantityType(forIdentifier: .heartRate)!
            ]
            try await store.requestAuthorization(toShare: [], read: types)
            status = "Разрешения выданы"
        } catch {
            status = "Auth error: \(error.localizedDescription)"
        }
    }

    // MARK: Observer
    func startECGObserver() {
        let type = HKObjectType.electrocardiogramType()
        let obs = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, _ in
            self?.fetchLatestECGFull()
            completion()
        }
        store.execute(obs)
        store.enableBackgroundDelivery(for: type, frequency: .immediate) { [weak self] success, error in
            if let error {
                Task { @MainActor in self?.status = "BG delivery error: \(error.localizedDescription)" }
            } else if success {
                Task { @MainActor in self?.status = "Наблюдение за ЭКГ включено" }
            }
        }
    }

    // MARK: Read latest ECG
    func fetchLatestECGFull() {
        status = "Читаем ЭКГ…"

        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let q = HKSampleQuery(sampleType: HKObjectType.electrocardiogramType(),
                              predicate: nil,
                              limit: 1,
                              sortDescriptors: [sort]) { [weak self] _, samples, error in
            guard let self else { return }
            if let error {
                Task { @MainActor in self.status = "Ошибка запроса: \(error.localizedDescription)" }
                return
            }
            guard let sample = samples?.first as? HKElectrocardiogram else {
                Task { @MainActor in self.status = "ЭКГ не найдено" }
                return
            }

            // метрики Apple (как в приложении «ЭКГ»)
            let appleBpm = sample.averageHeartRate?.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
            let classificationStr: String = {
                switch sample.classification {
                case .notSet: return "Не задано"
                case .sinusRhythm: return "Синусовый ритм"
                case .atrialFibrillation: return "Фибрилляция предсердий"
                case .inconclusiveLowHeartRate: return "Неоднозначно (низкий пульс)"
                case .inconclusiveHighHeartRate: return "Неоднозначно (высокий пульс)"
                case .inconclusivePoorReading: return "Неоднозначно (помехи)"
                case .inconclusiveOther: return "Неоднозначно"
                case .unrecognized: return "Не распознано"
                @unknown default: return "Неизвестно"
                }
            }()
            let symptomsStr: String? = {
                switch sample.symptomsStatus {
                case .notSet: return nil
                case .none: return "Симптомы: нет"
                case .present: return "Симптомы: указаны"
                @unknown default: return nil
                }
            }()

            var pts: [ECGPoint] = []
            let eq = HKElectrocardiogramQuery(sample) { _, result in
                switch result {
                case .measurement(let m):
                    if let v = m.quantity(for: .appleWatchSimilarToLeadI)?.doubleValue(for: .volt()) {
                        pts.append(ECGPoint(t: m.timeSinceSampleStart, mV: v * 1000.0))
                    }
                case .done:
                    Task.detached(priority: .userInitiated) { [pts] in
                        let computed = ECGAnalysis.compute(points: pts)
                        // ---------- SNR Apple Watch ----------
                        let rawMV = pts.map { $0.mV }
                        let sigMV = self.smooth5(rawMV)
                        let snr = ECGSNR.snrDb(raw: rawMV, signal: sigMV)
                        // --------------------------------------
                        let final = ECGAnalytics(
                            sampleRate: computed?.sampleRate ?? 512,
                            rPeaksSec: computed?.rPeaksSec ?? [],
                            avgHR: computed?.avgHR,
                            sdnn: computed?.sdnn,
                            rmssd: computed?.rmssd,
                            appleAvgHR: appleBpm,
                            classification: classificationStr,
                            symptoms: symptomsStr,
                            interpretation: computed?.interpretation,
                            snrDb: snr
                        )
                        await MainActor.run { [weak self] in
                            guard let self else { return }
                            self.ecg = pts
                            self.analytics = final
                            self.status = "ЭКГ получено (\(pts.count) точек, \(String(format: "%.1f", pts.last?.t ?? 0)) c)"                        }
                    }
                case .error(let e):
                    Task { @MainActor in self.status = "Ошибка чтения ЭКГ: \(e.localizedDescription)" }
                @unknown default: break
                }
            }
            self.store.execute(eq)
        }
        store.execute(q)
    }

    func reset() {
        ecg.removeAll()
        hr.removeAll()
        analytics = nil
        status = "Готово"
    }
}
