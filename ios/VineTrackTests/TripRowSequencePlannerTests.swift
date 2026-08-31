//
//  TripRowSequencePlannerTests.swift
//  VineTrackTests
//
//  Regression cover for the cross-platform path-generation defect: patterns
//  used to invent `totalRows + 1` numeric paths from the selected local start
//  row, so a block of rows 69–108 started at path 108.5 produced 147.5 →
//  146.5 → … — paths that do not exist in the vineyard.
//
//  The contract these tests pin: `availablePaths` is the authoritative
//  universe, and every value a planned pattern emits is a member of it.
//

import Testing
@testable import VineTrack

struct TripRowSequencePlannerTests {

    // MARK: - Helpers

    /// The valid path universe for a set of ACTUAL configured row numbers.
    /// For each row N the paths N-0.5 and N+0.5 are valid.
    private func paths(forRows rows: [Int]) -> [Double] {
        var set = Set<Double>()
        for n in rows {
            set.insert(Double(n) - 0.5)
            set.insert(Double(n) + 0.5)
        }
        return set.sorted()
    }

    /// The Pinot Noir block from the production report: 40 actual rows,
    /// 41 valid paths (68.5 … 108.5).
    private var pinotNoirPaths: [Double] { paths(forRows: Array(69...108)) }

    /// Every pattern that plans a sequence (Free Drive plans nothing).
    private let plannedPatterns: [TrackingPattern] = [
        .sequential, .everySecondRow, .fiveThree, .upAndBack, .twoRowUpBack, .custom,
    ]

    // MARK: - The exact production case

    /// rows 69…108, sequential, startPath 108.5, Higher → Lower.
    /// Was: 147.5 → 146.5 → 145.5 …  Must be: 108.5 → 107.5 → … → 68.5.
    @Test func production_sequential_start108_5_higherToLower() {
        let seq = TripRowSequencePlanner.plannedSequence(
            paths: pinotNoirPaths,
            pattern: .sequential,
            startPath: 108.5,
            higherFirst: false
        )
        #expect(seq.first == 108.5)
        #expect(seq.last == 68.5)
        #expect(seq.count == 41)
        #expect(Array(seq.prefix(3)) == [108.5, 107.5, 106.5])
        // The defect's signature value must be nowhere in the sequence.
        #expect(!seq.contains(147.5))
        #expect(seq.allSatisfy { $0 >= 68.5 && $0 <= 108.5 })
    }

    /// rows 69…108, start 68.5, Lower → Higher ⇒ 68.5 … 108.5.
    @Test func production_sequential_start68_5_lowerToHigher() {
        let seq = TripRowSequencePlanner.plannedSequence(
            paths: pinotNoirPaths,
            pattern: .sequential,
            startPath: 68.5,
            higherFirst: true
        )
        #expect(seq.first == 68.5)
        #expect(seq.last == 108.5)
        #expect(seq.count == 41)
    }

    /// A mid-block start must still cover every path, wrapping to the far side.
    /// 90.5 … 108.5, then 68.5 … 89.5.
    @Test func production_sequential_start90_5_lowerToHigher_wraps() {
        let seq = TripRowSequencePlanner.plannedSequence(
            paths: pinotNoirPaths,
            pattern: .sequential,
            startPath: 90.5,
            higherFirst: true
        )
        #expect(seq.first == 90.5)
        #expect(seq.count == 41)
        #expect(Set(seq).count == 41)
        #expect(seq[18] == 108.5)
        #expect(seq[19] == 68.5)
        #expect(seq.last == 89.5)
    }

    /// The same mid-block start in the opposite direction.
    /// 90.5 … 68.5, then 108.5 … 91.5.
    @Test func production_sequential_start90_5_higherToLower_wraps() {
        let seq = TripRowSequencePlanner.plannedSequence(
            paths: pinotNoirPaths,
            pattern: .sequential,
            startPath: 90.5,
            higherFirst: false
        )
        #expect(seq.first == 90.5)
        #expect(seq.count == 41)
        #expect(Set(seq).count == 41)
        #expect(seq[1] == 89.5)
        #expect(seq[22] == 68.5)
        #expect(seq[23] == 108.5)
        #expect(seq.last == 91.5)
    }

    // MARK: - Universe membership for every planned pattern

    /// No planned pattern may emit a value outside `availablePaths`, in either
    /// direction, from any start path. Up and Back may repeat a valid path.
    @Test func everyPlannedPattern_onlyEmitsAvailablePaths() {
        let universe = Set(pinotNoirPaths)
        for pattern in plannedPatterns {
            for higherFirst in [true, false] {
                for start in [68.5, 90.5, 108.5] {
                    let seq = TripRowSequencePlanner.plannedSequence(
                        paths: pinotNoirPaths,
                        pattern: pattern,
                        startPath: start,
                        higherFirst: higherFirst
                    )
                    #expect(!seq.isEmpty, "\(pattern.rawValue) produced nothing")
                    for path in seq {
                        #expect(
                            universe.contains(path),
                            "\(pattern.rawValue) invented path \(path)"
                        )
                    }
                }
            }
        }
    }

    /// For patterns where Start Path is meaningful the traversal must BEGIN on
    /// the selected path. (2 Row Up & Back deliberately opens one path along —
    /// spray two, skip two — so it is asserted separately below.)
    @Test func startPathIsHonoured_forStartMeaningfulPatterns() {
        for pattern in [TrackingPattern.sequential, .everySecondRow, .fiveThree, .upAndBack, .custom] {
            for higherFirst in [true, false] {
                let seq = TripRowSequencePlanner.plannedSequence(
                    paths: pinotNoirPaths,
                    pattern: pattern,
                    startPath: 90.5,
                    higherFirst: higherFirst
                )
                #expect(seq.first == 90.5, "\(pattern.rawValue) did not start on the start path")
            }
        }
    }

    /// Full coverage: the once-through patterns visit all 41 paths exactly once.
    @Test func coveragePatterns_visitEveryPathOnce() {
        for pattern in [TrackingPattern.sequential, .fiveThree, .twoRowUpBack, .custom] {
            let seq = TripRowSequencePlanner.plannedSequence(
                paths: pinotNoirPaths,
                pattern: pattern,
                startPath: 108.5,
                higherFirst: false
            )
            #expect(Set(seq).count == 41, "\(pattern.rawValue) missed paths")
            #expect(seq.count == 41, "\(pattern.rawValue) repeated paths")
        }
    }

    /// Up and Back intentionally repeats each valid path.
    @Test func upAndBack_repeatsEachValidPath() {
        let seq = TripRowSequencePlanner.plannedSequence(
            paths: pinotNoirPaths,
            pattern: .upAndBack,
            startPath: 108.5,
            higherFirst: false
        )
        #expect(seq.count == 82)
        #expect(Set(seq).count == 41)
        #expect(Array(seq.prefix(4)) == [108.5, 108.5, 107.5, 107.5])
    }

    // MARK: - Non-contiguous multi-block selection

    /// Rows 1–14 and 69–108 selected together. `maxRow - minRow + 1` is 108,
    /// but only 54 rows are configured — the planner must never walk the gap.
    @Test func nonContiguousSelection_producesNoPhantomPathsInTheGap() {
        let rows = Array(1...14) + Array(69...108)
        let universe = paths(forRows: rows)
        #expect(universe.count == 56)

        for pattern in plannedPatterns {
            for higherFirst in [true, false] {
                let seq = TripRowSequencePlanner.plannedSequence(
                    paths: universe,
                    pattern: pattern,
                    startPath: 108.5,
                    higherFirst: higherFirst
                )
                let valid = Set(universe)
                for path in seq {
                    #expect(valid.contains(path), "\(pattern.rawValue) invented \(path)")
                    // Nothing may appear strictly inside the row 15…68 gap.
                    #expect(
                        !(path > 14.5 && path < 68.5),
                        "\(pattern.rawValue) walked the gap at \(path)"
                    )
                }
            }
        }
    }

    /// Sequential across the non-contiguous selection jumps the gap in one
    /// step rather than inventing the rows between.
    @Test func nonContiguousSelection_sequentialJumpsTheGap() {
        let rows = Array(1...14) + Array(69...108)
        let seq = TripRowSequencePlanner.plannedSequence(
            paths: paths(forRows: rows),
            pattern: .sequential,
            startPath: 0.5,
            higherFirst: true
        )
        #expect(seq.first == 0.5)
        #expect(seq.last == 108.5)
        #expect(seq.count == 56)
        // 14.5 is the last path of the low block; 68.5 the first of the high.
        let gapIndex = seq.firstIndex(of: 14.5)
        #expect(gapIndex != nil)
        if let i = gapIndex {
            #expect(seq[i + 1] == 68.5)
        }
    }

    // MARK: - Start path / Free Drive

    /// The start path used for planning is itself always a valid path.
    @Test func clampedStartPath_snapsOntoTheUniverse() {
        let ordered = TripRowSequencePlanner.orderedTraversal(
            paths: pinotNoirPaths,
            startPath: 999.0,
            higherFirst: true
        )
        #expect(ordered.first == 108.5)
        #expect(Set(ordered).count == 41)
    }

    /// Free Drive plans no sequence at all.
    @Test func freeDrive_hasNoPlannedSequence() {
        let seq = TripRowSequencePlanner.plannedSequence(
            paths: pinotNoirPaths,
            pattern: .freeDrive,
            startPath: 108.5,
            higherFirst: false
        )
        #expect(seq.isEmpty)
    }
}
