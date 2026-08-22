import Foundation

/// Which evidence tier supplied the one visible Official Label link.
///
/// Recorded so a test — and a diagnostic — can assert WHERE the URL came from,
/// not merely that some URL arrived. "Blank because nothing was returned" and
/// "blank because we dropped it on decode" are different defects and must not
/// look the same.
nonisolated enum ChemicalLabelReferenceOrigin: String, Sendable, Hashable {
    /// `registration.label_reference` carrying authoritative provenance —
    /// the register portal itself confirmed this document for this identity.
    case registerConfirmedDocument
    /// `label_extraction.document_url` — the document a completed extraction
    /// pass actually read. Same document, stated by the extractor.
    case labelExtractionDocument
    /// A `verification.sources[]` entry of official-register or
    /// manufacturer-label kind whose reference is itself a label document.
    case labelEvidenceSource
    /// `registration.label_reference` with no authoritative provenance — the
    /// lookup's own reading, already server-validated for reachability.
    case structuredRegistration
    /// The structured reference already on the saved record.
    case existingStructured
    /// The legacy `saved_chemicals.label_url` column.
    case existingRecord

    /// Whether this tier is the lookup speaking, or the record/operator.
    ///
    /// Lookup-derived candidates must clear the label-document test before
    /// they may occupy the Official Label field. A value the operator already
    /// has on the record is theirs and is never second-guessed.
    var isLookupDerived: Bool {
        switch self {
        case .registerConfirmedDocument, .labelExtractionDocument,
             .labelEvidenceSource, .structuredRegistration:
            return true
        case .existingStructured, .existingRecord:
            return false
        }
    }
}

/// The chosen Official Label link and the tier that supplied it.
nonisolated struct ChemicalLabelReferenceChoice: Sendable, Hashable {
    let url: String
    let origin: ChemicalLabelReferenceOrigin
}

/// Picks the ONE Official Label link out of everything a lookup returned.
///
/// # Why this type exists
///
/// The backend states a label document in more than one place, by design: the
/// register portal confirms a document URL (Stage LD-1, which lands in
/// `registration.label_reference`), and a completed text-extraction pass
/// reports the document it actually read (Stage LD-2 `label_extraction`).
/// Those are two statements about the SAME document, not two documents, and
/// `ChemicalStructuredLookup` decoded only the first — so a lookup that
/// extracted a label but whose register-side document discovery came back
/// empty reached the Review screen with an empty Official Label field while
/// the URL sat in the response, decoded by nobody.
///
/// This resolver reads every place the address can legitimately appear and
/// returns the strongest one, so there is still exactly one visible label
/// field and exactly one value that can fill it.
///
/// # What it will not do
///
/// It will not promote a marketing page. A registrant's product page is a
/// real, useful link — it has its own field — but presenting it as the
/// approved label invites an operator to spray off a brochure. Lookup-derived
/// candidates must therefore look like a label DOCUMENT; a value already on
/// the record passes through untouched, because that one is the operator's.
nonisolated enum ChemicalLabelReference {

    /// Whether a URL is plausibly the official label DOCUMENT.
    ///
    /// Mirrors the edge function's own `looksLikeLabelURL` rejections (bare
    /// host, search/category pages) and then requires a positive signal: a PDF
    /// or document extension, a known eLabels host, or "label" stated in the
    /// path or query. Absence of a signal is a refusal, not a pass — the
    /// failure mode being guarded against is a plausible-looking product page
    /// silently becoming the label.
    static func looksLikeLabelDocument(_ raw: String) -> Bool {
        let sanitised = LabelURLValidator.sanitize(raw, requireDocumentPath: true)
        guard !sanitised.isEmpty,
              let url = URL(string: sanitised),
              let host = url.host?.lowercased()
        else { return false }

        let path = url.path.lowercased()
        let query = (url.query ?? "").lowercased()

        // Generic navigation surfaces are never a specific product's label.
        for segment in ["/search", "/category", "/categories", "/tag", "/tags", "/products"]
        where path.hasPrefix(segment) || path.contains("\(segment)/") {
            return false
        }

        // A register's own label-document host.
        if host.contains("elabels") { return true }

        for suffix in [".pdf", ".doc", ".docx"] where path.hasSuffix(suffix) {
            return true
        }
        if path.contains("label") || query.contains("label") { return true }
        return false
    }

    /// Resolve the Official Label link for a review draft.
    ///
    /// - Parameters:
    ///   - lookup: the structured response, or `nil` when none ran.
    ///   - existingStructured: the structured reference already on the record.
    ///   - existingRecordURL: the legacy `label_url` column on the record.
    /// - Returns: the strongest actual label reference, or `nil` when no tier
    ///   supplied one. `nil` means the lookup genuinely returned no label
    ///   address — it is never the result of a value being dropped.
    static func resolve(
        lookup: ChemicalStructuredLookup?,
        existingStructured: String?,
        existingRecordURL: String?
    ) -> ChemicalLabelReferenceChoice? {
        for candidate in candidates(
            lookup: lookup,
            existingStructured: existingStructured,
            existingRecordURL: existingRecordURL
        ) {
            let requiresDocument = candidate.origin.isLookupDerived
            if requiresDocument {
                guard looksLikeLabelDocument(candidate.url) else { continue }
                return ChemicalLabelReferenceChoice(
                    url: LabelURLValidator.sanitize(candidate.url, requireDocumentPath: true),
                    origin: candidate.origin
                )
            }
            let sanitised = LabelURLValidator.sanitize(candidate.url)
            guard !sanitised.isEmpty else { continue }
            return ChemicalLabelReferenceChoice(url: sanitised, origin: candidate.origin)
        }
        return nil
    }

    /// Every place a label address can legitimately appear, strongest first.
    ///
    /// Exposed for diagnostics: when the field is blank, the honest question
    /// is "what did the response actually carry?", and this answers it without
    /// a second lookup.
    static func candidates(
        lookup: ChemicalStructuredLookup?,
        existingStructured: String?,
        existingRecordURL: String?
    ) -> [ChemicalLabelReferenceChoice] {
        var out: [ChemicalLabelReferenceChoice] = []

        func add(_ raw: String?, _ origin: ChemicalLabelReferenceOrigin) {
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else { return }
            out.append(ChemicalLabelReferenceChoice(url: trimmed, origin: origin))
        }

        let registrationReference = lookup?.registration?.labelReference
        // `field_provenance.label_reference` is the resolver's own statement
        // about how it established this URL. `official_register` and
        // `manufacturer_label` are its two authoritative tiers.
        let provenance = lookup?.fieldProvenance?["label_reference"]
        let isAuthoritative = provenance == ChemicalDataSourceKind.officialRegister.rawValue
            || provenance == ChemicalDataSourceKind.manufacturerLabel.rawValue

        if isAuthoritative { add(registrationReference, .registerConfirmedDocument) }
        add(lookup?.labelExtraction?.documentURL, .labelExtractionDocument)

        // Label EVIDENCE: a cited source that is itself the label document.
        // Filtered by kind first — an AI-interpretation source citing a page
        // it read is not label evidence, whatever the URL looks like.
        for source in lookup?.verification.sources ?? []
        where source.kind == .manufacturerLabel || source.kind == .officialRegister {
            add(source.reference, .labelEvidenceSource)
        }

        if !isAuthoritative { add(registrationReference, .structuredRegistration) }
        add(existingStructured, .existingStructured)
        add(existingRecordURL, .existingRecord)
        return out
    }
}

/// Stage LD-2 document-extraction provenance (`label_extraction`).
///
/// Additive on the wire and present only when a document text pass actually
/// completed. Decoded for ONE reason: `document_url` is the address of the
/// official label the extractor read, and it is the strongest label reference
/// available on responses where register-side document discovery returned
/// nothing. It is never shown as a separate user-facing field — one label,
/// one visible link.
nonisolated struct ChemicalLabelExtraction: Sendable, Hashable {
    let documentURL: String?
    let documentSHA256: String?
    let parserVersion: String?

    nonisolated enum CodingKeys: String, CodingKey {
        case documentURL = "document_url"
        case documentSHA256 = "document_sha256"
        case parserVersion = "parser_version"
    }
}

extension ChemicalLabelExtraction: Codable {
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        documentURL = try? c.decodeIfPresent(String.self, forKey: .documentURL)
        documentSHA256 = try? c.decodeIfPresent(String.self, forKey: .documentSHA256)
        // Tolerated as a number by older writers; a version string is never
        // worth failing a lookup over.
        if let text = try? c.decodeIfPresent(String.self, forKey: .parserVersion) {
            parserVersion = text
        } else if let number = try? c.decodeIfPresent(Int.self, forKey: .parserVersion) {
            parserVersion = String(number)
        } else {
            parserVersion = nil
        }
    }
}
