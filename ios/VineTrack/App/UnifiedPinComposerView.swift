import SwiftUI
import MapKit
import CoreLocation

/// Unified "Manual Pin / Repair / Observation" composer (sql/170); an
/// extension of the existing pin workflow, not a separate issue system.
///
/// Location-first flow:
///  1. Choose how to add the pin: drop a pin manually / select a row /
///     select a block.
///  2. Pick the location using the chosen method (map tap with canonical row
///     snapping, block + row/quarter selection, or block only).
///  3. Swipeable Repair | Growth | Custom tabs; tap a type, then Save Pin.
///
/// Repair and Growth saves go through the existing local-first pin create
/// path (mode Repairs/Growth); Custom saves use the simplified
/// `create_custom_pin` RPC (mode ManualIssue) referencing the
/// vineyard-shared custom type. There is no Left/Right selection and no
/// category/priority/due-date/assignee/status controls anywhere in this
/// flow. The saved pin lands on the existing Pins map/list.
struct UnifiedPinComposerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MigratedDataStore.self) private var store
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(CustomPinTypeService.self) private var customPinService
    // The app's ONE location service — reused here for the blue current
    // location dot and the opening camera. No second GPS source exists.
    @Environment(LocationService.self) private var locationService

    /// Called after a successful save so the caller can jump to the Pins tab.
    var onSaved: () -> Void = {}

    private enum Step { case method, location, type }

    @State private var step: Step = .method
    @State private var method: String = UnifiedPinContract.scopePoint
    // True once the user has explicitly picked a method — drives the
    // location-choice cards' selected state when stepping back.
    @State private var methodChosen = false

    // Location state.
    @State private var tappedCoordinate: CLLocationCoordinate2D?
    @State private var selectedPaddockId: UUID?
    @State private var selectedSegments: Set<ManualIssueSegment> = []

    // Type selection.
    @State private var selectedStandard: ButtonConfig?
    @State private var selectedCustom: CustomPinTypeRecord?
    // The Growth Stage launcher's exact E-L stage from the EXISTING picker.
    @State private var selectedGrowthStage: GrowthStage?
    @State private var showGrowthPicker = false
    @State private var showAddCustom = false
    @State private var newCustomName = ""

    @State private var validationMessage: String?
    @State private var isSaving = false

    // Full-screen pin-drop map (point method) and the row-selector filter.
    @State private var showFullMap = false
    @State private var rowFilter = ""

    // Manual-map camera. Each map is framed ONCE, from the priority below;
    // later GPS fixes never re-centre it, so the moment the operator pans,
    // zooms or drops a pin the camera is theirs.
    @State private var inlineCamera: MapCameraPosition = .automatic
    @State private var didFrameInlineCamera = false
    @State private var fullScreenCamera: MapCameraPosition = .automatic
    @State private var didFrameFullScreenCamera = false
    /// True while the draft pin is under the finger. Map interaction is
    /// suspended for the duration so the drag moves the PIN, never the map.
    @State private var isDraggingPin = false
    /// The pin's screen point at the instant the drag began, captured via
    /// `MapProxy.convert(_:to:)` in the MAP's own context (reliable), so the
    /// drag only ever needs `value.translation` — absolute gesture locations
    /// from inside an annotation's hosting view resolve the named space
    /// inconsistently and were the source of the top-left ghost pin.
    @State private var dragAnchorPoint: CGPoint?
    /// Where the single drag-overlay pin is drawn (container coordinates).
    @State private var dragPinScreenPoint: CGPoint?
    /// Live coordinate under the finger while dragging — drives the row
    /// preview label only; the placement itself commits on drag end.
    @State private var draggedPreviewCoordinate: CLLocationCoordinate2D?

    // Photo capture for the pin this composer just created. The pin is
    // created FIRST and its id held here, so ignoring, dismissing or
    // cancelling the photo question can never lose it.
    @State private var pendingPhotoPinId: UUID?
    @State private var showAutoPhotoConfirm = false
    @State private var showPhotoPicker = false
    @State private var pendingShowPicker = false
    /// Set the instant a pin is created, so no timeout, dismissal or photo
    /// callback can ever run the save a second time.
    @State private var hasCreatedPin = false
    /// Set when the composer closes, so the prompt's timeout and its
    /// dismissal handler cannot both finish the flow.
    @State private var didFinish = false

    /// Gesture coordinate spaces for the two manual maps. Named (not
    /// `.local`) so a drag started on the pin converts against the exact map
    /// that hosts it.
    private let inlineMapSpace = "unifiedPinInlineMap"
    private let fullMapSpace = "unifiedPinFullMap"

    private var selectedPaddock: Paddock? {
        store.paddocks.first { $0.id == selectedPaddockId }
    }

    private var hasSelectedType: Bool {
        selectedStandard != nil || selectedCustom != nil || selectedGrowthStage != nil
    }

    var body: some View {
        Group {
            switch step {
            case .method: methodStep
            case .location: locationStep
            case .type: typeStep
            }
        }
        .background(VineyardTheme.appBackground)
        .navigationTitle(UnifiedPinContract.quickActionTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            customPinService.store = store
            // Ask once, through the EXISTING service. A refusal is fine —
            // manual placement never depends on a fix, it just loses the dot.
            if locationService.authorizationStatus == .notDetermined {
                locationService.requestPermission()
            }
            locationService.startUpdating()
            frameCamerasIfNeeded()
            if let vineyardId = store.selectedVineyardId {
                await customPinService.refresh(vineyardId: vineyardId)
            }
        }
        // A late first fix may still frame the map, but only while the
        // operator has not taken control — `didFrame…` latches on tap, drag,
        // pan and zoom.
        .onChange(of: locationService.location?.timestamp) { _, _ in
            frameCamerasIfNeeded()
        }
        .sheet(isPresented: $showPhotoPicker, onDismiss: { finishSave() }) {
            // Cancelling the camera keeps the pin exactly as saved.
            CameraImagePicker { data in
                attachPhoto(data: data)
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showAutoPhotoConfirm, onDismiss: {
            if pendingShowPicker {
                pendingShowPicker = false
                showPhotoPicker = true
            } else {
                // Skip, swipe-dismiss and the 3s timeout are the same
                // answer: the pin is already saved, finish without a photo.
                pendingPhotoPinId = nil
                finishSave()
            }
        }) {
            // The EXISTING 3-second prompt — same countdown, same wording.
            AutoPhotoConfirmSheet(
                onConfirm: {
                    pendingShowPicker = true
                    showAutoPhotoConfirm = false
                },
                onCancel: {
                    pendingShowPicker = false
                    showAutoPhotoConfirm = false
                }
            )
        }
        .sheet(isPresented: $showGrowthPicker) {
            // The EXISTING E-L growth-stage picker — same images, labels,
            // order and identifiers as the standard Growth pin workflow.
            // Cancelling changes nothing; no pin exists until Save Pin.
            GrowthStagePickerSheet { stage in
                selectedGrowthStage = stage
                selectedStandard = nil
                selectedCustom = nil
                validationMessage = nil
            }
        }
        .alert("Add custom item", isPresented: $showAddCustom) {
            TextField("Custom item name", text: $newCustomName)
            Button("Add") { addCustomItem() }
            Button("Cancel", role: .cancel) { newCustomName = "" }
        } message: {
            Text("Shared with everyone in this vineyard.")
        }
    }

    // MARK: - Step 1: location method

    private var methodStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("How do you want to add the pin?")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                methodCard(
                    title: UnifiedPinContract.methodTitles[0],
                    subtitle: UnifiedPinContract.methodSubtitles[0],
                    icon: "mappin.and.ellipse",
                    color: VineyardTheme.primary,
                    scope: UnifiedPinContract.scopePoint
                )
                methodCard(
                    title: UnifiedPinContract.methodTitles[1],
                    subtitle: UnifiedPinContract.methodSubtitles[1],
                    icon: "rectangle.split.3x1",
                    color: VineyardTheme.leafGreen,
                    scope: UnifiedPinContract.scopeRow
                )
                methodCard(
                    title: UnifiedPinContract.methodTitles[2],
                    subtitle: UnifiedPinContract.methodSubtitles[2],
                    icon: "square.dashed",
                    color: VineyardTheme.earthBrown,
                    scope: UnifiedPinContract.scopeBlock
                )
            }
            .padding(.horizontal)
        }
    }

    /// One enlarged location-choice control — full-width, min height
    /// `UnifiedPinContract.methodButtonMinHeight` (≈ double the original card),
    /// with a clear blue selected state. Identical sizing on Android.
    private func methodCard(title: String, subtitle: String, icon: String, color: Color, scope: String) -> some View {
        let isSelected = methodChosen && method == scope
        return Button {
            if methodChosen && method != scope {
                // Changing the method clears location state so no stale
                // snapping/segments survive.
                tappedCoordinate = nil
                selectedPaddockId = nil
                selectedSegments = []
            }
            method = scope
            methodChosen = true
            validationMessage = nil
            step = .location
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(color, in: .rect(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(VineyardTheme.actionBlue)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, minHeight: UnifiedPinContract.methodButtonMinHeight, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isSelected ? VineyardTheme.actionBlue : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step 2: location

    private var locationStep: some View {
        VStack(spacing: 0) {
            switch method {
            case UnifiedPinContract.scopeRow:
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        rowGrid
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }
            case UnifiedPinContract.scopeBlock:
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Tap a block \u{2014} the whole block will be flagged.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        blockPicker
                    }
                    .padding(.horizontal)
                    .padding(.top, 16)
                }
            default:
                // The map lives OUTSIDE any scroll view so it owns every
                // pinch and drag — smooth continuous zoom/pan.
                pointPicker
                    .padding(.horizontal)
                    .padding(.top, 8)
            }

            VStack(spacing: 8) {
                if let validationMessage {
                    Text(validationMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Button {
                    continueFromLocation()
                } label: {
                    Text("Continue")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(VineyardTheme.primary, in: .rect(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Back") { step = .method }
            }
        }
        .fullScreenCover(isPresented: $showFullMap) {
            fullScreenMapView
        }
    }

    private func continueFromLocation() {
        let error: String? = {
            switch method {
            case UnifiedPinContract.scopePoint:
                return tappedCoordinate == nil ? UnifiedPinContract.errorTapMap : nil
            case UnifiedPinContract.scopeRow:
                if ManualIssueContract.canonicalSegments(Array(selectedSegments)).isEmpty {
                    return UnifiedPinContract.errorSelectRow
                }
                if selectedPaddockId == nil { return UnifiedPinContract.errorRowBlock }
                return nil
            default:
                return selectedPaddockId == nil ? UnifiedPinContract.errorSelectBlock : nil
            }
        }()
        if let error {
            validationMessage = error
        } else {
            validationMessage = nil
            step = .type
        }
    }

    private var pointPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            MapReader { proxy in
                Map(position: $inlineCamera, interactionModes: isDraggingPin ? [] : .all) {
                    // The blue current-location dot, from the app's existing
                    // location service. Visually distinct from the draft pin,
                    // and simply absent when permission is denied.
                    currentLocationContent
                    if let tappedCoordinate {
                        Annotation("", coordinate: tappedCoordinate) {
                            draftPinMarker(proxy: proxy, space: inlineMapSpace)
                        }
                    }
                }
                .mapStyle(.hybrid)
                .onTapGesture { position in
                    if let coordinate = proxy.convert(position, from: .local) {
                        placeDraftPin(at: coordinate)
                    }
                }
                .onMapCameraChange { _ in
                    // Any pan or zoom hands the camera to the operator.
                    didFrameInlineCamera = true
                }
            }
            .coordinateSpace(.named(inlineMapSpace))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(.rect(cornerRadius: 10))
            .overlay { dragOverlayPin }
            .overlay(alignment: .topTrailing) {
                mapExpandButton
            }
            placementPreviewLabel(onDark: false)
        }
    }

    /// The draft pin's shared visual — used by the map annotation at rest
    /// and by the drag overlay while the finger is down.
    private func pinImage(dragging: Bool) -> some View {
        Image(systemName: "mappin.circle.fill")
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(.white, VineyardTheme.primary)
            .shadow(color: .black.opacity(0.35), radius: dragging ? 7 : 2, y: 1)
            .scaleEffect(dragging ? 1.22 : 1.0)
    }

    /// The blue current-location dot, driven by the app's ONE LocationService
    /// fix. `UserAnnotation()` depends on the Map's own internal tracking,
    /// which does not reliably render in this composer; this draws the same
    /// visual from the fix the rest of the app already trusts.
    @MapContentBuilder
    private var currentLocationContent: some MapContent {
        if let device = locationService.location?.coordinate, CLLocationCoordinate2DIsValid(device) {
            Annotation("", coordinate: device) {
                ZStack {
                    Circle().fill(Color.blue.opacity(0.22)).frame(width: 36, height: 36)
                    Circle().fill(.white).frame(width: 19, height: 19)
                    Circle().fill(.blue).frame(width: 13, height: 13)
                }
                // Never intercept a placement tap under the dot.
                .allowsHitTesting(false)
            }
            .annotationTitles(.hidden)
        }
    }

    /// The ONE visible pin while dragging — drawn in the map container's own
    /// coordinate space at the anchored finger offset. The map annotation
    /// underneath stays at its pre-drag coordinate (hidden), so it is never
    /// recreated mid-drag and no second pin can appear.
    @ViewBuilder
    private var dragOverlayPin: some View {
        if isDraggingPin, let point = dragPinScreenPoint {
            pinImage(dragging: true)
                .position(point)
                .allowsHitTesting(false)
        }
    }

    /// The draft pin itself — tap-placed, then DRAGGABLE.
    ///
    /// The drag is translation-based: the pin's screen point is anchored ONCE
    /// at drag start (converted in the map's own context, where the named
    /// space always resolves) and every update applies `value.translation`
    /// to that anchor. Absolute `value.location` is never used — from inside
    /// an annotation's hosting view it intermittently failed to resolve the
    /// named space, collapsing to points near (0,0): that was both the ghost
    /// pin at the top-left and the “outside mapped blocks” label flicker.
    /// The preview label re-resolves live from the dragged coordinate; the
    /// placement commits on drag end.
    private func draftPinMarker(proxy: MapProxy, space: String) -> some View {
        pinImage(dragging: isDraggingPin)
            // While dragging, the overlay pin is the visible one.
            .opacity(isDraggingPin ? 0 : 1)
            .animation(.snappy(duration: 0.15), value: isDraggingPin)
            .contentShape(.circle)
            .gesture(
                // minimumDistance 0 claims the touch the instant it lands on
                // the pin, which is what stops the map panning underneath it.
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragAnchorPoint == nil, let tappedCoordinate {
                            dragAnchorPoint = proxy.convert(tappedCoordinate, to: .named(space))
                        }
                        guard let anchor = dragAnchorPoint else { return }
                        isDraggingPin = true
                        let point = CGPoint(
                            x: anchor.x + value.translation.width,
                            y: anchor.y + value.translation.height
                        )
                        dragPinScreenPoint = point
                        if let moved = proxy.convert(point, from: .named(space)) {
                            draggedPreviewCoordinate = moved
                        }
                    }
                    .onEnded { value in
                        if let anchor = dragAnchorPoint {
                            let point = CGPoint(
                                x: anchor.x + value.translation.width,
                                y: anchor.y + value.translation.height
                            )
                            if let moved = proxy.convert(point, from: .named(space)) {
                                placeDraftPin(at: moved)
                            }
                        }
                        dragAnchorPoint = nil
                        dragPinScreenPoint = nil
                        draggedPreviewCoordinate = nil
                        isDraggingPin = false
                    }
            )
            .accessibilityLabel("Dropped pin — drag to move it")
    }

    /// The single entry point for every placement gesture on either map, so
    /// the inline and full-screen maps always share one coordinate.
    private func placeDraftPin(at coordinate: CLLocationCoordinate2D) {
        tappedCoordinate = coordinate
        validationMessage = nil
        // A placed pin is the operator's frame of reference from here on.
        didFrameInlineCamera = true
        didFrameFullScreenCamera = true
    }

    /// Expand control floated over the inline map's corner.
    private var mapExpandButton: some View {
        Button {
            // The full-screen map opens on the SHARED coordinate state, so it
            // always picks up wherever the pin currently is.
            frameFullScreenCameraOnOpen()
            showFullMap = true
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.black.opacity(0.55), in: .rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .padding(10)
        .accessibilityLabel("Full-screen map")
    }

    /// Canonical snapping preview — the same resolution the save uses, so
    /// the label always matches what gets stored.
    @ViewBuilder
    private func placementPreviewLabel(onDark: Bool) -> some View {
        let tint: Color = onDark ? .white.opacity(0.92) : Color.secondary
        // While dragging, resolve from the live dragged coordinate ONLY — one
        // source, one resolver, so the label can't flicker between answers.
        if let coordinate = draggedPreviewCoordinate ?? tappedCoordinate {
            let attachment = resolvedAttachment(for: coordinate)
            let block = RowGuidance.paddock(for: coordinate, in: store.paddocks)
            if let block, attachment.snappedToRow, let row = attachment.pinRowNumber {
                Label("\(block.name) · on row \(row)", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.footnote)
                    .foregroundStyle(tint)
            } else if let block {
                Label("\(block.name) · not attached to a row", systemImage: "mappin")
                    .font(.footnote)
                    .foregroundStyle(tint)
            } else {
                Label("Pin placed outside mapped blocks", systemImage: "mappin")
                    .font(.footnote)
                    .foregroundStyle(tint)
            }
        } else {
            Label("Tap the map to place the pin", systemImage: "hand.tap")
                .font(.footnote)
                .foregroundStyle(tint)
        }
    }

    /// Edge-to-edge pin-drop map: over-zoom past the normal framing (the
    /// imagery softens rather than disappearing), tap to move the pin, and
    /// the placement label + Continue float on top so the flow never leaves
    /// the map.
    private var fullScreenMapView: some View {
        ZStack {
            MapReader { proxy in
                // Over-zoom: a tiny minimum camera distance lets the user zoom
                // well past the normal framing — the imagery upsamples (softens)
                // rather than disappearing.
                Map(
                    position: $fullScreenCamera,
                    bounds: MapCameraBounds(minimumDistance: 10),
                    interactionModes: isDraggingPin ? [] : .all
                ) {
                    currentLocationContent
                    if let tappedCoordinate {
                        Annotation("", coordinate: tappedCoordinate) {
                            draftPinMarker(proxy: proxy, space: fullMapSpace)
                        }
                    }
                }
                .mapStyle(.hybrid)
                .mapControls {
                    MapUserLocationButton()
                }
                .onTapGesture { position in
                    if let coordinate = proxy.convert(position, from: .local) {
                        placeDraftPin(at: coordinate)
                    }
                }
                .onMapCameraChange { _ in
                    didFrameFullScreenCamera = true
                }
                .ignoresSafeArea()
            }
            .coordinateSpace(.named(fullMapSpace))
            .overlay { dragOverlayPin }

            VStack {
                HStack {
                    Spacer()
                    Button {
                        showFullMap = false
                    } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.black.opacity(0.55), in: .rect(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Exit full-screen map")
                }

                Spacer()

                VStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        placementPreviewLabel(onDark: true)
                        if let validationMessage {
                            Text(validationMessage)
                                .font(.footnote)
                                .foregroundStyle(Color(red: 1.0, green: 0.54, blue: 0.5))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.55), in: .rect(cornerRadius: 12))

                    Button {
                        continueFromLocation()
                        if step == .type { showFullMap = false }
                    } label: {
                        Text("Continue")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(VineyardTheme.primary, in: .rect(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    /// Where a manual map should OPEN, in the agreed priority order:
    ///
    /// 1. the pin already dropped in this composer,
    /// 2. the operator's current device location,
    /// 3. the mapped vineyard / selected block,
    /// 4. the existing wide fallback.
    ///
    /// Returns nil while none of 1–3 is known yet, which is what lets a late
    /// first GPS fix still frame the map instead of stranding it on the
    /// fallback.
    private func openingRegion(span: CLLocationDegrees) -> MKCoordinateRegion? {
        if let tappedCoordinate {
            return MKCoordinateRegion(
                center: tappedCoordinate,
                span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)
            )
        }
        if let device = locationService.location?.coordinate, CLLocationCoordinate2DIsValid(device) {
            return MKCoordinateRegion(
                center: device,
                span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)
            )
        }
        if let paddock = selectedPaddock ?? store.paddocks.first(where: { !$0.polygonPoints.isEmpty }) {
            return MKCoordinateRegion(
                center: paddock.polygonPoints.centroid,
                span: MKCoordinateSpan(latitudeDelta: span * 2, longitudeDelta: span * 2)
            )
        }
        return nil
    }

    /// The existing wide fallback, used only when nothing better is known.
    private var fallbackRegion: MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: -34.9, longitude: 138.6),
            span: MKCoordinateSpan(latitudeDelta: 40, longitudeDelta: 40)
        )
    }

    /// Frame each map at most ONCE. After that the camera belongs to the
    /// operator: a pan, a zoom, a tap or a pin drag latches the flag, and a
    /// moving GPS fix never pulls the view back.
    private func frameCamerasIfNeeded() {
        if !didFrameInlineCamera, let region = openingRegion(span: 0.004) {
            didFrameInlineCamera = true
            inlineCamera = .region(region)
        }
        if !didFrameFullScreenCamera, let region = openingRegion(span: 0.0015) {
            didFrameFullScreenCamera = true
            fullScreenCamera = .region(region)
        }
    }

    /// Framing for the full-screen map at the moment it is opened. It starts
    /// from the shared coordinate state, so it always opens on whatever the
    /// inline map is showing.
    private func frameFullScreenCameraOnOpen() {
        didFrameFullScreenCamera = false
        fullScreenCamera = .region(openingRegion(span: 0.0015) ?? fallbackRegion)
        didFrameFullScreenCamera = true
    }

    /// Full-width tappable block cards — generous touch area with a clear
    /// checkmark on the selected block (replaces the old compact menu).
    @ViewBuilder
    private var blockPicker: some View {
        let paddocks = store.paddocks.sorted { $0.name.lowercased() < $1.name.lowercased() }
        if paddocks.isEmpty {
            Text("No blocks mapped in this vineyard yet.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            ForEach(paddocks) { paddock in
                let isSelected = paddock.id == selectedPaddockId
                Button {
                    selectedPaddockId = paddock.id
                    selectedSegments = []
                    validationMessage = nil
                } label: {
                    HStack {
                        Text(paddock.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                        Spacer()
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(VineyardTheme.leafGreen)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isSelected ? VineyardTheme.leafGreen : Color.clear, lineWidth: 2)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// One block with its mapped rows in the row-first selector.
    private struct RowBlockEntry: Identifiable {
        let paddock: Paddock
        let rows: [PaddockRow]
        var id: UUID { paddock.id }
    }

    /// Blocks that have mapped row geometry, sorted by name — the row-first
    /// selector lists every one of them under its block header so "Row 41"
    /// is never ambiguous across blocks.
    private var rowBlocks: [RowBlockEntry] {
        var entries: [RowBlockEntry] = []
        for paddock in store.paddocks {
            let rows = paddock.rows.sorted { $0.number < $1.number }
            if !rows.isEmpty {
                entries.append(RowBlockEntry(paddock: paddock, rows: rows))
            }
        }
        entries.sort { $0.paddock.name.lowercased() < $1.paddock.name.lowercased() }
        return entries
    }

    /// Row-first tap: the block is DERIVED from the tapped row's geometry;
    /// switching blocks starts a fresh selection.
    private func handleRowTap(blockId: UUID, tapped: Set<ManualIssueSegment>) {
        let result = UnifiedPinContract.applyRowTap(
            currentBlockId: selectedPaddockId,
            tappedBlockId: blockId,
            currentSegments: selectedSegments,
            tappedSegments: tapped
        )
        selectedPaddockId = result.blockId
        selectedSegments = result.segments
        validationMessage = nil
    }

    @ViewBuilder
    private var rowGrid: some View {
        let blocks = rowBlocks
        if blocks.isEmpty {
            Label("No mapped rows in this vineyard — use Select a block instead.", systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            // Compact one-line filter — narrows what is VISIBLE only; the
            // selection is untouched while filtering.
            rowFilterField
            if !selectedSegments.isEmpty, let selectedPaddock {
                Text(ManualIssueContract.rowSelectionSummary(Array(selectedSegments)))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(VineyardTheme.leafGreen)
                Text("Block: \(selectedPaddock.name) — detected from the selected row")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            let filtered = filteredRowBlocks(blocks)
            if filtered.isEmpty {
                Text("No blocks or rows match \u{201c}\(rowFilter.trimmingCharacters(in: .whitespaces))\u{201d}.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(filtered) { entry in
                blockRowSection(entry)
            }
        }
    }

    /// Compact one-line filter above the row selector (block name or row number).
    private var rowFilterField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.footnote)
                .foregroundStyle(.secondary)
            TextField("Filter by block or row number", text: $rowFilter)
                .font(.subheadline)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !rowFilter.isEmpty {
                Button {
                    rowFilter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
    }

    /// Row-filter matching: a block-name substring match keeps the whole
    /// block; otherwise only rows whose number starts with the query stay
    /// visible. Mirrors the Android composer exactly.
    private func filteredRowBlocks(_ blocks: [RowBlockEntry]) -> [RowBlockEntry] {
        let query = rowFilter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return blocks }
        var result: [RowBlockEntry] = []
        for entry in blocks {
            if entry.paddock.name.localizedCaseInsensitiveContains(query) {
                result.append(entry)
            } else {
                let rows = entry.rows.filter { String($0.number).hasPrefix(query) }
                if !rows.isEmpty {
                    result.append(RowBlockEntry(paddock: entry.paddock, rows: rows))
                }
            }
        }
        return result
    }

    @ViewBuilder
    private func blockRowSection(_ entry: RowBlockEntry) -> some View {
        let inBlock = entry.paddock.id == selectedPaddockId
        Text(entry.paddock.name)
            .font(.footnote.weight(.bold))
            .foregroundStyle(inBlock && !selectedSegments.isEmpty ? VineyardTheme.leafGreen : Color.primary)
            .padding(.top, 6)
        ForEach(entry.rows) { row in
            rowLine(row, blockId: entry.paddock.id, inBlock: inBlock)
        }
    }

    private func rowLine(_ row: PaddockRow, blockId: UUID, inBlock: Bool) -> some View {
        HStack(spacing: 6) {
            let all = Set((1...4).map { ManualIssueSegment(row: row.number, segment: $0) })
            let wholeSelected = inBlock && all.isSubset(of: selectedSegments)
            Button {
                handleRowTap(blockId: blockId, tapped: all)
            } label: {
                Text("\(row.number)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(wholeSelected ? Color.white : Color.primary)
                    .frame(width: 34, height: 26)
                    .background(
                        wholeSelected ? VineyardTheme.leafGreen : Color(.tertiarySystemBackground),
                        in: .rect(cornerRadius: 6)
                    )
            }
            .buttonStyle(.plain)
            ForEach(1...4, id: \.self) { quarter in
                let segment = ManualIssueSegment(row: row.number, segment: quarter)
                let isSelected = inBlock && selectedSegments.contains(segment)
                Button {
                    handleRowTap(blockId: blockId, tapped: [segment])
                } label: {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isSelected ? VineyardTheme.leafGreen : Color(.tertiarySystemBackground))
                        .frame(height: 26)
                        .overlay {
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Step 3: Repair | Growth | Custom

    @State private var tabSelection: Int = 0

    private var typeStep: some View {
        VStack(spacing: 0) {
            // Tappable + swipeable tabs, same ordering and wording as Android.
            HStack(spacing: 8) {
                ForEach(Array(UnifiedPinContract.tabs.enumerated()), id: \.offset) { index, title in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { tabSelection = index }
                    } label: {
                        Text(title)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(tabSelection == index ? Color.white : Color.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(
                                tabSelection == index ? VineyardTheme.primary : Color.clear,
                                in: .rect(cornerRadius: 9)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
            .padding(.horizontal)
            .padding(.top, 8)

            TabView(selection: $tabSelection) {
                standardButtonsPage(mode: .repairs).tag(0)
                standardButtonsPage(mode: .growth).tag(1)
                customTypesPage.tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.easeInOut(duration: 0.25), value: tabSelection)

            if let validationMessage {
                Text(validationMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }
            Button {
                Task { await save() }
            } label: {
                Group {
                    if isSaving {
                        ProgressView().tint(.white)
                    } else {
                        Text("Save Pin").font(.headline)
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(
                    hasSelectedType ? VineyardTheme.primary : Color.gray.opacity(0.5),
                    in: .rect(cornerRadius: 12)
                )
            }
            .buttonStyle(.plain)
            .disabled(isSaving || !hasSelectedType)
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Back") { step = .location }
            }
        }
    }

    /// The EXISTING vineyard button catalogue — same stored identifiers,
    /// labels and colours as the Repairs/Growth launcher. Growth Stage never
    /// appears here (dedupe by flag AND by name) — it has its own dedicated
    /// tile that opens the existing stage picker. Left/right launcher
    /// duplicates collapse to one tile each.
    private func composerButtons(mode: PinMode) -> [ButtonConfig] {
        let source = mode == .growth ? store.growthButtons : store.repairButtons
        var seen = Set<String>()
        return source
            .filter {
                !$0.isGrowthStageButton &&
                    $0.name.trimmingCharacters(in: .whitespaces)
                        .caseInsensitiveCompare(UnifiedPinContract.growthStageButton) != .orderedSame
            }
            .sorted { $0.index < $1.index }
            .filter { seen.insert(UnifiedPinContract.catalogueKey(name: $0.name, color: $0.color)).inserted }
    }

    /// The Growth tab's Growth Stage launcher — rendered exactly once, first,
    /// at the same tile size as the other Growth buttons. Opens the EXISTING
    /// E-L stage picker; the chosen stage saves as a normal Growth pin.
    private var growthStageTile: some View {
        Button {
            showGrowthPicker = true
        } label: {
            VStack(spacing: 6) {
                if selectedGrowthStage != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                } else {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.title3.weight(.semibold))
                }
                Text(UnifiedPinContract.growthStageButton)
                    .font(.headline.weight(.heavy))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
                Text(selectedGrowthStage.map { "EL \($0.code)" } ?? "Pick the E-L stage")
                    .font(.caption2)
                    .opacity(0.9)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: UnifiedPinContract.typeButtonMinHeight)
            .background(
                LinearGradient(
                    colors: [
                        Color.fromString(UnifiedPinContract.growthStagePinColor),
                        Color.fromString(UnifiedPinContract.growthStagePinColor).opacity(0.82)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                in: .rect(cornerRadius: 14)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(selectedGrowthStage != nil ? Color.white : Color.black.opacity(0.10), lineWidth: selectedGrowthStage != nil ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func standardButtonsPage(mode: PinMode) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                if mode == .growth {
                    growthStageTile
                }
                ForEach(composerButtons(mode: mode)) { button in
                    let isSelected = selectedStandard?.id == button.id
                    Button {
                        selectedStandard = button
                        selectedCustom = nil
                        selectedGrowthStage = nil
                        validationMessage = nil
                    } label: {
                        VStack(spacing: 6) {
                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.title3)
                            } else {
                                Image(systemName: "mappin.and.ellipse")
                                    .font(.title3.weight(.semibold))
                            }
                            Text(button.name)
                                .font(.headline.weight(.heavy))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .minimumScaleFactor(0.7)
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: UnifiedPinContract.typeButtonMinHeight)
                        .background(
                            LinearGradient(
                                colors: [Color.fromString(button.color), Color.fromString(button.color).opacity(0.82)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            in: .rect(cornerRadius: 14)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(isSelected ? Color.white : Color.black.opacity(0.10), lineWidth: isSelected ? 2 : 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.top, 12)
        }
    }

    private var customTypesPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                let types = customPinService.activeTypes(vineyardId: store.selectedVineyardId)
                if types.isEmpty {
                    Text("No custom items yet — add one for actions the Repair and Growth buttons don't cover (e.g. Broken Wire, Large Divot, Check Irrigation).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(types) { type in
                    let isSelected = selectedCustom?.id == type.id
                    Button {
                        selectedCustom = type
                        selectedStandard = nil
                        selectedGrowthStage = nil
                        validationMessage = nil
                    } label: {
                        HStack {
                            Text(type.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(isSelected ? Color.white : Color.primary)
                            Spacer()
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 13)
                        .background(
                            isSelected ? Color.orange : Color(.secondarySystemBackground),
                            in: .rect(cornerRadius: 12)
                        )
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    newCustomName = ""
                    showAddCustom = true
                } label: {
                    Label("Add custom item", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(VineyardTheme.primary)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.top, 12)
        }
    }

    private func addCustomItem() {
        let name = newCustomName
        newCustomName = ""
        guard let vineyardId = store.selectedVineyardId else { return }
        Task {
            if let type = await customPinService.addType(name: name, vineyardId: vineyardId) {
                selectedCustom = type
                selectedStandard = nil
                selectedGrowthStage = nil
                validationMessage = nil
            } else if let message = customPinService.errorMessage {
                validationMessage = message
                customPinService.errorMessage = nil
            }
        }
    }

    // MARK: - Save

    /// Canonical side-less attachment for a manually dropped point: block by
    /// containment + nearest-row snapping. Resolved once; the same result
    /// feeds the preview label and the saved pin.
    private func resolvedAttachment(for coordinate: CLLocationCoordinate2D) -> PinAttachmentResolver.Attachment {
        let paddock = RowGuidance.paddock(for: coordinate, in: store.paddocks)
        let base = PinAttachmentResolver.resolveManual(
            coordinate: coordinate,
            operatorSide: .right, // resolver requires a side; stripped below
            paddock: paddock
        )
        // The unified composer records no Left/Right — strip the side while
        // keeping the row/snap geometry intact.
        return PinAttachmentResolver.Attachment(
            drivingRowNumber: base.drivingRowNumber,
            pinRowNumber: base.pinRowNumber,
            pinSide: nil,
            snappedCoordinate: base.snappedCoordinate,
            alongRowDistanceM: base.alongRowDistanceM,
            snappedToRow: base.snappedToRow
        )
    }

    /// Marker coordinate for the current method: original tap for point,
    /// mean of segment midpoints for rows (block centroid fallback), block
    /// centroid for block. The structured selection stays authoritative.
    private func markerCoordinate() -> (latitude: Double, longitude: Double)? {
        switch method {
        case UnifiedPinContract.scopePoint:
            guard let tappedCoordinate else { return nil }
            return (tappedCoordinate.latitude, tappedCoordinate.longitude)
        case UnifiedPinContract.scopeRow:
            guard let paddock = selectedPaddock else { return nil }
            var rowLines: [Int: (start: (latitude: Double, longitude: Double), end: (latitude: Double, longitude: Double))] = [:]
            for row in paddock.rows {
                rowLines[row.number] = (
                    start: (row.startPoint.latitude, row.startPoint.longitude),
                    end: (row.endPoint.latitude, row.endPoint.longitude)
                )
            }
            if let marker = ManualIssueContract.markerCoordinate(segments: Array(selectedSegments), rowLines: rowLines) {
                return marker
            }
            return ManualIssueContract.blockCentroid(points: paddock.polygonPoints.map { ($0.latitude, $0.longitude) })
        default:
            guard let paddock = selectedPaddock else { return nil }
            return ManualIssueContract.blockCentroid(points: paddock.polygonPoints.map { ($0.latitude, $0.longitude) })
        }
    }

    private func save() async {
        // The pin is created exactly once. Every later path — the photo
        // prompt's Skip, its 3s timeout, a swipe-dismiss, a cancelled camera
        // — runs AFTER this point and can never re-enter it.
        guard !hasCreatedPin else { return }
        let marker = markerCoordinate()
        let canonical = ManualIssueContract.canonicalSegments(Array(selectedSegments))
        if let error = UnifiedPinContract.validationError(
            scope: method,
            hasSelectedType: hasSelectedType,
            latitude: marker?.latitude,
            longitude: marker?.longitude,
            paddockId: selectedPaddockId,
            segments: canonical
        ) {
            validationMessage = error
            return
        }
        guard let marker else {
            validationMessage = "A map location is required."
            return
        }
        isSaving = true
        defer { isSaving = false }
        customPinService.store = store

        let coordinate = CLLocationCoordinate2D(latitude: marker.latitude, longitude: marker.longitude)
        // Resolved AGAIN here, from the final coordinate, through the same
        // canonical resolver the live preview label uses. A pin dragged from
        // row 69 to row 70 after the label was drawn therefore cannot be
        // stored against the row it merely used to be near.
        let attachment: PinAttachmentResolver.Attachment? =
            method == UnifiedPinContract.scopePoint ? resolvedAttachment(for: coordinate) : nil
        let containmentBlock: UUID? = method == UnifiedPinContract.scopePoint
            ? RowGuidance.paddock(for: coordinate, in: store.paddocks)?.id
            : selectedPaddockId
        let rowSegments = method == UnifiedPinContract.scopeRow ? canonical : nil

        if let stage = selectedGrowthStage {
            // Growth Stage: a normal Growth pin through the EXISTING
            // growth-stage create path, carrying the exact E-L identifier.
            guard let pin = store.createGrowthStagePin(
                stageCode: stage.code,
                stageDescription: stage.description,
                coordinate: coordinate,
                heading: nil,
                side: nil, // no Left/Right in the unified composer
                paddockId: containmentBlock,
                rowNumber: nil,
                createdBy: auth.userName,
                createdByUserId: auth.userId,
                attachment: attachment,
                locationScope: method,
                rowSegments: rowSegments
            ) else {
                validationMessage = "Could not create pin — no vineyard selected."
                return
            }
            if let rowSegments {
                await customPinService.queueRowSegments(pinId: pin.id, segments: rowSegments)
            }
            promptForPhoto(pinId: pin.id)
        } else if let button = selectedStandard {
            // Repair / Growth: the EXISTING pin create path stays
            // authoritative — never routed through a Manual Issue RPC.
            guard let pin = store.createPinFromButton(
                button: button,
                coordinate: coordinate,
                heading: nil,
                side: nil, // no Left/Right in the unified composer
                paddockId: containmentBlock,
                rowNumber: nil,
                createdBy: auth.userName,
                createdByUserId: auth.userId,
                attachment: attachment,
                locationScope: method,
                rowSegments: rowSegments
            ) else {
                validationMessage = "Could not create pin — no vineyard selected."
                return
            }
            if let rowSegments {
                // Structured ROW selection persists via set_pin_row_segments;
                // queued + retried until the pin insert reaches the server.
                await customPinService.queueRowSegments(pinId: pin.id, segments: rowSegments)
            }
            promptForPhoto(pinId: pin.id)
        } else if let type = selectedCustom {
            guard let vineyardId = store.selectedVineyardId else {
                validationMessage = "Could not create pin — no vineyard selected."
                return
            }
            let params = CustomPinCreateParams(
                id: UUID(),
                vineyardId: vineyardId,
                title: type.name,
                locationScope: method,
                customTypeId: type.id,
                paddockId: containmentBlock,
                notes: nil,
                latitude: marker.latitude,
                longitude: marker.longitude,
                snappedLatitude: attachment?.snappedCoordinate?.latitude,
                snappedLongitude: attachment?.snappedCoordinate?.longitude,
                drivingRowNumber: nil,
                pinRowNumber: attachment?.pinRowNumber.map(Double.init),
                alongRowDistanceM: attachment?.alongRowDistanceM,
                snappedToRow: attachment?.snappedToRow ?? false,
                clientUpdatedAt: ManualIssueTimestamp.now(),
                segments: rowSegments
            )
            let saved = await customPinService.createCustomPin(params)
            if saved {
                promptForPhoto(pinId: params.id)
            } else if let message = customPinService.errorMessage {
                validationMessage = message
                customPinService.errorMessage = nil
            }
        }
    }

    // MARK: - Photo

    /// Ask the photo question for the pin that was JUST created.
    ///
    /// This runs for every save out of this composer — Repair, Growth,
    /// Growth Stage and Custom, on the map, row and block methods alike —
    /// and deliberately does NOT consult `settings.autoPhotoPrompt`. That
    /// preference still governs the ordinary quick Repair/Growth taps
    /// elsewhere; it is untouched here.
    private func promptForPhoto(pinId: UUID) {
        hasCreatedPin = true
        pendingPhotoPinId = pinId
        pendingShowPicker = false
        showAutoPhotoConfirm = true
    }

    /// Attach the captured photo to the exact pin this composer created.
    /// A cancelled camera returns nil and the pin simply keeps no photo.
    private func attachPhoto(data: Data?) {
        defer { pendingPhotoPinId = nil }
        guard let data, let pinId = pendingPhotoPinId else { return }
        guard var pin = store.pins.first(where: { $0.id == pinId }) else { return }
        pin.photoData = data
        store.updatePin(pin)
    }

    /// Leave the composer once the photo question is fully resolved. Guarded
    /// so the timeout, a dismissal and a photo callback cannot each dismiss.
    private func finishSave() {
        guard !didFinish else { return }
        didFinish = true
        dismiss()
        onSaved()
    }
}
