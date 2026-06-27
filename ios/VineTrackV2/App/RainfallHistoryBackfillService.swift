import Foundation

/// Aggregated outcome of a chunked Davis or Weather Underground rainfall
/// backfill loop. Surfaces enough detail for the UI to show progress,
/// rate-limit resume hints and final counts.
nonisolated struct ChunkedRainfallBackfillResult: Sendable, Equatable {
    public let daysRequested: Int
    public let daysProcessed: Int
    public let rowsUpserted: Int
    public let errorsCount: Int
    public let chunksCompleted: Int
    /// True when the proxy reported `rate_limited = true` on any chunk
    /// and the loop stopped early.
    public let rateLimited: Bool
    /// True when the full requested range was covered.
    public let completed: Bool
    /// Offset to pass on a future retry to resume where this run stopped.
    /// Nil when the range was fully completed.
    public let resumeOffset: Int?
    public let proxyVersion: String?
    /// Optional station label (WU only).
    public let stationLabel: String?
}

/// Snapshot delivered to the per-chunk progress callback. Allows the UI
/// to render a smooth progress bar while the loop runs.
nonisolated struct ChunkedRainfallProgress: Sendable {
    public let daysProcessed: Int
    public let daysRequested: Int
    public let rowsUpsertedTotal: Int
    public let chunksCompleted: Int
    public let lastChunkRows: Int
    public let lastChunkSlice: Int
    public let nextOffset: Int?
    public let rateLimited: Bool
}

/// Drives long-range chunked rainfall backfills for Davis WeatherLink and
/// Weather Underground using the existing edge-function clients. Stops on
/// rate-limit and persists a resume offset so the user can pick up later.
nonisolated enum RainfallHistoryBackfillService {

    // MARK: - Davis

    /// Loops `davis-proxy backfill_rainfall` until the requested range is
    /// covered or WeatherLink rate-limits us. Davis chunk size defaults
    /// to 60 days (the proxy maximum).
    static func backfillDavisChunked(
        vineyardId: UUID,
        stationId: String,
        totalDays: Int = 365,
        chunkDays: Int = 60,
        startOffset: Int = 0,
        progress: (@Sendable (ChunkedRainfallProgress) -> Void)? = nil
    ) async throws -> ChunkedRainfallBackfillResult {
        let total = max(1, min(365, totalDays))
        let chunk = max(1, min(60, chunkDays))
        var offset = max(0, min(total, startOffset))

        var processedTotal = 0
        var rowsTotal = 0
        var errorsTotal = 0
        var chunks = 0
        var lastVersion: String?
        var rateLimited = false

        while offset < total {
            let r = try await VineyardDavisProxyService.backfillRainfall(
                vineyardId: vineyardId,
                stationId: stationId,
                days: total,
                offsetDays: offset,
                chunkDays: chunk
            )
            processedTotal += r.daysProcessed
            rowsTotal += r.rowsUpserted
            errorsTotal += r.errorsCount
            chunks += 1
            lastVersion = r.proxyVersion ?? lastVersion

            progress?(ChunkedRainfallProgress(
                daysProcessed: processedTotal,
                daysRequested: total,
                rowsUpsertedTotal: rowsTotal,
                chunksCompleted: chunks,
                lastChunkRows: r.rowsUpserted,
                lastChunkSlice: r.sliceLength,
                nextOffset: r.nextOffsetDays,
                rateLimited: r.rateLimited
            ))

            if r.rateLimited {
                rateLimited = true
                offset = r.nextOffsetDays ?? (offset + max(1, r.sliceLength))
                break
            }
            guard let next = r.nextOffsetDays, r.more else {
                offset = total
                break
            }
            // Defensive: if the proxy ever returns the same offset, bail to
            // avoid an infinite loop.
            if next <= offset { break }
            offset = next
            // Tiny pause between chunks to be polite to WeatherLink.
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        let completed = !rateLimited && offset >= total
        return ChunkedRainfallBackfillResult(
            daysRequested: total,
            daysProcessed: processedTotal,
            rowsUpserted: rowsTotal,
            errorsCount: errorsTotal,
            chunksCompleted: chunks,
            rateLimited: rateLimited,
            completed: completed,
            resumeOffset: completed ? nil : offset,
            proxyVersion: lastVersion,
            stationLabel: nil
        )
    }

    // MARK: - Weather Underground

    /// Loops `wunderground-proxy backfill_rainfall` until the requested
    /// range is covered or WU rate-limits us. WU chunk size defaults to
    /// 30 days (the proxy maximum).
    static func backfillWundergroundChunked(
        vineyardId: UUID,
        stationId: String? = nil,
        totalDays: Int = 365,
        chunkDays: Int = 30,
        startOffset: Int = 0,
        progress: (@Sendable (ChunkedRainfallProgress) -> Void)? = nil
    ) async throws -> ChunkedRainfallBackfillResult {
        let total = max(1, min(365, totalDays))
        let chunk = max(1, min(30, chunkDays))
        var offset = max(0, min(total, startOffset))

        var processedTotal = 0
        var rowsTotal = 0
        var errorsTotal = 0
        var chunks = 0
        var lastVersion: String?
        var lastStationLabel: String?
        var rateLimited = false

        while offset < total {
            let r = try await VineyardWundergroundProxyService.backfillRainfall(
                vineyardId: vineyardId,
                stationId: stationId,
                days: total,
                offsetDays: offset,
                chunkDays: chunk
            )
            processedTotal += r.daysProcessed
            rowsTotal += r.rowsUpserted
            errorsTotal += r.errorsCount
            chunks += 1
            lastVersion = r.proxyVersion ?? lastVersion
            if let n = r.stationName, !n.isEmpty { lastStationLabel = n }
            else if let s = r.stationId, !s.isEmpty, lastStationLabel == nil { lastStationLabel = s }

            progress?(ChunkedRainfallProgress(
                daysProcessed: processedTotal,
                daysRequested: total,
                rowsUpsertedTotal: rowsTotal,
                chunksCompleted: chunks,
                lastChunkRows: r.rowsUpserted,
                lastChunkSlice: r.sliceLength,
                nextOffset: r.nextOffsetDays,
                rateLimited: r.rateLimited
            ))

            if r.rateLimited {
                rateLimited = true
                offset = r.nextOffsetDays ?? (offset + max(1, r.sliceLength))
                break
            }
            guard let next = r.nextOffsetDays, r.more else {
                offset = total
                break
            }
            if next <= offset { break }
            offset = next
            try? await Task.sleep(nanoseconds: 350_000_000)
        }

        let completed = !rateLimited && offset >= total
        return ChunkedRainfallBackfillResult(
            daysRequested: total,
            daysProcessed: processedTotal,
            rowsUpserted: rowsTotal,
            errorsCount: errorsTotal,
            chunksCompleted: chunks,
            rateLimited: rateLimited,
            completed: completed,
            resumeOffset: completed ? nil : offset,
            proxyVersion: lastVersion,
            stationLabel: lastStationLabel
        )
    }

    // MARK: - Resume offsets (UserDefaults)

    /// Per-vineyard / per-source key used to remember where a chunked
    /// backfill left off after a rate-limit so the user can resume later.
    enum ResumeSource: String { case davis, wunderground }

    static func resumeOffsetKey(_ source: ResumeSource, vineyardId: UUID) -> String {
        "rainfall.history.resume.\(source.rawValue).\(vineyardId.uuidString)"
    }

    static func loadResumeOffset(_ source: ResumeSource, vineyardId: UUID) -> Int {
        UserDefaults.standard.integer(forKey: resumeOffsetKey(source, vineyardId: vineyardId))
    }

    static func saveResumeOffset(_ source: ResumeSource, vineyardId: UUID, offset: Int?) {
        let key = resumeOffsetKey(source, vineyardId: vineyardId)
        if let offset, offset > 0 {
            UserDefaults.standard.set(offset, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
