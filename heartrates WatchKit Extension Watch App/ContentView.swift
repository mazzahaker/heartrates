//
//  ContentView.swift
//  heartrates WatchKit Extension Watch App
//
//  Created by mazzahaker on 17/8/25.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var mgr = LiveHRManager()

    var body: some View {
        VStack(spacing: 8) {
            Text("Пульс → iPhone\n10 секунд").multilineTextAlignment(.center)
            Button("Старт 10 с") {
                Task { await mgr.requestAuth(); mgr.start10s() }
            }
            .buttonStyle(.borderedProminent)
            Text(mgr.status).font(.footnote).foregroundStyle(.secondary)
        }.padding()
    }
}
