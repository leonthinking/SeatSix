import Foundation

struct PlaybackEvent: Sendable {
    enum Kind: Sendable { case started, progress, stopped }
    var kind: Kind
    var positionTicks: Int64
    var isPaused: Bool
}

public enum PlaybackReportingStatus: String, Sendable { case idle, reporting, uncertain, ended }

/// Own one reporter per playback. A single drain task prevents actor reentrancy from reordering writes.
public actor PlaybackReporter {
    private struct Pending {
        var event: PlaybackEvent
        var waiters: [CheckedContinuation<Void, Error>]
    }
    private let client: MediaServerClient
    private let plan: PlaybackPlan
    private var state: PlaybackReportingStatus = .idle
    private var queue: [Pending] = []
    private var draining = false
    private var stopQueued = false

    public init(client: MediaServerClient, plan: PlaybackPlan) { self.client = client; self.plan = plan }
    public func status() -> PlaybackReportingStatus { state }

    public func start(positionTicks: Int64 = 0) async throws {
        guard state == .idle else { throw state == .uncertain ? MediaServerError.reportingUncertain : MediaServerError.invalidReportingState }
        state = .reporting
        try await enqueue(PlaybackEvent(kind: .started, positionTicks: positionTicks, isPaused: false))
    }

    public func progress(positionTicks: Int64, isPaused: Bool) async throws {
        try validateActive()
        try await enqueue(PlaybackEvent(kind: .progress, positionTicks: positionTicks, isPaused: isPaused))
    }

    public func stop(positionTicks: Int64) async throws {
        try validateActive()
        stopQueued = true
        try await enqueue(PlaybackEvent(kind: .stopped, positionTicks: positionTicks, isPaused: true))
    }

    private func validateActive() throws {
        if state == .uncertain { throw MediaServerError.reportingUncertain }
        guard state == .reporting, !stopQueued else { throw MediaServerError.invalidReportingState }
    }

    private func enqueue(_ event: PlaybackEvent) async throws {
        try await withCheckedThrowingContinuation { continuation in
            if event.kind == .progress, let last = queue.indices.last, queue[last].event.kind == .progress {
                queue[last].event = event
                queue[last].waiters.append(continuation)
            } else { queue.append(Pending(event: event, waiters: [continuation])) }
            guard !draining else { return }
            draining = true
            Task { await drain() }
        }
    }

    private func drain() async {
        while !queue.isEmpty {
            let next = queue.removeFirst()
            do {
                try await client.report(next.event, plan: plan)
                if next.event.kind == .stopped { state = .ended }
                next.waiters.forEach { $0.resume() }
            } catch {
                // A timeout can mean the server applied the write. Never blindly replay it or later writes.
                state = .uncertain
                next.waiters.forEach { $0.resume(throwing: error) }
                let abandoned = queue
                queue.removeAll()
                abandoned.flatMap(\.waiters).forEach { $0.resume(throwing: MediaServerError.reportingUncertain) }
                break
            }
        }
        draining = false
    }
}
