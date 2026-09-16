import Testing
import Foundation
@testable import VineTrack

/// Vineyard Insights Round 1 — access gating, Vintage Notes and Scout capture.
///
/// Mirrors the Android `VineyardInsightsAccessTest`, `VintageNotesTest` and
/// `ScoutCaptureTest`. The cross-platform parity assertions are duplicated on
/// purpose: the same vineyard is scouted from both apps, so a divergence in a
/// stored code must fail a build rather than a vintage.
@MainActor
struct VineyardInsightsTests {

    private let vineyardID = UUID()
    private let otherVineyardID = UUID()
    private let blockA = UUID()
    private let blockB = UUID()

    /// An isolated defaults suite so each test starts from empty storage and
    /// never touches the real app's data.
    private func makeService(now: @escaping () -> Date = { Date() }) -> VineyardInsightsService {
        let suiteName = "vineyard-insights-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return VineyardInsightsService(
            store: VineyardInsightsStore(defaults: defaults),
            now: now
        )
    }

    // MARK: - Access

    private func access(
        isAuthenticated: Bool = true,
        isResolving: Bool = false,
        isSystemAdmin: Bool = true,
        vineyardID: UUID? = UUID(),
        isMember: Bool = true
    ) -> VineyardInsightsAccess {
        VineyardInsightsAccess.resolve(
            isAuthenticated: isAuthenticated,
            isResolving: isResolving,
            isSystemAdmin: isSystemAdmin,
            selectedVineyardID: vineyardID,
            isMemberOfSelectedVineyard: isMember
        )
    }

    @Test("A System Admin who is a member of the selected vineyard may use the preview")
    func systemAdminMemberAllowed() {
        #expect(access().isAllowed)
    }

    @Test("A vineyard owner who is not a System Admin is denied")
    func ownerDenied() {
        // Owner is a CUSTOMER-level role. It confers no platform authority, and
        // this is the case that would leak an unreleased preview to every
        // customer if the two were ever conflated.
        #expect(access(isSystemAdmin: false) == .unavailable(.notSystemAdmin))
    }

    @Test("A System Admin without membership of the selected vineyard is denied")
    func adminWithoutMembershipDenied() {
        // Platform authority is not a skeleton key into a grower's business.
        #expect(access(isMember: false) == .unavailable(.notVineyardMember))
    }

    @Test("A System Admin with no vineyard selected is denied")
    func adminWithoutVineyardDenied() {
        #expect(access(vineyardID: nil) == .unavailable(.notVineyardMember))
    }

    @Test("A still-resolving session is denied rather than optimistically allowed")
    func resolvingDenied() {
        // This is what stops the tile flashing into view during launch. A flash
        // is not untidy — it discloses that the feature exists.
        #expect(access(isResolving: true) == .unavailable(.stillResolving))
    }

    @Test("Signing out removes access immediately, even with a stale admin flag")
    func signedOutDenied() {
        #expect(access(isAuthenticated: false, isSystemAdmin: true) == .unavailable(.notAuthenticated))
    }

    @Test("The tool is absent from the authorised catalogue for a non-admin")
    func catalogueHidesPreview() {
        let ids = OperationalToolCatalog
            .authorised(canViewCosting: true, canUseVineyardInsights: false)
            .map(\.id)

        #expect(!ids.contains(VineyardInsightsCatalog.toolID))
    }

    @Test("The tool appears only when the resolved access decision allows it")
    func catalogueShowsPreviewWhenAllowed() {
        let ids = OperationalToolCatalog
            .authorised(canViewCosting: false, canUseVineyardInsights: true)
            .map(\.id)

        #expect(ids.contains(VineyardInsightsCatalog.toolID))
    }

    @Test("Authorisation defaults to closed when a caller has not resolved access")
    func catalogueFailsClosedByDefault() {
        // An older call site must not expose the preview by omission.
        let ids = OperationalToolCatalog.authorised(canViewCosting: true).map(\.id)

        #expect(!ids.contains(VineyardInsightsCatalog.toolID))
    }

    @Test("A saved layout cannot reveal the tool to a non-admin")
    func savedLayoutCannotReveal() {
        // Customisation is applied ON TOP of the authorised catalogue, so a
        // preference row naming the preview is just an unknown id.
        let authorised = OperationalToolCatalog
            .authorised(canViewCosting: true, canUseVineyardInsights: false)
            .map(\.id)
        let savedLayout = [VineyardInsightsCatalog.toolID, "work_tasks"]

        #expect(savedLayout.filter { authorised.contains($0) } == ["work_tasks"])
    }

    @Test("The costing permission cannot substitute for System Admin")
    func costingIsNotAdmin() {
        let costingOnly = OperationalToolCatalog
            .authorised(canViewCosting: true, canUseVineyardInsights: false)

        #expect(costingOnly.contains { $0.id == "cost_reports" })
        #expect(!costingOnly.contains { $0.requirement == .systemAdminPreview })
    }

    @Test("The preview declares the exact required display strings")
    func previewStrings() {
        let tool = OperationalToolCatalog.tool(id: VineyardInsightsCatalog.toolID)

        #expect(tool?.title == "Vineyard Insights")
        #expect(tool?.subtitle == "Scouting, vintage notes & reports")
        #expect(tool?.requirement == .systemAdminPreview)
        #expect(VineyardInsightsCatalog.previewBadge == "System Admin Preview")
    }

    @Test("The preview is last in the default order, matching SQL 236 display_order 140")
    func previewOrdering() {
        #expect(OperationalToolCatalog.defaultOrder.last == VineyardInsightsCatalog.toolID)
    }

    // MARK: - Vintage Notes

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        return Calendar.current.date(from: components)!
    }

    @Test("The vintage follows the configured season boundary, not the calendar year")
    func vintageFollowsSeason() {
        let june = VintageNoteDraft(date: date(2026, 6, 30))
        let july = VintageNoteDraft(date: date(2026, 7, 1))

        #expect(june.resolvedVintage(seasonStartMonth: 7, seasonStartDay: 1) == 2026)
        #expect(july.resolvedVintage(seasonStartMonth: 7, seasonStartDay: 1) == 2027)
    }

    @Test("A January season start labels the vintage with its own calendar year")
    func januarySeasonStart() {
        let draft = VintageNoteDraft(date: date(2026, 2, 15))

        #expect(draft.resolvedVintage(seasonStartMonth: 1, seasonStartDay: 1) == 2026)
    }

    @Test("Changing the note date recalculates the vintage without creating a second note")
    func changingDateRecalculatesVintage() {
        let service = makeService()
        var draft = VintageNoteDraft(date: date(2026, 6, 30), notes: "Frost damage")

        let before = service.saveNote(
            draft: draft,
            vineyardID: vineyardID,
            observedByUserID: nil,
            observerName: "Jonathan",
            seasonStartMonth: 7,
            seasonStartDay: 1
        )
        #expect(before?.vintageYear == 2026)

        draft.date = date(2026, 7, 2)
        let after = service.saveNote(
            draft: draft,
            vineyardID: vineyardID,
            observedByUserID: nil,
            observerName: "Jonathan",
            seasonStartMonth: 7,
            seasonStartDay: 1
        )

        #expect(after?.vintageYear == 2027)
        #expect(service.notes.count == 1)
    }

    @Test("The client vintage mirrors the authoritative resolver exactly")
    func clientMirrorsResolver() {
        // Display-only, but it still has to agree: otherwise the operator is
        // shown one vintage and the record is filed under another.
        let when = date(2026, 11, 15)
        let draft = VintageNoteDraft(date: when)

        #expect(
            draft.resolvedVintage(seasonStartMonth: 11, seasonStartDay: 1)
                == VintageResolver.vintageYear(for: when, seasonStartMonth: 11, seasonStartDay: 1)
        )
    }

    @Test("An empty type and empty notes cannot save")
    func emptyNoteRefused() {
        let service = makeService()
        let draft = VintageNoteDraft()

        #expect(!draft.canSave)
        #expect(draft.blockedReason == VintageNoteRules.emptyMessage)
        #expect(
            service.saveNote(
                draft: draft,
                vineyardID: vineyardID,
                observedByUserID: nil,
                observerName: nil,
                seasonStartMonth: 7,
                seasonStartDay: 1
            ) == nil
        )
        #expect(service.notes.isEmpty)
    }

    @Test("Notes alone can save, and a type alone can save")
    func eitherHalfIsEnough() {
        // Refusing either would push observers into picking an inaccurate type
        // just to get past validation.
        #expect(VintageNoteDraft(notes: "Heavy dew all week").canSave)

        let frost = VintageNoteCatalog.systemType("frost")
        #expect(frost != nil)
        #expect(VintageNoteDraft(noteTypeID: frost?.code, noteTypeLabel: frost?.label).canSave)
    }

    @Test("Whitespace-only notes with no type cannot save")
    func whitespaceRefused() {
        #expect(!VintageNoteDraft(notes: "   \n ").canSave)
    }

    @Test("An edit that does not touch the type keeps the original label snapshot")
    func labelSnapshotSurvivesEdit() {
        let service = makeService()
        let hail = VintageNoteCatalog.systemType("hail")!
        let saved = service.saveNote(
            draft: VintageNoteDraft(noteTypeID: hail.code, noteTypeLabel: hail.label),
            vineyardID: vineyardID,
            observedByUserID: nil,
            observerName: nil,
            seasonStartMonth: 7,
            seasonStartDay: 1
        )
        #expect(saved != nil)

        // The form carries no label this time — a blank must not erase history.
        let edited = service.saveNote(
            draft: VintageNoteDraft(id: saved!.id, noteTypeID: hail.code, notes: "Northern rows"),
            vineyardID: vineyardID,
            observedByUserID: nil,
            observerName: nil,
            seasonStartMonth: 7,
            seasonStartDay: 1
        )

        #expect(edited?.noteTypeLabelSnapshot == "Hail")
    }

    @Test("A retired type leaves the picker but stays readable on an existing note")
    func retiredTypeStaysReadable() {
        let service = makeService()
        let custom = service.addCustomNoteType(vineyardID: vineyardID, label: "Contractor delay")
        #expect(custom != nil)
        let saved = service.saveNote(
            draft: VintageNoteDraft(noteTypeID: custom!.code, noteTypeLabel: custom!.label),
            vineyardID: vineyardID,
            observedByUserID: nil,
            observerName: nil,
            seasonStartMonth: 7,
            seasonStartDay: 1
        )
        #expect(saved != nil)

        let retired = VintageNoteType(
            code: custom!.code,
            group: custom!.group,
            label: custom!.label,
            sortOrder: custom!.sortOrder,
            isCustom: true,
            isActive: false
        )

        #expect(!VintageNoteCatalog.selectable(customTypes: [retired]).contains { $0.code == custom!.code })
        #expect(service.notes.first?.noteTypeLabelSnapshot == "Contractor delay")
    }

    @Test("A custom type stays scoped to its own vineyard")
    func customTypeScoped() {
        let service = makeService()
        service.addCustomNoteType(vineyardID: vineyardID, label: "Creek crossing washed out")

        #expect(service.customNoteTypes(vineyardID: vineyardID).count == 1)
        #expect(service.customNoteTypes(vineyardID: otherVineyardID).isEmpty)
    }

    @Test("An offline retry of the same capture creates one note only")
    func offlineRetryIsIdempotent() {
        // The draft id is the idempotency key: a replay is an update of one
        // row, never a second note about the same event.
        let service = makeService()
        let draft = VintageNoteDraft(notes: "Hail through Block 4")

        for _ in 0..<3 {
            service.saveNote(
                draft: draft,
                vineyardID: vineyardID,
                observedByUserID: nil,
                observerName: nil,
                seasonStartMonth: 7,
                seasonStartDay: 1
            )
        }

        #expect(service.notes.count == 1)
    }

    @Test("Deletion is a tombstone rather than an erasure")
    func deletionIsTombstone() {
        let service = makeService()
        let saved = service.saveNote(
            draft: VintageNoteDraft(notes: "Wrong date"),
            vineyardID: vineyardID,
            observedByUserID: nil,
            observerName: nil,
            seasonStartMonth: 7,
            seasonStartDay: 1
        )
        #expect(saved != nil)

        service.deleteNote(saved!.id)

        // Retained locally so sync can reconcile it, gone from every display.
        #expect(service.notes.count == 1)
        #expect(service.notes.first?.isDeleted == true)
        #expect(service.notes(vintageYear: saved!.vintageYear).isEmpty)
    }

    @Test("Sign-out removes every locally held preview record")
    func signOutClears() {
        let service = makeService()
        service.saveNote(
            draft: VintageNoteDraft(notes: "Preview data"),
            vineyardID: vineyardID,
            observedByUserID: nil,
            observerName: nil,
            seasonStartMonth: 7,
            seasonStartDay: 1
        )
        #expect(service.notes.count == 1)

        service.clearOnSignOut()

        #expect(service.notes.isEmpty)
    }

    @Test("Notes list newest first")
    func notesSortNewestFirst() {
        let service = makeService()
        for (day, text) in [(1, "Older"), (15, "Newer")] {
            service.saveNote(
                draft: VintageNoteDraft(date: date(2026, 9, day), notes: text),
                vineyardID: vineyardID,
                observedByUserID: nil,
                observerName: nil,
                seasonStartMonth: 7,
                seasonStartDay: 1
            )
        }

        #expect(service.notes(vintageYear: 2027).map(\.notes) == ["Newer", "Older"])
    }

    @Test("The seeded catalogue matches the 39 types seeded by SQL 236")
    func catalogueCount() {
        #expect(VintageNoteCatalog.systemTypes.count == 39)
    }

    @Test("Weather types lead the grouped picker")
    func weatherLeadsPicker() {
        let groups = VintageNoteCatalog.grouped(customTypes: []).map(\.group)

        #expect(groups == [.weather, .phenology, .disease, .activity, .other])
        #expect(VintageNoteCatalog.grouped(customTypes: []).first?.types.first?.label == "Frost")
    }

    @Test("Note type codes and labels match Android exactly")
    func noteTypeParity() {
        // Byte-identical with the Android `VintageNoteCatalog.systemTypes`.
        let weather = VintageNoteCatalog.systemTypes
            .filter { $0.group == .weather }
            .sorted { $0.sortOrder < $1.sortOrder }

        #expect(weather.map(\.code) == [
            "frost", "low_temperature", "extended_dry", "excessive_heat", "high_winds",
            "heavy_rain", "extended_wet", "flooding", "hail", "smoke_exposure", "high_humidity",
        ])
        #expect(weather.map(\.label) == [
            "Frost", "Low temperature / cold spell", "Extended dry period",
            "Excessive heat / heatwave", "High winds", "Heavy rain", "Extended wet period",
            "Flooding / waterlogging", "Hail", "Smoke / bushfire exposure",
            "High humidity / persistent fog",
        ])
    }

    // MARK: - Scout

    private func startVisit(_ service: VineyardInsightsService) -> ScoutVisit {
        service.startVisit(
            vineyardID: vineyardID,
            scoutUserID: nil,
            scoutName: "Jonathan",
            seasonStartMonth: 7,
            seasonStartDay: 1,
            date: date(2026, 11, 20)
        )
    }

    private func assessmentID(_ service: VineyardInsightsService, _ visitID: UUID, _ block: UUID) -> UUID {
        service.visit(visitID)!.assessment(paddockID: block)!.id
    }

    @Test("A visit resolves its vintage from the season boundary")
    func visitVintage() {
        let service = makeService()

        #expect(startVisit(service).vintageYear == 2027)
    }

    @Test("A block cannot be assessed twice in one visit")
    func oneAssessmentPerBlock() {
        // Two partially-filled assessments would make "what did the scout find
        // in Block A?" ambiguous.
        let service = makeService()
        let visit = startVisit(service)
        service.toggleBlock(visitID: visit.id, paddockID: blockA)
        let first = assessmentID(service, visit.id, blockA)
        service.setObservationNotes(
            visitID: visit.id, assessmentID: first, item: .otherIssue, notes: "Rabbit damage"
        )

        service.toggleBlock(visitID: visit.id, paddockID: blockA)

        #expect(service.visit(visit.id)?.assessments.count == 1)
        #expect(service.visit(visit.id)?.assessments.first?.id == first)
    }

    @Test("Every assessment item is present and defaults to Not assessed")
    func defaultsToNotAssessed() {
        // "Not assessed" is a real stored answer, deliberately distinct from a
        // null: a report must be able to say the item was not assessed.
        let service = makeService()
        let visit = startVisit(service)
        service.toggleBlock(visitID: visit.id, paddockID: blockA)
        let assessment = service.visit(visit.id)!.assessment(paddockID: blockA)!

        #expect(assessment.observations.count == ScoutItem.allCases.count)
        let weeds = assessment.observation(.weeds)
        #expect(weeds?.valueCode == VineyardInsightsCatalog.notAssessedCode)
        #expect(weeds?.valueLabel == "Not assessed")
        #expect(weeds?.hasContent == false)
    }

    @Test("Dropdown codes and labels match Android exactly")
    func dropdownParity() {
        func codes(_ item: ScoutItem) -> [String] {
            VineyardInsightsCatalog.options(for: item).map(\.code)
        }
        func labels(_ item: ScoutItem) -> [String] {
            VineyardInsightsCatalog.options(for: item).map(\.label)
        }

        #expect(codes(.weeds) == ["not_assessed", "under_control", "needs_attention", "inhibiting_growth"])
        #expect(labels(.weeds) == ["Not assessed", "Under control", "Needs attention", "Inhibiting growth"])
        #expect(codes(.vineVigour) == ["not_assessed", "lacks_growth", "good_shoot_length", "consider_trimming"])
        #expect(labels(.vineVigour) == ["Not assessed", "Lacks growth", "Good shoot length", "Consider trimming"])
        #expect(codes(.soilMoisture) == [
            "not_assessed", "adequate", "low_soil_moisture", "soil_very_dry", "vines_showing_stress",
        ])
        #expect(labels(.soilMoisture) == [
            "Not assessed", "Adequate", "Low soil moisture", "Soil very dry", "Vines showing stress",
        ])
        #expect(codes(.powderyMildew) == ["not_assessed", "no_sign", "growth_on_leaves", "found_in_bunches"])
        #expect(labels(.powderyMildew) == ["Not assessed", "No sign", "Growth on leaves", "Found in bunches"])
        #expect(codes(.downyMildew) == [
            "not_assessed", "no_sign", "primary_infection", "on_leaves", "secondary_infection", "in_bunches",
        ])
        #expect(labels(.downyMildew) == [
            "Not assessed", "No sign", "Primary infection", "On leaves", "Secondary infection", "In bunches",
        ])
    }

    @Test("An unrecognised stored code yields no invented label")
    func unknownCodeHasNoLabel() {
        #expect(VineyardInsightsCatalog.label(for: .weeds, code: "some_future_code") == nil)
        #expect(!VineyardInsightsCatalog.isAssessed(item: .weeds, code: "some_future_code"))
    }

    @Test("An E-L selection creates exactly one canonical record")
    func growthStageCreate() {
        let observationID = UUID()

        let plan = ScoutGrowthStageLink.plan(
            observationID: observationID,
            vineyardID: vineyardID,
            paddockID: blockA,
            existingRecordID: nil,
            existingStageCode: nil,
            selectedStageCode: "EL23"
        )

        #expect(
            plan == .create(
                observationID: observationID,
                vineyardID: vineyardID,
                paddockID: blockA,
                stageCode: "EL23"
            )
        )
    }

    @Test("An offline replay of the same E-L capture does not duplicate the record")
    func growthStageReplayIsNoOp() {
        let recordID = UUID()

        let plan = ScoutGrowthStageLink.plan(
            observationID: UUID(),
            vineyardID: vineyardID,
            paddockID: blockA,
            existingRecordID: recordID,
            existingStageCode: "EL23",
            selectedStageCode: "EL23"
        )

        #expect(plan == .unchanged(growthStageRecordID: recordID))
    }

    @Test("Editing the E-L selection updates the canonical record in place")
    func growthStageEditUpdates() {
        let observationID = UUID()
        let recordID = UUID()

        let plan = ScoutGrowthStageLink.plan(
            observationID: observationID,
            vineyardID: vineyardID,
            paddockID: blockA,
            existingRecordID: recordID,
            existingStageCode: "EL23",
            selectedStageCode: "EL25"
        )

        #expect(
            plan == .update(
                observationID: observationID,
                growthStageRecordID: recordID,
                stageCode: "EL25"
            )
        )
    }

    @Test("Deleting a Scout retains every canonical Growth Stage record it created")
    func deletingScoutRetainsPhenology() {
        // The observation was genuinely made in the vineyard; the visit is only
        // the paperwork that carried it.
        let service = makeService()
        let visit = startVisit(service)
        service.toggleBlock(visitID: visit.id, paddockID: blockA)
        let id = assessmentID(service, visit.id, blockA)
        let recordID = UUID()
        service.linkGrowthStageRecord(
            visitID: visit.id,
            assessmentID: id,
            pinID: UUID(),
            recordID: recordID,
            stageLabel: "E-L 23"
        )

        let retained = service.deleteVisit(visit.id)

        #expect(retained == [.unlink(growthStageRecordID: recordID)])
        #expect(service.visits.isEmpty)
    }

    @Test("The Scout observation stores a link and never a competing stage value")
    func growthStageStoresLinkOnly() {
        // Two rows that can disagree would eventually tell the vineyard two
        // different budburst dates from two screens.
        let service = makeService()
        let visit = startVisit(service)
        service.toggleBlock(visitID: visit.id, paddockID: blockA)
        let id = assessmentID(service, visit.id, blockA)
        let recordID = UUID()

        service.linkGrowthStageRecord(
            visitID: visit.id, assessmentID: id, recordID: recordID, stageLabel: "E-L 23"
        )

        let saved = service.visit(visit.id)?.assessment(paddockID: blockA)?.observation(.growthStage)
        #expect(saved?.linkedGrowthStageRecordID == recordID)
        #expect(saved?.valueCode == nil)
    }

    @Test("A photo without a qualifying fix is explicitly block-only and carries no coordinates")
    func blockOnlyPhotoHasNoCoordinates() {
        let photo = ScoutPhoto.blockOnly(
            observationID: UUID(),
            localPath: "/tmp/b.jpg",
            capturedAt: Date(),
            capturedByUserID: nil
        )

        #expect(photo.locationStatus == .unavailable)
        #expect(photo.latitude == nil)
        #expect(photo.longitude == nil)
        #expect(photo.accuracyMetres == nil)
        #expect(photo.locationStatus.label == "Location unavailable — block association only")
    }

    @Test("A stale fix can never be represented as a fresh photo location")
    func staleFixCannotBecomeAPosition() {
        // The type makes the dishonest combination unconstructable: the
        // initialiser is private and no factory accepts coordinates with an
        // unavailable status, so a stale fix, last-known position, shed
        // location or block centroid cannot be smuggled in as measured.
        let confirmed = ScoutPhoto.gpsConfirmed(
            observationID: UUID(),
            localPath: nil,
            capturedAt: Date(),
            capturedByUserID: nil,
            latitude: -33.2835,
            longitude: 149.0988,
            accuracyMetres: 4.2
        )
        let blockOnly = ScoutPhoto.blockOnly(
            observationID: UUID(),
            localPath: nil,
            capturedAt: Date(),
            capturedByUserID: nil
        )

        #expect(confirmed.locationStatus == .gpsConfirmed)
        #expect(confirmed.latitude != nil)
        #expect(blockOnly.locationStatus == .unavailable)
        #expect(blockOnly.latitude == nil)
    }

    @Test("Multiple photos persist against one assessment item")
    func multiplePhotosPersist() {
        let service = makeService()
        let visit = startVisit(service)
        service.toggleBlock(visitID: visit.id, paddockID: blockA)
        let id = assessmentID(service, visit.id, blockA)

        for index in 0..<3 {
            service.capturePhoto(
                visitID: visit.id,
                assessmentID: id,
                item: .powderyMildew,
                imageData: Data([UInt8(index), 2, 3, 4]),
                locationFix: nil,
                capturedByUserID: nil
            )
        }

        let saved = service.visit(visit.id)?.assessment(paddockID: blockA)?.observation(.powderyMildew)
        #expect(saved?.photos.count == 3)
    }

    @Test("Completion does not require every dropdown to have a value")
    func completionDoesNotRequireEveryDropdown() {
        // Forcing six selections per block to record "nothing of note" teaches
        // operators to click through defaults.
        let service = makeService()
        let visit = startVisit(service)
        service.toggleBlock(visitID: visit.id, paddockID: blockA)
        let id = assessmentID(service, visit.id, blockA)
        service.setObservationNotes(
            visitID: visit.id, assessmentID: id, item: .generalRecommendation, notes: "Looks clean"
        )

        #expect(service.review(visitID: visit.id).canComplete)
        #expect(service.completeVisit(visit.id))
        #expect(service.visit(visit.id)?.status == .completed)
    }

    @Test("A selected block with no observation blocks completion")
    func emptyBlockBlocksCompletion() {
        // A block added and never opened is the one case where silence is
        // indistinguishable from an omission.
        let service = makeService()
        let visit = startVisit(service)
        service.toggleBlock(visitID: visit.id, paddockID: blockA)
        service.toggleBlock(visitID: visit.id, paddockID: blockB)
        let id = assessmentID(service, visit.id, blockA)
        service.setObservationNotes(
            visitID: visit.id, assessmentID: id, item: .otherIssue, notes: "Bird netting torn"
        )

        let review = service.review(visitID: visit.id)

        #expect(!review.canComplete)
        #expect(review.blocksIncomplete == 1)
        #expect(review.incompletePaddockIDs == [blockB])
        #expect(review.blockedReason() != nil)
        #expect(!service.completeVisit(visit.id))
    }

    @Test("A single Not assessed dropdown is not evidence the block was visited")
    func notAssessedIsNotEvidence() {
        let service = makeService()
        let visit = startVisit(service)
        service.toggleBlock(visitID: visit.id, paddockID: blockA)
        let id = assessmentID(service, visit.id, blockA)
        let notAssessed = VineyardInsightsCatalog.option(
            for: .weeds, code: VineyardInsightsCatalog.notAssessedCode
        )!

        service.setObservationValue(
            visitID: visit.id, assessmentID: id, item: .weeds, option: notAssessed
        )

        #expect(!service.review(visitID: visit.id).canComplete)
    }

    @Test("A completed visit is read-only until deliberately reopened")
    func completedIsReadOnly() {
        let service = makeService()
        let visit = startVisit(service)
        service.toggleBlock(visitID: visit.id, paddockID: blockA)
        let id = assessmentID(service, visit.id, blockA)
        service.setObservationNotes(
            visitID: visit.id, assessmentID: id, item: .otherIssue, notes: "Original"
        )
        service.completeVisit(visit.id)

        service.setObservationNotes(
            visitID: visit.id, assessmentID: id, item: .otherIssue, notes: "Edited after completion"
        )
        #expect(
            service.visit(visit.id)?.assessment(paddockID: blockA)?.observation(.otherIssue)?.notes
                == "Original"
        )

        service.reopenVisit(visit.id)
        service.setObservationNotes(
            visitID: visit.id, assessmentID: id, item: .otherIssue, notes: "Edited after reopening"
        )
        #expect(
            service.visit(visit.id)?.assessment(paddockID: blockA)?.observation(.otherIssue)?.notes
                == "Edited after reopening"
        )
    }

    @Test("An unavailable weather reading is recorded as absent and never invented")
    func weatherUnavailableIsHonest() {
        let service = makeService()
        let visit = startVisit(service)

        service.setWeather(
            visitID: visit.id,
            weather: ScoutWeatherSnapshot.unavailable(capturedAt: Date(), source: "WillyWeather")
        )

        let weather = service.visit(visit.id)?.weather
        #expect(weather?.isUnavailable == true)
        #expect(weather?.temperatureCelsius == nil)
    }

    @Test("Weather never blocks saving a visit")
    func weatherNeverBlocksSaving() {
        let service = makeService()
        let visit = startVisit(service)
        service.toggleBlock(visitID: visit.id, paddockID: blockA)
        let id = assessmentID(service, visit.id, blockA)
        service.setObservationNotes(
            visitID: visit.id, assessmentID: id, item: .otherIssue, notes: "No weather held"
        )

        #expect(service.visit(visit.id)?.weather == nil)
        #expect(service.review(visitID: visit.id).canComplete)
    }

    @Test("A visit survives a reload from storage with its observations intact")
    func visitSurvivesReload() {
        let suiteName = "vineyard-insights-reload-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = VineyardInsightsStore(defaults: defaults)
        let service = VineyardInsightsService(store: store)

        let visit = startVisit(service)
        service.toggleBlock(visitID: visit.id, paddockID: blockA)
        let id = assessmentID(service, visit.id, blockA)
        let dry = VineyardInsightsCatalog.option(for: .soilMoisture, code: "soil_very_dry")!
        service.setObservationValue(
            visitID: visit.id, assessmentID: id, item: .soilMoisture, option: dry
        )
        service.setObservationNotes(
            visitID: visit.id, assessmentID: id, item: .soilMoisture, notes: "Northern end worst"
        )

        let reloaded = VineyardInsightsStore(defaults: defaults).loadVisits().first
        let saved = reloaded?.assessment(paddockID: blockA)?.observation(.soilMoisture)

        #expect(saved?.valueCode == "soil_very_dry")
        #expect(saved?.valueLabel == "Soil very dry")
        #expect(saved?.notes == "Northern end worst")
    }

    @Test("Each queued operation carries its own vineyard for replay")
    func queueCarriesVineyard() {
        // Replay must never consult the currently selected vineyard.
        let suiteName = "vineyard-insights-queue-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = VineyardInsightsStore(defaults: defaults)
        let service = VineyardInsightsService(store: store)

        let visit = startVisit(service)

        let queued = store.loadQueue()
        #expect(queued.count == 1)
        #expect(queued.first?.vineyardID == vineyardID)
        #expect(queued.first?.recordID == visit.id)
    }

    @Test("Repeated offline edits collapse to one pending upsert")
    func queueCollapses() {
        let suiteName = "vineyard-insights-collapse-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = VineyardInsightsStore(defaults: defaults)
        let service = VineyardInsightsService(store: store)

        let visit = startVisit(service)
        service.toggleBlock(visitID: visit.id, paddockID: blockA)
        let id = assessmentID(service, visit.id, blockA)
        for index in 0..<4 {
            service.setObservationNotes(
                visitID: visit.id, assessmentID: id, item: .otherIssue, notes: "Edit \(index)"
            )
        }

        let scoutEntries = store.loadQueue().filter { $0.entity == .scoutVisit }
        #expect(scoutEntries.count == 1)
    }

    @Test("The review counts what the operator needs before completing")
    func reviewCounts() {
        let service = makeService()
        let visit = startVisit(service)
        service.toggleBlock(visitID: visit.id, paddockID: blockA)
        let id = assessmentID(service, visit.id, blockA)
        service.setObservationValue(
            visitID: visit.id,
            assessmentID: id,
            item: .downyMildew,
            option: VineyardInsightsCatalog.option(for: .downyMildew, code: "in_bunches")!
        )
        service.setObservationValue(
            visitID: visit.id,
            assessmentID: id,
            item: .weeds,
            option: VineyardInsightsCatalog.option(for: .weeds, code: "needs_attention")!
        )
        service.setObservationNotes(
            visitID: visit.id, assessmentID: id, item: .otherIssue, notes: "Fence down"
        )
        service.setObservationNotes(
            visitID: visit.id, assessmentID: id, item: .generalRecommendation, notes: "Spray next week"
        )
        service.linkGrowthStageRecord(
            visitID: visit.id,
            assessmentID: id,
            pinID: nil,
            recordID: UUID(),
            stageLabel: "E-L 23"
        )
        service.capturePhoto(
            visitID: visit.id,
            assessmentID: id,
            item: .downyMildew,
            imageData: Data([1, 2, 3, 4]),
            locationFix: nil,
            capturedByUserID: nil
        )

        let review = service.review(visitID: visit.id)

        #expect(review.blocksAssessed == 1)
        #expect(review.blocksIncomplete == 0)
        #expect(review.growthStageObservations == 1)
        #expect(review.attentionItems == 2)
        #expect(review.photoCount == 1)
        #expect(review.otherIssues == 1)
        #expect(review.generalRecommendations == 1)
    }

    // MARK: - Round 1 report workspace

    @Test("The Round 1 report controls carry the exact required disabled message")
    func reportDisabledMessage() {
        #expect(
            VintageReportWorkspaceView.disabledMessage
                == "Vintage Report generation will be enabled after the Scout and Vintage Notes "
                + "data foundation is verified."
        )
    }
}
