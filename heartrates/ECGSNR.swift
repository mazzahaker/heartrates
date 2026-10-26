//
//  ECGSNR.swift
//  heartrates
//
//  Created by Vladlen Melnik on 1/3/26.
//

import Foundation

enum ECGSNR {
    
    static func rms(_ x: [Double]) -> Double {
        guard !x.isEmpty else { return 0 }
        let s = x.reduce(0.0) { $0 + $1*$1 }
        return sqrt(s / Double(x.count))
    }
    
    /// SNR(dB) = 20*log10(rms(signal)/rms(noise)), noise = raw - signal
    static func snrDb(raw: [Double], signal: [Double]) -> Double? {
        let n = min(raw.count, signal.count)
        guard n > 16 else { return nil }
        
        var noise = [Double]()
        noise.reserveCapacity(n)
        
        for i in 0..<n {
            noise.append(raw[i] - signal[i])
        }
        
        let rs = rms(Array(signal.prefix(n)))
        let rn = rms(noise)
        
        guard rs.isFinite, rn.isFinite, rs > 0, rn > 0 else { return nil }
        return 20.0 * log10(rs / rn)
    }
    static func signalForSNR(_ raw: [Double], fs: Double) -> [Double] {
        // клинический диапазон ЭКГ
        return bpZeroPhaseGlobal(
            raw,
            fs: fs,
            hpFc: 0.5,
            lpFc: 40.0,
            hpQ: 0.7071,
            lpQ: 0.7071,
            notchOn: true,
            notchQ: 30.0
        )
    }}

