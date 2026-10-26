//
//  PDFExporter.swift
//  heartrates
//
//  Created by mazzahaker on 17/8/25.
//

import UIKit
import SwiftUI

// A4 @ 72 dpi
private let pageSize = CGSize(width: 595, height: 842)

// mm -> pt @72dpi
private let ptPerMM: CGFloat = 72.0 / 25.4
private let mm1: CGFloat = ptPerMM

// Медицинские стандарты
private let mmPerSecond: CGFloat = 25.0      // 25 мм/с
private let mmPerMilliVolt: CGFloat = 10.0   // 10 мм/мВ

// Layout
private let pageMargin: CGFloat = 32
private let plotOuterTop: CGFloat = 64
private let rowSpacing: CGFloat = 8

enum ECGPDFSource { case appleWatch, esp32, xiao }

enum PDFExporter {
    private static func preparePaperFilteredFromRawForPDF(_ points: [ECGPoint], source: ECGPDFSource) -> [ECGPoint] {
        let pts = sanitizeMonotonic(points)
        guard pts.count > 10 else { return pts }

        // decimate до ~200 Гц (как у остальных)
        let fs0 = estimateFs(from: pts)
        let targetFs = 200.0
        let factor = max(1, Int(round(fs0 / targetFs)))
        let dec = decimate(points: pts, factor: factor)

        let fs = estimateFs(from: dec)
        var y = dec.map { $0.mV }

        // 1) baseline removal (мягко)
        let winHP = max(3, Int(round(0.3 * fs)))
        let baseline = movingAverageZeroPhase(y, window: winHP)
        for i in y.indices { y[i] -= baseline[i] }

        // 2) low-pass для "бумажного" вида
        y = lowpassMovingAverage(y, fs: fs, fc: 40.0)

        // 3) чуть-чуть прибрать единичные выбросы (но не убивать морфологию!)
        y = medianFilter(y, window: 3)   // для AW лучше 3, не 5

        // ВАЖНО: никаких k-нормализаций по амплитуде для AW
        // иначе реальный масштаб 10 мм/мВ становится "нечестным"

        // лёгкая страховка от совсем диких выбросов (опционально)
        let clipMV = 3.0
        for i in y.indices {
            if y[i] > clipMV { y[i] = clipMV }
            else if y[i] < -clipMV { y[i] = -clipMV }
        }

        return zip(dec, y).map { (p, mv) in ECGPoint(t: p.t, mV: mv) }
    }
    // MARK: - PUBLIC (4 pages)
    static func makePDF(
        raw: [ECGPoint],
        filtered: [ECGPoint],
        mwi: [ECGPoint],
        detMWI: [ECGPoint],
        detThr: Double,
        detPeakTimes: [Double],
        signalMarkerPoints: [ECGPoint] = [],
        analytics: ECGAnalytics?,
        source: ECGPDFSource
    ) -> Data? {

        guard raw.count > 1 || filtered.count > 1 else { return nil }

        // 1) RAW: baseline-removal + clamp + decimate (без “красивой” нормализации)
        let rawPrepared = prepareRawPointsForPDF(raw, source: source)

        // 2) Filtered: твой “PDF-красивый” пайплайн (для AW = как есть)
        let filteredPrepared: [ECGPoint]
        if source == .appleWatch {
            // для PDF делаем "красивый" filtered из RAW, а не из detection-filtered
            filteredPrepared = preparePaperFilteredFromRawForPDF(raw, source: source)
        } else {
            filteredPrepared = prepareFilteredForPDF(filtered, source: source)
        }        // 3-4) MWI/Detection: только чистим NaN/Inf + decimate (по желанию)
        let mwiPrepared = prepareMWIForPDF(mwi)
        let detPrepared = prepareMWIForPDF(detMWI)

        let bounds = CGRect(origin: .zero, size: pageSize)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)

        let pdf = renderer.pdfData { ctx in
            // Page 1: RAW
            renderECGPage(
                ctx: ctx,
                pageTitle: "1) RAW — \(sourceLabel(source))",
                subtitle: "25 мм/с, 10 мм/мВ",
                points: rawPrepared,
                analytics: analytics,
                source: source,
                isRaw: true
            )

            // Page 2: Filtered
            renderECGPage(
                ctx: ctx,
                pageTitle: "2) Filtered — \(sourceLabel(source))",
                subtitle: "25 мм/с, 10 мм/мВ",
                points: filteredPrepared,
                analytics: analytics,
                source: source,
                isRaw: false
            )

            // Page 3: MWI
            renderMWIPage(
                ctx: ctx,
                pageTitle: "3) Pan–Tompkins (MWI) — \(sourceLabel(source))",
                subtitle: "25 мм/с, a.u. (auto Y)",
                mwi: mwiPrepared
            )
////
            // Page 4: Detection
            renderDetectionPage(
                ctx: ctx,
                pageTitle: "4) Detection — \(sourceLabel(source))",
                subtitle: "MWI + threshold + envelopes, a.u. (auto Y)",
                mwi: mwiPrepared,       // красивая кривая как на 3-й
                thrRef: detPrepared,    // шкала для порога — как раньше
                thr: detThr,            // без пересчёта!
                peakTimes: detPeakTimes
            )
            // Page 5: Signal Detection
            renderECGPage(
                ctx: ctx,
                pageTitle: "5) Детектирование по сигналу — \(sourceLabel(source))",
                subtitle: "25 мм/с, 10 мм/мВ",
                points: filteredPrepared,
                analytics: analytics,
                source: source,
                isRaw: false,
                peakTimes: [],
                markerPoints: signalMarkerPoints
            )
        }

        return pdf.isEmpty ? nil : pdf
    }

    // MARK: - Prepare (RAW)
    private static func prepareRawPointsForPDF(_ points: [ECGPoint], source: ECGPDFSource) -> [ECGPoint] {
        // Apple Watch оставляем как есть
        if source == .appleWatch { return sanitizeMonotonic(points) }

        let pts = sanitizeMonotonic(points)
        guard pts.count > 10 else { return pts }

        // 1) decimate (делаем раньше, чтобы все расчёты были стабильнее)
        let fs0 = estimateFs(from: pts)
        let targetFs = 200.0
        let factor = max(1, Int(round(fs0 / targetFs)))
        var out = decimate(points: pts, factor: factor)

        // 2) очень мягкое удаление baseline/DC (RAW остаётся RAW, но перестаёт "уплывать")
        let fs = estimateFs(from: out)
        var y = out.map { $0.mV }

        // окно ~0.8–1.0 с: убирает медленный дрейф, не "фильтрует" QRS
        let win = max(5, Int(round(0.9 * fs)))
        let base = movingAverageZeroPhase(y, window: win)
        for i in y.indices { y[i] -= base[i] }
        if source == .esp32 {
            y = medianFilter(y, window: 3)
        }
        // 2.5) ROBUST auto-scale для RAW под "медицинский" масштаб PDF
        // Цель: чтобы типичная амплитуда (p99 по центру) была ~1.0 мВ (или меньше),
        // иначе фиксированный 10 мм/мВ превращает шум в «частокол».
        let n0 = y.count
        let cut0 = Int(0.5 * fs)
        let lo0 = min(max(cut0, 0), max(n0 - 1, 0))
        let hi0 = max(min(n0 - cut0, n0), lo0 + 1)
        let mid0 = Array(y[lo0..<hi0]).map { abs($0) }

        let p99raw = quantile(mid0, 0.99)
        if p99raw.isFinite, p99raw > 1e-9 {
            // выбери целевой уровень: 0.8–1.0 "мВ" на p99
            let targetP99 = 1.0
            var k = targetP99 / p99raw
            // safety: не раздувать слишком и не гасить в ноль
            k = min(max(k, 0.05), 20.0)
            for i in y.indices { y[i] *= k }
        }
        
        // 3) clamp по "центру" записи (чтобы начало/конец не диктовали масштаб)
        let n = y.count
        let cut = Int(0.5 * fs)
        let lo = min(max(cut, 0), max(n - 1, 0))
        let hi = max(min(n - cut, n), lo + 1)
        let mid = Array(y[lo..<hi]).map { abs($0) }

        let p99 = quantile(mid, 0.99)
        var clampMV = max(0.8, p99 * 1.6)
                clampMV = min(clampMV, 2.2)
        // 4) мягкая компрессия "игл" (важно именно для RAW)
        let knee = clampMV * 0.55                  // где начинаем компрессию
        let maxMV = clampMV                         // верхняя "полка"

        for i in y.indices {
            let s = y[i]
            let a = abs(s)
            if a <= knee { continue }
            let sign = s >= 0 ? 1.0 : -1.0
            // плавно стремится к maxMV
            let compressed = knee + (maxMV - knee) * (1.0 - exp(-(a - knee) / (0.18 * knee)))
            y[i] = sign * min(compressed, maxMV)
        }

        // 5) финальный hard-clamp (страховка)
        for i in y.indices {
            if y[i] > clampMV { y[i] = clampMV }
            else if y[i] < -clampMV { y[i] = -clampMV }
        }

        out = zip(out, y).map { (p, mv) in ECGPoint(t: p.t, mV: mv) }
        return out
    }

    // sanitize + монотонное время + t начинается с 0
    private static func sanitizeMonotonic(_ pts: [ECGPoint]) -> [ECGPoint] {
        let clean = pts.filter { $0.t.isFinite && $0.mV.isFinite }
        guard clean.count > 1 else { return clean }

        var out: [ECGPoint] = []
        out.reserveCapacity(clean.count)

        var lastT = -Double.greatestFiniteMagnitude
        let t0 = clean.first!.t

        for p in clean {
            let t = p.t - t0
            // отбрасываем нерастущие точки времени (частая причина "столбов")
            if t <= lastT { continue }
            out.append(ECGPoint(t: t, mV: p.mV))
            lastT = t
        }
        return out
    }

    // MARK: - Prepare (Filtered)
    private static func prepareFilteredForPDF(_ points: [ECGPoint], source: ECGPDFSource) -> [ECGPoint] {
        let pts = sanitize(points)
        guard pts.count > 5 else { return pts }
        if source == .appleWatch { return pts }

        var y = pts.map { $0.mV }
        let fs = estimateFs(from: pts)

        // baseline removal (~0.3s)
        let winHP = max(3, Int(round(0.3 * fs)))
        let baseline = movingAverageZeroPhase(y, window: winHP)
        for i in y.indices { y[i] -= baseline[i] }
        if source == .esp32 {
            y = medianFilter(y, window: 3)
        }
        // low-pass for “paper look”
        y = lowpassMovingAverage(y, fs: fs, fc: 40.0)

        // median (despike)
        y = medianFilter(y, window: 5)

        // clamp (по центру записи, чтобы края не портили масштаб)
        let n = y.count
        let cut = Int(0.5 * fs)
        let lo = min(max(cut, 0), max(n - 1, 0))
        let hi = max(min(n - cut, n), lo + 1)
        let mid = Array(y[lo..<hi])
        let absMid = mid.map { abs($0) }

        let p90 = quantile(absMid, 0.90)
        let p99 = quantile(absMid, 0.99)

        // ref — чтобы не раздувало масштаб на почти нулевом сигнале
        let ref = max(p90, min(p99, 1.0))
        let targetMaxAbsMV = 0.55

        var k = targetMaxAbsMV / max(ref, 1e-3)
        k = min(max(k, 0.1), 5.0) // safety
        for i in y.indices { y[i] *= k }

        // soft-clip peaks чуть-чуть
        let clipMV = 2.2
        for i in y.indices {
            if y[i] > clipMV { y[i] = clipMV }
            else if y[i] < -clipMV { y[i] = -clipMV }
        }

        let prepared = zip(pts, y).map { (p, mv) in ECGPoint(t: p.t, mV: mv) }

        // decimate to ~200 Hz
        let targetFs = 200.0
        let factor = max(1, Int(round(fs / targetFs)))
        return decimate(points: prepared, factor: factor)
    }

    // MARK: - Prepare (MWI/Detection)
    private static func prepareMWIForPDF(_ points: [ECGPoint]) -> [ECGPoint] {
        let pts = sanitize(points)
        guard pts.count > 5 else { return pts }
        let fs = estimateFs(from: pts)
        let targetFs = 200.0
        let factor = max(1, Int(round(fs / targetFs)))
        return decimate(points: pts, factor: factor)
    }

    // MARK: - Rendering pages
    private static func renderECGPage(
        ctx: UIGraphicsPDFRendererContext,
        pageTitle: String,
        subtitle: String,
        points: [ECGPoint],
        analytics: ECGAnalytics?,
        source: ECGPDFSource,
        isRaw: Bool,
        peakTimes: [Double] = [],
        markerPoints: [ECGPoint] = []
    ) {
        ctx.beginPage()
        guard let g = UIGraphicsGetCurrentContext() else { return }

        (pageTitle as NSString).draw(
            at: CGPoint(x: pageMargin, y: pageMargin - 8),
            withAttributes: [.font: UIFont.boldSystemFont(ofSize: 16)]
        )
        (subtitle as NSString).draw(
            at: CGPoint(x: pageMargin, y: pageMargin + 12),
            withAttributes: [.font: UIFont.systemFont(ofSize: 12), .foregroundColor: UIColor.darkGray]
        )

        // calibration 1mV (для mV страниц)
        drawCalibration(in: g, at: CGPoint(x: pageMargin, y: pageMargin + 28))

        let rowRects = makeRowRects()
        let secondsPerRow = secondsPerRow(from: rowRects[0])

        for rr in rowRects {
            drawGrid(in: g, rect: rr)
            drawRowBorder(in: g, rect: rr)
        }

        drawECGMultiRowFixedScale(
            in: g,
            rowRects: rowRects,
            points: points,
            secondsPerRow: secondsPerRow,
            source: source,
            isRaw: isRaw,
            peakTimes: peakTimes,
            markerPoints: markerPoints
        )
        let analyticsTop = rowRects.last!.maxY + 24
        let textRect = CGRect(x: pageMargin, y: analyticsTop,
                              width: pageSize.width - pageMargin * 2, height: 260)
        drawAnalytics(in: textRect, analytics: analytics)
    }

    private static func renderMWIPage(
        ctx: UIGraphicsPDFRendererContext,
        pageTitle: String,
        subtitle: String,
        mwi: [ECGPoint]
    ) {
        ctx.beginPage()
        guard let g = UIGraphicsGetCurrentContext() else { return }

        (pageTitle as NSString).draw(
            at: CGPoint(x: pageMargin, y: pageMargin - 8),
            withAttributes: [.font: UIFont.boldSystemFont(ofSize: 16)]
        )
        (subtitle as NSString).draw(
            at: CGPoint(x: pageMargin, y: pageMargin + 12),
            withAttributes: [.font: UIFont.systemFont(ofSize: 12), .foregroundColor: UIColor.darkGray]
        )

        let rowRects = makeRowRects()
        let secondsPerRow = secondsPerRow(from: rowRects[0])

        for rr in rowRects {
            drawGrid(in: g, rect: rr)
            drawRowBorder(in: g, rect: rr)
        }

        let yScale = autoYScalePtPerUnit(points: mwi, rowRect: rowRects[0])
        drawSignalMultiRow(in: g, rowRects: rowRects, points: mwi, secondsPerRow: secondsPerRow, yScalePtPerUnit: yScale)
    }
    private static func renderDetectionPage(
        ctx: UIGraphicsPDFRendererContext,
        pageTitle: String,
        subtitle: String,
        mwi: [ECGPoint],          // что рисуем (красивая парабола)
        thrRef: [ECGPoint],       // по чему считаем Y-шкалу для порога
        thr: Double,
        peakTimes: [Double]
    ) {
        ctx.beginPage()
        guard let g = UIGraphicsGetCurrentContext() else { return }

        (pageTitle as NSString).draw(
            at: CGPoint(x: pageMargin, y: pageMargin - 8),
            withAttributes: [.font: UIFont.boldSystemFont(ofSize: 16)]
        )
        (subtitle as NSString).draw(
            at: CGPoint(x: pageMargin, y: pageMargin + 12),
            withAttributes: [.font: UIFont.systemFont(ofSize: 12), .foregroundColor: UIColor.darkGray]
        )

        let rowRects = makeRowRects()
        let secondsPerRow = secondsPerRow(from: rowRects[0])

        for rr in rowRects {
            drawGrid(in: g, rect: rr)
            drawRowBorder(in: g, rect: rr)
        }

        // шкала для сигнала (по mwiPrepared) — чтобы 4-я выглядела как 3-я
        let yScaleSignal = autoYScalePtPerUnit(points: mwi, rowRect: rowRects[0])

        // шкала для порога (по detPrepared) — чтобы пунктир был "как раньше"
        let yScaleThr = autoYScalePtPerUnit(points: thrRef, rowRect: rowRects[0])

        drawSignalMultiRow(in: g,
                           rowRects: rowRects,
                           points: mwi,
                           secondsPerRow: secondsPerRow,
                           yScalePtPerUnit: yScaleSignal)

        // ВАЖНО: рисуем порог с yScaleThr, а не yScaleSignal
        drawThresholdMultiRow(in: g,
                              rowRects: rowRects,
                              thr: thr,
                              yScalePtPerUnit: yScaleThr)

        drawPeaksMultiRow(in: g,
                          rowRects: rowRects,
                          peakTimes: peakTimes,
                          secondsPerRow: secondsPerRow,
                          mwi: mwi,
                          yScalePtPerUnit: yScaleSignal)
    }

    // MARK: - Row layout helpers
    private static func makeRowRects() -> [CGRect] {
        let plotArea = CGRect(
            x: pageMargin,
            y: plotOuterTop + pageMargin,
            width: pageSize.width - pageMargin * 2,
            height: 3 * 80 + 2 * rowSpacing
        )
        let rows = 3
        let totalSpacing = rowSpacing * CGFloat(rows - 1)
        let rowHeight = (plotArea.height - totalSpacing) / CGFloat(rows)

        return (0..<rows).map { r in
            let y = plotArea.minY + CGFloat(r) * (rowHeight + rowSpacing)
            return CGRect(x: plotArea.minX, y: y, width: plotArea.width, height: rowHeight)
        }
    }

    private static func secondsPerRow(from rowRect: CGRect) -> Double {
        Double(rowRect.width / (mmPerSecond * mm1))
    }

    // MARK: - Drawing (fixed ECG scale 10mm/mV)
    private static func drawECGMultiRowFixedScale(
        in ctx: CGContext,
        rowRects: [CGRect],
        points: [ECGPoint],
        secondsPerRow: Double,
        source: ECGPDFSource,
        isRaw: Bool,
        peakTimes: [Double] = [],
        markerPoints: [ECGPoint] = []
    )
    {
        let xScalePtPerSec = mmPerSecond * mm1
        let yScalePtPerMV  = mmPerMilliVolt * mm1

        // сгруппируем точки по строкам, чтобы удобно клипать
        var buckets = Array(repeating: [ECGPoint](), count: rowRects.count)
        buckets = buckets.map { _ in [] }
        for p in points {
            let rowIndex = Int(floor(p.t / secondsPerRow))
            if rowIndex >= 0, rowIndex < rowRects.count {
                buckets[rowIndex].append(p)
            }
        }

        ctx.saveGState()
        ctx.setStrokeColor(UIColor.black.cgColor)
        ctx.setLineWidth(1.0)

        for rowIndex in 0..<rowRects.count {
            let rr = rowRects[rowIndex]
            let rowPts = buckets[rowIndex]
            guard rowPts.count > 1 else { continue }

            ctx.saveGState()
            ctx.clip(to: rr)

            // сколько мВ помещается в полувысоту строки (оставляем запас, чтобы не упиралось в край)
            let maxMVFit = Double((rr.height * 0.46) / yScalePtPerMV)  // 0.46 можно 0.42–0.48

            // где начинаем мягкое сжатие
            let knee = maxMVFit * 0.65

            func softClip(_ v: Double) -> Double {
                let a = abs(v)
                if a <= knee { return v }
                let sign = v >= 0 ? 1.0 : -1.0
                // плавно стремится к maxMVFit
                let t = (a - knee) / max(1e-9, (maxMVFit - knee))
                let y = knee + (maxMVFit - knee) * (1.0 - exp(-2.2 * t))
                return sign * min(y, maxMVFit)
            }

            ctx.beginPath()
            var first = true

            for p in rowPts {
                let xWithin = p.t - Double(rowIndex) * secondsPerRow
                let x = rr.minX + CGFloat(xWithin) * xScalePtPerSec

                // ключ: "влезаем" в высоту строки
                let mv = softClip(p.mV)
                let y = rr.midY - CGFloat(mv) * yScalePtPerMV

                if first {
                    ctx.move(to: CGPoint(x: x, y: y))
                    first = false
                } else {
                    ctx.addLine(to: CGPoint(x: x, y: y))
                }
            }
            ctx.strokePath()

            let rowT0 = Double(rowIndex) * secondsPerRow
            let rowT1 = rowT0 + secondsPerRow

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

            // Новый путь: если переданы готовые markerPoints — рисуем по ним
            if !markerPoints.isEmpty {
                let rowMarkers = markerPoints.filter { $0.t >= rowT0 && $0.t <= rowT1 }

                if !rowMarkers.isEmpty {
                    ctx.saveGState()
                    ctx.setFillColor(UIColor.systemRed.withAlphaComponent(0.9).cgColor)

                    for marker in rowMarkers {
                        // ВАЖНО: ищем ближайшую точку именно в rowPts,
                        // то есть в уже подготовленном для PDF сигнале
                        guard let idx = nearestIndexByTime(rowPts, marker.t) else { continue }
                        let peak = rowPts[idx]

                        let xWithin = peak.t - rowT0
                        let x = rr.minX + CGFloat(xWithin) * xScalePtPerSec

                        let mv = softClip(peak.mV)
                        let y = rr.midY - CGFloat(mv) * yScalePtPerMV

                        let r: CGFloat = 4.0
                        ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
                    }

                    ctx.restoreGState()
                }
            }
            // Старый путь: если markerPoints не передали, но есть peakTimes
            else if !isRaw && !peakTimes.isEmpty {
                let rowPeakTimes = peakTimes.filter { $0 >= rowT0 && $0 <= rowT1 }

                if !rowPeakTimes.isEmpty {
                    let fs = estimateFs(from: rowPts)
                    let halfWindowSec = 0.05
                    let halfN = max(1, Int(round(halfWindowSec * fs)))

                    func localSignalPeak(near t: Double) -> ECGPoint? {
                        guard let idx0 = nearestIndexByTime(rowPts, t) else { return nil }

                        let i1 = max(0, idx0 - halfN)
                        let i2 = min(rowPts.count - 1, idx0 + halfN)

                        var bestI = idx0
                        var bestV = rowPts[idx0].mV

                        for i in i1...i2 {
                            let v = rowPts[i].mV
                            if v > bestV {
                                bestV = v
                                bestI = i
                            }
                        }

                        return rowPts[bestI]
                    }

                    ctx.saveGState()
                    ctx.setFillColor(UIColor.systemRed.withAlphaComponent(0.9).cgColor)

                    for tPeak in rowPeakTimes {
                        guard let peak = localSignalPeak(near: tPeak) else { continue }

                        let xWithin = peak.t - rowT0
                        let x = rr.minX + CGFloat(xWithin) * xScalePtPerSec

                        let mv = softClip(peak.mV)
                        let y = rr.midY - CGFloat(mv) * yScalePtPerMV

                        let r: CGFloat = 4.0
                        ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
                    }

                    ctx.restoreGState()
                }
            }

            ctx.restoreGState()
        }
        ctx.restoreGState()
    }
    

    // MARK: - Drawing (auto Y for MWI)
    private static func autoYScalePtPerUnit(points: [ECGPoint], rowRect: CGRect) -> CGFloat {
        let vals = points.map { abs($0.mV) }.filter { $0.isFinite }
        guard !vals.isEmpty else { return 1.0 }
        let p95 = quantile(vals, 0.95)
        let targetHalfHeight = rowRect.height * 0.35
        return p95 > 1e-9 ? (targetHalfHeight / CGFloat(p95)) : 1.0
    }

    private static func drawSignalMultiRow(
        in ctx: CGContext,
        rowRects: [CGRect],
        points: [ECGPoint],
        secondsPerRow: Double,
        yScalePtPerUnit: CGFloat
    ) {
        let xScalePtPerSec = mmPerSecond * mm1

        ctx.saveGState()
        ctx.setStrokeColor(UIColor.black.cgColor)
        ctx.setLineWidth(1.0)

        var currentRow = -1

        for p in points {
            let rowIndex = Int(floor(p.t / secondsPerRow))
            guard rowIndex >= 0, rowIndex < rowRects.count else { continue }

            let rr = rowRects[rowIndex]
            let xWithin = p.t - Double(rowIndex) * secondsPerRow
            let x = rr.minX + CGFloat(xWithin) * xScalePtPerSec
            let y = rr.midY - CGFloat(p.mV) * yScalePtPerUnit

            if rowIndex != currentRow {
                if currentRow != -1 { ctx.strokePath() }
                ctx.beginPath()
                ctx.move(to: CGPoint(x: x, y: y))
                currentRow = rowIndex
            } else {
                ctx.addLine(to: CGPoint(x: x, y: y))
            }
        }

        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func drawThresholdMultiRow(
        in ctx: CGContext,
        rowRects: [CGRect],
        thr: Double,
        yScalePtPerUnit: CGFloat
    ) {
        ctx.saveGState()
        ctx.setStrokeColor(UIColor.red.withAlphaComponent(0.6).cgColor)
        ctx.setLineWidth(1.0)
        ctx.setLineDash(phase: 0, lengths: [6, 4])

        for rr in rowRects {
            let y = rr.midY - CGFloat(thr) * yScalePtPerUnit
            ctx.beginPath()
            ctx.move(to: CGPoint(x: rr.minX, y: y))
            ctx.addLine(to: CGPoint(x: rr.maxX, y: y))
            ctx.strokePath()
        }

        ctx.restoreGState()
    }
    private static func drawPeakParabolasMultiRow(
        in ctx: CGContext,
        rowRects: [CGRect],
        peakTimes: [Double],
        secondsPerRow: Double,
        mwi: [ECGPoint],
        yScalePtPerUnit: CGFloat
    ) {
        guard mwi.count > 2, let lastT = mwi.last?.t, lastT > 0 else { return }

        let xScalePtPerSec = mmPerSecond * mm1
        let fs = estimateFs(from: mwi)

        // Ширина "параболы" вокруг пика (подбери по вкусу)
        // 140–200 мс обычно выглядит хорошо
        let halfWindowSec = 0.09   // 90 мс влево и 90 мс вправо => ~180 мс "шапка"
        let halfN = max(2, Int(round(halfWindowSec * fs)))

        // Быстрый nearest index по времени (binary search)
        func nearestIndex(for time: Double) -> Int {
            var lo = 0
            var hi = mwi.count - 1
            while lo < hi {
                let mid = (lo + hi) / 2
                if mwi[mid].t < time { lo = mid + 1 } else { hi = mid }
            }
            if lo > 0 {
                let a = abs(mwi[lo].t - time)
                let b = abs(mwi[lo - 1].t - time)
                return (b < a) ? (lo - 1) : lo
            }
            return lo
        }

        ctx.saveGState()
        ctx.setStrokeColor(UIColor.systemGreen.cgColor)
        ctx.setLineWidth(1.6) // "парабола" будет заметнее
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)

        for t0 in peakTimes {
            if t0 < 0 || t0 > lastT { continue }

            let i0 = nearestIndex(for: t0)
            let i1 = max(0, i0 - halfN)
            let i2 = min(mwi.count - 1, i0 + halfN)
            if i2 - i1 < 2 { continue }

            // рисуем сегмент, но аккуратно по строкам (чтобы не "перепрыгивало" через разрыв)
            for rowIndex in 0..<rowRects.count {
                let rr = rowRects[rowIndex]
                let rowT0 = Double(rowIndex) * secondsPerRow
                let rowT1 = rowT0 + secondsPerRow

                // быстро проверим, пересекается ли окно с этой строкой
                if mwi[i2].t < rowT0 || mwi[i1].t > rowT1 { continue }

                ctx.saveGState()
                ctx.clip(to: rr)

                ctx.beginPath()
                var started = false

                for i in i1...i2 {
                    let p = mwi[i]
                    if p.t < rowT0 || p.t > rowT1 { continue }

                    let xWithin = p.t - rowT0
                    let x = rr.minX + CGFloat(xWithin) * xScalePtPerSec
                    let y = rr.midY - CGFloat(p.mV) * yScalePtPerUnit

                    if !started {
                        ctx.move(to: CGPoint(x: x, y: y))
                        started = true
                    } else {
                        ctx.addLine(to: CGPoint(x: x, y: y))
                    }
                }

                if started { ctx.strokePath() }
                ctx.restoreGState()
            }
        }

        ctx.restoreGState()
    }
    private static func drawPeaksMultiRow(
        in ctx: CGContext,
        rowRects: [CGRect],
        peakTimes: [Double],
        secondsPerRow: Double,
        mwi: [ECGPoint],
        yScalePtPerUnit: CGFloat
    ) {
        guard let lastT = mwi.last?.t, lastT > 0, mwi.count > 2 else { return }

        let fs = estimateFs(from: mwi)
        // минимум 200 мс между R-пиками (убирает двойные точки)
        let minPeakDistSec = max(0.20, 2.0 / max(1.0, fs))

        let xScalePtPerSec = mmPerSecond * mm1
        let n = mwi.count

        // окно поиска локального максимума вокруг peakTime
        let halfWindowSec = 0.06
        let halfN = max(1, Int(round(halfWindowSec * fs)))

        // бинарный поиск ближайшего индекса по времени
        func nearestIndex(for time: Double) -> Int {
            var lo = 0
            var hi = n - 1
            while lo < hi {
                let mid = (lo + hi) / 2
                if mwi[mid].t < time { lo = mid + 1 } else { hi = mid }
            }
            if lo > 0 {
                let a = abs(mwi[lo].t - time)
                let b = abs(mwi[lo - 1].t - time)
                return (b < a) ? (lo - 1) : lo
            }
            return lo
        }

        // амплитуда "вершины" около времени (для выбора лучшего при дублях)
        func peakValue(near time: Double) -> Double {
            let idx0 = nearestIndex(for: time)
            let i1 = max(0, idx0 - halfN)
            let i2 = min(n - 1, idx0 + halfN)

            var bestV = mwi[idx0].mV
            for i in i1...i2 {
                let v = mwi[i].mV
                if v > bestV { bestV = v }   // максимум вверх
                // если хочешь по модулю: if abs(v) > abs(bestV) { bestV = v }
            }
            return bestV
        }

        // 1) чистим peakTimes, сортируем
        let cleaned = peakTimes
            .filter { $0.isFinite && $0 >= 0 && $0 <= lastT }
            .sorted()

        // 2) дедуп: если пики ближе minPeakDistSec — оставляем тот, у которого выше "вершина"
        var dedup: [Double] = []
        dedup.reserveCapacity(cleaned.count)

        for t in cleaned {
            guard let last = dedup.last else {
                dedup.append(t)
                continue
            }

            if t - last >= minPeakDistSec {
                dedup.append(t)
            } else {
                // слишком близко: сравним высоту и заменим, если новый "сильнее"
                let vLast = peakValue(near: last)
                let vNew  = peakValue(near: t)
                if vNew > vLast {
                    dedup[dedup.count - 1] = t
                }
            }
        }

        ctx.saveGState()
        ctx.setFillColor(UIColor.systemGreen.cgColor)

        // 3) рисуем точки
        for t in dedup {
            let idx0 = nearestIndex(for: t)
            let i1 = max(0, idx0 - halfN)
            let i2 = min(n - 1, idx0 + halfN)

            var bestI = idx0
            var bestV = mwi[idx0].mV
            for i in i1...i2 {
                let v = mwi[i].mV
                if v > bestV {
                    bestV = v
                    bestI = i
                }
            }

            let peakT = mwi[bestI].t
            let rowIndex = Int(floor(peakT / secondsPerRow))
            guard rowIndex >= 0, rowIndex < rowRects.count else { continue }

            let rr = rowRects[rowIndex]
            let xWithin = peakT - Double(rowIndex) * secondsPerRow
            let x = rr.minX + CGFloat(xWithin) * xScalePtPerSec

            let yVal = mwi[bestI].mV
            let y = rr.midY - CGFloat(yVal) * yScalePtPerUnit

            let r: CGFloat = 3.2
            ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2*r, height: 2*r))
        }

        ctx.restoreGState()
    }

    // MARK: - Grid / Border / Calibration / Analytics
    private static func drawGrid(in ctx: CGContext, rect: CGRect) {
        ctx.saveGState()
        ctx.setLineWidth(0.5)

        // Vertical
        var x = rect.minX
        var col = 0
        while x <= rect.maxX + 0.1 {
            let big = (col % 5 == 0)
            let color = big ? UIColor(red: 1, green: 0.3, blue: 0.3, alpha: 1).cgColor
                            : UIColor(white: 0.85, alpha: 1).cgColor
            ctx.setStrokeColor(color)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: x, y: rect.minY))
            ctx.addLine(to: CGPoint(x: x, y: rect.maxY))
            ctx.strokePath()
            x += mm1; col += 1
        }

        // Horizontal
        var y = rect.minY
        var row = 0
        while y <= rect.maxY + 0.1 {
            let big = (row % 5 == 0)
            let color = big ? UIColor(red: 1, green: 0.3, blue: 0.3, alpha: 1).cgColor
                            : UIColor(white: 0.85, alpha: 1).cgColor
            ctx.setStrokeColor(color)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: rect.minX, y: y))
            ctx.addLine(to: CGPoint(x: rect.maxX, y: y))
            ctx.strokePath()
            y += mm1; row += 1
        }

        ctx.restoreGState()
    }

    private static func drawRowBorder(in ctx: CGContext, rect: CGRect) {
        ctx.saveGState()
        ctx.setStrokeColor(UIColor(white: 0.0, alpha: 0.15).cgColor)
        ctx.setLineWidth(0.8)
        ctx.addRect(rect)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func drawCalibration(in ctx: CGContext, at origin: CGPoint) {
        ctx.saveGState()
        ctx.setStrokeColor(UIColor.red.cgColor)
        ctx.setLineWidth(1.0)

        let w = 10.0 * mm1
        let h = 10.0 * mm1
        let r = CGRect(x: origin.x, y: origin.y + 2, width: w, height: h)

        ctx.stroke(r)
        ("1 mV" as NSString).draw(at: CGPoint(x: r.maxX + 6, y: r.minY - 2),
                                  withAttributes: [.font: UIFont.systemFont(ofSize: 10),
                                                   .foregroundColor: UIColor.red])
        ctx.restoreGState()
    }

    private static func drawAnalytics(in rect: CGRect, analytics: ECGAnalytics?) {
        guard let a = analytics else { return }
        var t = ""
        if let cls = a.classification { t += "Классификация: \(cls)\n" }
        if let bpm = a.appleAvgHR { t += "Средний ЧСС: \(Int(bpm)) bpm\n" }
        t += "Частота дискретизации: \(Int(a.sampleRate)) Гц\n"
        if let s = a.symptoms { t += "Симптомы: \(s)\n" }
        t += "R-пиков: \(a.rPeaksSec.count)\n"
        if let sdnn = a.sdnn { t += "SDNN: \(Int(sdnn)) мс\n" }
        if let rmssd = a.rmssd { t += "RMSSD: \(Int(rmssd)) мс\n" }

        if let hrv = ECGAnalysis.computeHRVMetrics(rr: zip(a.rPeaksSec.dropFirst(), a.rPeaksSec).map { $0 - $1 }) {
            t += "HRmin: \(Int(hrv.hrMin)) bpm\n"
            t += "HRmax: \(Int(hrv.hrMax)) bpm\n"
            t += "ΔRR: \(Int(hrv.deltaRR * 1000.0)) мс\n"
            t += "NN50: \(hrv.nn50)\n"
            t += String(format: "pNN50: %.1f %%\n", hrv.pnn50)
            t += String(format: "CV: %.1f %%\n", hrv.cv)
            t += String(format: "NArr: %.1f %%\n", hrv.narr)
        }

        if let it = a.interpretation {
            t += "\n"
            t += "\(it.hrMinStatus)\n"
            t += "\(it.hrMaxStatus)\n"
            t += "\(it.deltaRRStatus)\n"
            t += "\(it.sdnnStatus)\n"
            t += "\(it.rmssdStatus)\n"
            t += "\(it.pnn50Status)\n"
            t += "\(it.cvStatus)\n"
            t += "\(it.narrStatus)\n"
            t += "\(it.stress)\n"
        }
        (t as NSString).draw(in: rect, withAttributes: [
            .font: UIFont.systemFont(ofSize: 12),
            .foregroundColor: UIColor.black
        ])
    }

    // MARK: - Utils
    private static func sourceLabel(_ s: ECGPDFSource) -> String {
        switch s {
        case .appleWatch: return "Apple Watch"
        case .esp32: return "ESP32"
        case .xiao: return "XIAO"
        }
    }

    private static func sanitize(_ pts: [ECGPoint]) -> [ECGPoint] {
        pts.filter { $0.t.isFinite && $0.mV.isFinite }
    }

    private static func decimate(points: [ECGPoint], factor: Int) -> [ECGPoint] {
        guard factor > 1, points.count > factor else { return points }
        var out: [ECGPoint] = []
        out.reserveCapacity(points.count / factor + 1)
        var i = 0
        while i < points.count {
            out.append(points[i])
            i += factor
        }
        return out
    }

    private static func estimateFs(from points: [ECGPoint]) -> Double {
        let n = min(points.count - 1, 200)
        if n <= 5 { return 500.0 }
        var dts: [Double] = []
        dts.reserveCapacity(n)
        for i in 1...n {
            let dt = points[i].t - points[i-1].t
            if dt.isFinite, dt > 0 { dts.append(dt) }
        }
        guard !dts.isEmpty else { return 500.0 }
        dts.sort()
        let med = dts[dts.count / 2]
        return med > 0 ? (1.0 / med) : 500.0
    }

    private static func quantile(_ x: [Double], _ q: Double) -> Double {
        let s = x.sorted()
        guard !s.isEmpty else { return 0 }
        let idx = max(0, min(s.count - 1, Int(Double(s.count - 1) * q)))
        return s[idx]
    }

    private static func medianFilter(_ x: [Double], window w: Int = 5) -> [Double] {
        guard w >= 3, w % 2 == 1, x.count > w else { return x }
        let r = w / 2
        var out = x
        for i in r..<(x.count - r) {
            var buf: [Double] = []
            buf.reserveCapacity(w)
            for k in (i - r)...(i + r) { buf.append(x[k]) }
            buf.sort()
            out[i] = buf[r]
        }
        return out
    }

    private static func movingAverageZeroPhase(_ x: [Double], window w: Int) -> [Double] {
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
        let rev = ma(fwd.reversed()).reversed()
        return Array(rev)
    }

    private static func lowpassMovingAverage(_ x: [Double], fs: Double, fc: Double) -> [Double] {
        let w = max(3, Int(round(fs / max(1.0, fc))))
        return movingAverageZeroPhase(x, window: w)
    }
}
