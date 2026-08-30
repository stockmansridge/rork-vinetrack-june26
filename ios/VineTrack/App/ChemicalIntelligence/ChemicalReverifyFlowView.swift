import SwiftUI

/// Re-verify Chemical — re-checking a product VineTrack has ALREADY identified.
///
/// Deliberately not a wizard. Match & Verify is a wizard because the product is
/// unknown and the operator has to choose which registration it is. Here the
/// identity is already held, so there is exactly one question — "has the official
/// information moved?" — and the screen answers it in one step: Checking, then
/// Current, Changes Found, or Failure.
///
/// Nothing in this file decides anything. Eligibility comes from
/// `ChemicalReverification.isOffered`, the lookup key from
/// `ChemicalReverification.Plan`, the comparison from
/// `ChemicalIntelligenceDiffer`, and the written result from
/// `ChemicalReverification.apply` — which routes through
/// `ChemicalEditReconciler`, so the trust level is COMPUTED and there is no
/// "Mark Verified" button to be found anywhere.
struct ChemicalReverifyFlowView: View {
    let chemical: SavedChemical
    /// Called only when a write actually happened.
    ///
    /// The edit sheet uses this to close itself: it captured its form fields from
    /// the record at init, and letting a stale form Save over a freshly
    /// re-verified record would silently undo the update the operator just
    /// accepted.
    var onCompleted: () -> Void = {}

    @Environment(MigratedDataStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case checking
        /// Nothing about the product moved. `refreshed` is the evidence-only
        /// update to store, or `nil` when there is no structured record to
        /// refresh — a no-change result must not materialise a legacy seed.
        case current(candidate: ChemicalIntelligence, refreshed: ChemicalIntelligence?)
        /// Something moved. The outcome is computed ONCE here and both previewed
        /// and written, so the operator accepts exactly what they were shown.
        case changes(
            candidate: ChemicalIntelligence,
            diff: ChemicalIntelligenceDiff,
            outcome: ChemicalEditOutcome
        )
        case failed(String)
    }

    @State private var phase: Phase = .checking
    @State private var hasStarted: Bool = false
    /// Set the moment a write is committed, and never cleared.
    ///
    /// The accept and confirm buttons each write once and then dismiss. Dismissal
    /// is not instantaneous, so without this a double tap fires the handler twice
    /// and the second call writes an outcome computed against the pre-update
    /// record — undoing part of what the operator just accepted. Mirrors the
    /// `saving` guard on Android's `ChemicalReverifySheet`.
    @State private var isWriting: Bool = false

    private var countryCode: String {
        ChemicalRegistration.normaliseCountry(
            ChemicalInfoService.resolveCountry(vineyardCountry: store.selectedVineyard?.country)
        )
    }

    private var plan: ChemicalReverification.Plan {
        ChemicalReverification.plan(for: chemical, fallbackCountry: countryCode)
    }

    /// What the Chemical Store currently DISPLAYS for this product.
    private var currentIntelligence: ChemicalIntelligence? {
        ChemicalReverifyFlow.currentIntelligence(chemical)
    }

    var body: some View {
        NavigationStack {
            List {
                switch phase {
                case .checking:
                    checkingSection
                case let .current(candidate, refreshed):
                    currentResult(candidate: candidate, refreshed: refreshed)
                case let .changes(candidate, diff, outcome):
                    changesResult(candidate: candidate, diff: diff, outcome: outcome)
                case let .failed(message):
                    failureResult(message)
                }
            }
            .navigationTitle("Re-verify Chemical")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // Cancel is always available and always writes nothing.
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task {
            guard !hasStarted else { return }
            hasStarted = true
            await run()
        }
    }

    // MARK: - Checking

    private var checkingSection: some View {
        Group {
            Section {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Checking current product information…")
                        .font(.subheadline)
                }
            } footer: {
                Text("Your saved chemical is not changed until you accept an update.")
            }

            Section {
                ChemicalLookupDurationNotice(showsRepeatHint: true)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            identitySection
        }
    }

    /// What the lookup is being keyed on.
    ///
    /// Shown so the operator can see this is a re-check of the registration
    /// VineTrack holds, not a fresh brand-name search that might land on a
    /// different manufacturer's product with a similar name.
    private var identitySection: some View {
        Section {
            LabeledContent("Product", value: plan.productName.isEmpty ? "Unnamed" : plan.productName)
            if !plan.countryCode.isEmpty {
                LabeledContent("Country", value: plan.countryCode)
            }
            if let number = plan.registrationNumber, !number.isEmpty {
                LabeledContent("Registration", value: number)
            }
            if let registrant = plan.registrant, !registrant.isEmpty {
                LabeledContent("Registrant", value: registrant)
            }
            // Re-checking a foreign registration is still useful — it confirms
            // what the product IS — but it must never read as verifying the
            // product FOR this vineyard's jurisdiction.
            if case .mismatch(let registration, let vineyard) = ChemicalJurisdiction.suitability(
                registrationCountry: plan.countryCode,
                vineyardCountry: countryCode
            ) {
                Text(ChemicalJurisdiction.reverifyForeignNote(
                    registrationCountry: registration,
                    vineyardCountry: vineyard
                ))
                .font(.caption)
                .foregroundStyle(VineyardTheme.warning)
            }
        } header: {
            Text("Checking against")
        } footer: {
            Text(plan.strength.detail)
        }
    }

    // MARK: - Result: nothing changed

    private func currentResult(
        candidate: ChemicalIntelligence,
        refreshed: ChemicalIntelligence?
    ) -> some View {
        // The status shown is the one the record will actually hold: the refreshed
        // evidence when there is a structured record, otherwise what it already
        // resolves to. Never the lookup's own claim about itself.
        let resolved = (refreshed ?? currentIntelligence)?.resolvedVerificationStatus
            ?? chemical.verificationStatus
        return Group {
            Section {
                Label("Chemical information is current", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(VineyardTheme.success)
                Text("The register still reports the same chemistry, registration and label information VineTrack already holds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ChemicalIdentityView(
                    productName: (refreshed ?? currentIntelligence)?.registration?.registeredProductName
                        ?? chemical.name,
                    registration: (refreshed ?? currentIntelligence)?.registration,
                    productCategory: (refreshed ?? currentIntelligence)?.productCategory ?? ""
                )
                HStack {
                    Text("Verification")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    ChemicalVerificationBadge(status: resolved)
                }
            } header: {
                Text("Product identity")
            } footer: {
                Text(resolved.detail)
            }

            if let refreshed {
                Section {
                    ChemicalVerificationEvidenceView(
                        verification: refreshed.verification,
                        resolvedStatus: resolved
                    )
                } header: {
                    Text("Verification details")
                } footer: {
                    // Be explicit that only provenance moved. A "check date"
                    // is not a product change and must not read like one.
                    Text("Only the record of when this was last checked and which sources were consulted has been updated. No chemistry, rate or registered use was changed.")
                }
            }

            if !candidate.verification.conflicts.isEmpty {
                Section {
                    ChemicalConflictCard(conflicts: candidate.verification.conflicts)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }

            Section {
                Button {
                    confirmCurrent(refreshed)
                } label: {
                    Text(refreshed == nil ? "Close" : "Done")
                        .frame(maxWidth: .infinity)
                        .fontWeight(.semibold)
                }
                .disabled(isWriting)
            }
        }
    }

    // MARK: - Result: changes found

    private func changesResult(
        candidate: ChemicalIntelligence,
        diff: ChemicalIntelligenceDiff,
        outcome: ChemicalEditOutcome
    ) -> some View {
        // Conflicts come from the RECONCILED outcome, not the raw candidate: that
        // is the set which includes the reference-table cross-check plus the
        // lookup's own unresolved disagreements, and it is the set the record will
        // actually carry.
        let conflicts = outcome.intelligence.verification.conflicts
        let resolved = outcome.resolvedStatus
        return Group {
            Section {
                if conflicts.isEmpty {
                    Label("Updated information found", systemImage: "arrow.triangle.2.circlepath")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(VineyardTheme.info)
                } else {
                    // Identity matching is not the same as agreement. A conflicted
                    // candidate must never open with a green confirmation.
                    Label("Needs review", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                }
                Text(conflicts.isEmpty
                     ? "Review what has changed before updating this chemical."
                     : "The re-check returned information that disagrees with the reference classification. Review it before updating.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if diff.hasResistanceCriticalChanges {
                    Label("Includes resistance-critical changes", systemImage: "flask.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(VineyardTheme.warning)
                }
            }

            if !conflicts.isEmpty {
                Section {
                    ChemicalConflictCard(conflicts: conflicts)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }

            // Chemistry first, registry housekeeping last — the order comes from
            // the domain's own `displayOrder`, not from this file.
            ForEach(diff.populatedSections, id: \.rawValue) { section in
                Section {
                    ForEach(diff.changes(in: section)) { change in
                        changeRow(change)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text(section.label)
                        if diff.changes(in: section).contains(where: \.isResistanceCritical) {
                            Text("Resistance")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(VineyardTheme.warning.opacity(0.14))
                                .foregroundStyle(VineyardTheme.warning)
                                .clipShape(Capsule())
                        }
                    }
                }
            }

            Section {
                ChemicalVerificationEvidenceView(
                    verification: outcome.intelligence.verification,
                    resolvedStatus: resolved
                )
                HStack {
                    Text("After updating")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    ChemicalVerificationBadge(status: resolved)
                }
            } header: {
                Text("Verification details")
            } footer: {
                // The status is computed from the merged evidence. Say so, so
                // nobody reads the badge as something this screen chose.
                Text("\(resolved.detail) This status is derived from the evidence behind each value — it is not set by accepting this update.")
            }

            Section {
                Button {
                    accept(outcome)
                } label: {
                    Text("Apply verified changes")
                        .frame(maxWidth: .infinity)
                        .fontWeight(.semibold)
                }
                .disabled(isWriting)
                // The second decision is a DECISION, not an escape hatch.
                //
                // This used to be `Cancel`, which asks the operator to read
                // "abandon this screen" as "deliberately keep my own values".
                // Those are different sentences, and a compliance choice
                // should never be expressed by the button people press when
                // they want out. Android already words it this way; the
                // Portal does too.
                //
                // Behaviourally identical to the old Cancel — it writes
                // NOTHING. Keeping what you have is all-or-nothing: no
                // incoming value is partially applied, because a record half
                // from the old research and half from the new is a chemistry
                // nobody verified.
                Button("Keep what I have", role: .cancel) { dismiss() }
            } footer: {
                Text("Applying changes updates this Chemical Store record only. Keeping what you have writes nothing at all — no part of the update is applied. Completed spray records keep the chemical information that was captured at the time they were applied.")
            }
        }
    }

    /// One change, in the shape an operator reads: what it is, then current, then
    /// updated. Resistance-critical rows carry the emphasis.
    private func changeRow(_ change: ChemicalIntelligenceChange) -> some View {
        let tint: Color = change.isResistanceCritical ? VineyardTheme.warning : .secondary
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(change.title)
                    .font(change.isResistanceCritical
                          ? .subheadline.weight(.bold)
                          : .subheadline.weight(.medium))
                Text(change.kind.label)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(tint.opacity(0.12))
                    .foregroundStyle(tint)
                    .clipShape(Capsule())
            }
            if let current = change.currentValue {
                valueLine("Current", current, emphasised: false)
            }
            if let candidate = change.candidateValue {
                valueLine("Updated", candidate, emphasised: change.isResistanceCritical)
            }
        }
        .padding(.vertical, 2)
    }

    private func valueLine(_ title: String, _ value: String, emphasised: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 66, alignment: .leading)
            Text(value)
                .font(emphasised ? .caption.weight(.bold) : .caption.weight(.medium))
                .foregroundStyle(emphasised ? VineyardTheme.warning : .primary)
        }
    }

    // MARK: - Result: failure

    private func failureResult(_ message: String) -> some View {
        Group {
            Section {
                Label("Could not re-verify", systemImage: "wifi.exclamationmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(VineyardTheme.warning)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } footer: {
                // A failed lookup is not evidence about the product. It must
                // never cost a record the verification it already earned.
                Text("This chemical has not been changed. A failed check is not new information about the product, so its current verification status stands.")
            }

            Section {
                HStack {
                    Text("Current status")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    ChemicalVerificationBadge(status: chemical.verificationStatus)
                }
            }

            Section {
                Button("Try Again") {
                    Task { await run() }
                }
                Button("Cancel", role: .cancel) { dismiss() }
            }
        }
    }

    // MARK: - Actions

    /// One lookup, keyed on the strongest identity the record holds.
    ///
    /// Classification is delegated to `ChemicalReverifyFlow` so this view holds no
    /// rule of its own — the same code path the tests assert on.
    private func run() async {
        phase = .checking
        let plan = self.plan
        do {
            let lookup = try await ChemicalInfoService()
                .lookupStructured(productName: plan.lookupQuery, country: plan.countryCode)
            // Jurisdiction gate: the candidate must belong to the SAME country
            // the plan was keyed on (the record's own registration country,
            // vineyard only as fallback). A cross-country answer is a failed
            // check, never a diff — re-verification must not re-key a record
            // to a different country's label.
            if let reason = ChemicalJurisdiction.rejectionReason(
                for: lookup, requestCountry: plan.countryCode
            ) {
                phase = .failed(reason)
                return
            }
            switch ChemicalReverifyFlow.resolve(
                chemical: chemical,
                candidate: lookup.intelligence()
            ) {
            case let .current(candidate, refreshed):
                phase = .current(candidate: candidate, refreshed: refreshed)
            case let .changes(candidate, diff, outcome):
                phase = .changes(candidate: candidate, diff: diff, outcome: outcome)
            case let .unusable(reason):
                phase = .failed(reason)
            }
        } catch {
            phase = .failed(
                (error as? LocalizedError)?.errorDescription
                    ?? "The lookup is unavailable. Check your connection and try again."
            )
        }
    }

    /// Accept an update. The outcome was already reconciled and displayed, so
    /// what is written is exactly what was reviewed.
    private func accept(_ outcome: ChemicalEditOutcome) {
        guard !isWriting else { return }
        isWriting = true
        store.updateSavedChemical(ChemicalReverifyFlow.accepted(chemical, with: outcome))
        onCompleted()
        dismiss()
    }

    /// Close a no-change result, storing the refreshed evidence when there is any.
    private func confirmCurrent(_ refreshed: ChemicalIntelligence?) {
        guard let refreshed else {
            dismiss()
            return
        }
        guard !isWriting else { return }
        isWriting = true
        store.updateSavedChemical(ChemicalReverifyFlow.confirmed(chemical, with: refreshed))
        onCompleted()
        dismiss()
    }
}
