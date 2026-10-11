//
//  PhotoClusterer.swift
//  Camera Roll Cleaner
//
//  Thin @MainActor wrapper so the debug screen can show progress and
//  results. All the real work happens in PhotoClusterEngine, off the
//  main actor, so the UI (spinner, button) stays responsive while it runs.
//

import Combine
import Foundation

@MainActor
final class PhotoClusterer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var result: ClusteringResult?

    func run(in interval: DateInterval) async {
        isRunning = true
        result = await PhotoClusterEngine.run(in: interval)
        isRunning = false
    }
}
