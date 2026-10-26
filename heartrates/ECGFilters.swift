//
//  ECGFilters.swift
//  heartrates
//
//  Created by Vladlen Melnik on 1/3/26.
//

import Foundation

// MARK: - Global Biquad

struct GlobalBiquad {
    var b0: Double
        var b1: Double
        var b2: Double
        var a1: Double
        var a2: Double
    private var z1: Double = 0, z2: Double = 0
    
    init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }
    mutating func process(_ x: [Double]) -> [Double] {
        var out = Array(repeating: 0.0, count: x.count)
        var z1 = self.z1
        var z2 = self.z2

        for i in 0..<x.count {
            let w = x[i] - a1*z1 - a2*z2
            let y = b0*w + b1*z1 + b2*z2
            z2 = z1
            z1 = w
            out[i] = y
        }

        self.z1 = z1
        self.z2 = z2
        return out
    }
}

private enum GlobalBQType { case lowpass, highpass, notch }

private func makeGlobalBiquad(_ type: GlobalBQType,
                              fc: Double,
                              fs: Double,
                              Q: Double) -> GlobalBiquad {

    let omega = 2.0 * .pi * fc / fs
    let sn = sin(omega)
    let cs = cos(omega)
    let alpha = sn / (2.0 * Q)

    var b0 = 0.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0

    switch type {
    case .lowpass:
        b0 = (1 - cs) / 2
        b1 = 1 - cs
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

    return GlobalBiquad(
        b0: b0/a0,
        b1: b1/a0,
        b2: b2/a0,
        a1: a1/a0,
        a2: a2/a0
    )
}

// MARK: - Zero Phase

func bpZeroPhaseGlobal(_ x: [Double],
                       fs: Double,
                       hpFc: Double,
                       lpFc: Double,
                       hpQ: Double,
                       lpQ: Double,
                       notchOn: Bool,
                       notchQ: Double) -> [Double] {

    func cascade(_ input: [Double]) -> [Double] {
        var y = input

        if notchOn {
            var nz = makeGlobalBiquad(.notch, fc: 50.0, fs: fs, Q: notchQ)
            y = nz.process(y)
        }

        var hp1 = makeGlobalBiquad(.highpass, fc: hpFc, fs: fs, Q: hpQ)
        var hp2 = makeGlobalBiquad(.highpass, fc: hpFc, fs: fs, Q: hpQ)
        var lp1 = makeGlobalBiquad(.lowpass,  fc: lpFc, fs: fs, Q: lpQ)
        var lp2 = makeGlobalBiquad(.lowpass,  fc: lpFc, fs: fs, Q: lpQ)

        y = hp1.process(y)
        y = hp2.process(y)
        y = lp1.process(y)
        y = lp2.process(y)

        return y
    }

    let y1 = cascade(x)
    let y1r = Array(y1.reversed())
    let y2r = cascade(y1r)
    return Array(y2r.reversed())
}
