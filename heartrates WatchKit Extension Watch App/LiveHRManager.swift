//
//  LiveHRManager.swift
//  heartrates
//
//  Created by mazzahaker on 17/8/25.
//

import Foundation
import HealthKit
import WatchConnectivity

final class LiveHRManager: NSObject, ObservableObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate, WCSessionDelegate {
    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    @Published var status = "Готово"

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    // Разрешения: читаем пульс, пишем тренировку
    func requestAuth() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            await MainActor.run { self.status = "HealthKit недоступен" }
            return
        }
        do {
            let read: Set = [HKObjectType.quantityType(forIdentifier: .heartRate)!]
            let share: Set = [HKObjectType.workoutType()]
            try await store.requestAuthorization(toShare: share, read: read)
            await MainActor.run { self.status = "Разрешения выданы" }
        } catch {
            await MainActor.run { self.status = "Нет разрешений: \(error.localizedDescription)" }
        }
    }

    // Стартуем тренировку и собираем HR 10 секунд, потом останавливаемся
    func start10s() {
        do {
            let cfg = HKWorkoutConfiguration()
            cfg.activityType = .other
            cfg.locationType = .indoor

            let session = try HKWorkoutSession(healthStore: store, configuration: cfg)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: cfg)

            self.session = session
            self.builder = builder
            session.delegate = self
            builder.delegate = self

            let now = Date()
            session.startActivity(with: now)
            builder.beginCollection(withStart: now) { [weak self] _, _ in
                Task { @MainActor in self?.status = "Сбор пульса…" }
            }

            // Авто-стоп через 10 секунд
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
                await self?.stop()
            }
        } catch {
            Task { @MainActor in self.status = "Ошибка старта: \(error.localizedDescription)" }
        }
    }

    @MainActor
    func stop() {
        guard let session, let builder else { return }
        status = "Завершаем…"
        session.stopActivity(with: Date())
        builder.endCollection(withEnd: Date()) { [weak self] _, _ in
            session.end()
            builder.finishWorkout { _, _ in
                Task { @MainActor in
                    self?.status = "Готово"
                    self?.session = nil
                    self?.builder = nil
                }
            }
        }
    }

    // MARK: - Delegates
    func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from: HKWorkoutSessionState, date: Date) {}
    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in self.status = "Ошибка сессии: \(error.localizedDescription)" }
    }
    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf types: Set<HKSampleType>) {
        guard let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate),
              types.contains(hrType),
              let stats = workoutBuilder.statistics(for: hrType),
              let q = stats.mostRecentQuantity()
        else { return }

        let bpm = q.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        if WCSession.isSupported(), WCSession.default.isReachable {
            WCSession.default.sendMessage(["bpm": bpm, "ts": Date().timeIntervalSince1970], replyHandler: nil, errorHandler: nil)
        }
    }

    // WCSession — минимальные требования
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
}
