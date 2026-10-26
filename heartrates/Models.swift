//
//  Models.swift
//  heartrates
//
//  Created by mazzahaker on 17/8/25.
//

import Foundation

public struct ECGPoint: Identifiable, Hashable {
    public let id = UUID()
    public let t: Double    // секунды от начала записи
    public let mV: Double   // миллиВольты

    public init(t: Double, mV: Double) {
        self.t = t
        self.mV = mV
    }
}

struct HRPoint: Identifiable {
    let id = UUID()
    let t: TimeInterval   // время
    let bpm: Double
}

/// Аналитика ЭКГ
struct ECGAnalytics {
    let sampleRate: Double
    let rPeaksSec: [Double]

    // наши расчёты (HRV и пр.)
    let avgHR: Double?
    let sdnn: Double?
    let rmssd: Double?
    // официальные метрики Apple
    let appleAvgHR: Double?   // bpm
    let classification: String?
    let symptoms: String?
    let interpretation: ECGInterpretation?
    let snrDb: Double?
}
