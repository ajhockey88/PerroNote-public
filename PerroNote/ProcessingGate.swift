import Foundation

/// Lets one meeting be processed at a time. Others wait their turn in the order they were started.
actor ProcessingGate {
    static let shared = ProcessingGate()

    private var running = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        if !running { running = true; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func leave() {
        if waiting.isEmpty { running = false } else { waiting.removeFirst().resume() }
    }
}
