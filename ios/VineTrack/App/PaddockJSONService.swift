import Foundation

/// Local JSON import / export for paddocks (blocks).
///
/// File shape:
/// {
///   "version": 1,
///   "exportedAt": "2026-04-29T...",
///   "vineyardId": "<uuid>",
///   "paddocks": [ <Paddock>, ... ]
/// }
enum PaddockJSONService {

    nonisolated struct ImportSummary: Sendable {
        var created: Int = 0
        var updated: Int = 0
        var skipped: Int = 0
        var errors: [String] = []
    }

    nonisolated enum ImportError: LocalizedError {
        case invalidJSON
        case emptyFile
        case noPaddocks

        var errorDescription: String? {
            switch self {
            case .invalidJSON: return "This file is not a valid VineTrack blocks JSON file."
            case .emptyFile: return "The selected file is empty."
            case .noPaddocks: return "The file did not contain any blocks."
            }
        }
    }

    nonisolated struct ExportFile: Codable, Sendable {
        let version: Int
        let exportedAt: Date
        let vineyardId: UUID?
        let paddocks: [Paddock]
    }

    // MARK: - Export

    static func generateJSON(paddocks: [Paddock], vineyardId: UUID?) -> Data {
        let payload = ExportFile(
            version: 1,
            exportedAt: Date(),
            vineyardId: vineyardId,
            paddocks: paddocks
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(payload)) ?? Data("{}".utf8)
    }

    static func saveJSONToTemp(data: Data, fileName: String) -> URL {
        let safeName = fileName.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safeName)
        try? data.write(to: url)
        return url
    }

    // MARK: - Import

    static func parseJSON(data: Data, vineyardId: UUID, existing: [Paddock]) throws -> (paddocks: [Paddock], summary: ImportSummary) {
        guard !data.isEmpty else { throw ImportError.emptyFile }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let parsedPaddocks: [Paddock]
        if let file = try? decoder.decode(ExportFile.self, from: data) {
            parsedPaddocks = file.paddocks
        } else if let array = try? decoder.decode([Paddock].self, from: data) {
            parsedPaddocks = array
        } else {
            // Fallback: try ISO8601 with fractional seconds via custom strategy
            let altDecoder = JSONDecoder()
            altDecoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                let string = try container.decode(String.self)
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = formatter.date(from: string) { return date }
                formatter.formatOptions = [.withInternetDateTime]
                if let date = formatter.date(from: string) { return date }
                if let interval = TimeInterval(string) { return Date(timeIntervalSince1970: interval) }
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date \(string)")
            }
            if let file = try? altDecoder.decode(ExportFile.self, from: data) {
                parsedPaddocks = file.paddocks
            } else if let array = try? altDecoder.decode([Paddock].self, from: data) {
                parsedPaddocks = array
            } else {
                throw ImportError.invalidJSON
            }
        }

        guard !parsedPaddocks.isEmpty else { throw ImportError.noPaddocks }

        let existingById: [UUID: Paddock] = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

        var summary = ImportSummary()
        var resultPaddocks: [Paddock] = []

        for (index, incoming) in parsedPaddocks.enumerated() {
            let entryNumber = index + 1
            guard !incoming.name.trimmingCharacters(in: .whitespaces).isEmpty else {
                summary.skipped += 1
                summary.errors.append("Block \(entryNumber): missing name")
                continue
            }

            var paddock = incoming
            paddock.vineyardId = vineyardId

            if existingById[paddock.id] != nil {
                summary.updated += 1
            } else {
                summary.created += 1
            }
            resultPaddocks.append(paddock)
        }

        return (resultPaddocks, summary)
    }
}
