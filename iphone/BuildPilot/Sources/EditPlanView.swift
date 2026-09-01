import SwiftUI

/// Manual Measurement Editing. Reopens the plan in an editable state — walls,
/// ceiling, openings, surfaces, coats, preparation and notes — as simple
/// sections. Save sends only what changed to the deterministic re-estimate;
/// Cancel discards. It computes which outputs go stale (the PDF for any
/// quote-relevant change; the visualization only for surface/scope/prep
/// changes — never for notes alone).
struct EditPlanView: View {
    let session: SessionResponse
    /// (payload, pdfStale, visualizationStale). Empty payload → no changes.
    let onSave: (PlanEditPayload?, _ pdfStale: Bool, _ visualizationStale: Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    struct EditableWall: Identifiable {
        let id: String
        var width: Double
        var height: Double
        var opening: Double
    }

    @State private var walls: [EditableWall]
    @State private var ceilingArea: Double
    @State private var doorArea: Double
    @State private var windowArea: Double
    @State private var coats: Int
    @State private var paintWalls: Bool
    @State private var paintCeiling: Bool
    @State private var included: Set<String>   // wall ids included in painting
    @State private var prepText: String        // one prep item per line
    @State private var notesText: String       // one note per line
    @State private var verified: Bool

    private let originalWalls: [EditableWall]
    private let originalCeiling: Double
    private let originalDoor: Double
    private let originalWindow: Double
    private let originalCoats: Int
    private let originalWallsScope: Bool
    private let originalCeilingScope: Bool
    private let originalIncluded: Set<String>
    private let originalPrep: [String]
    private let originalNotes: [String]
    private let originalVerified: Bool
    private let allWallIds: Set<String>

    init(session: SessionResponse,
         onSave: @escaping (PlanEditPayload?, Bool, Bool) -> Void) {
        self.session = session
        self.onSave = onSave
        let m = session.measurements
        let r = session.requirements
        let ws = (m?.walls ?? []).map {
            EditableWall(id: $0.wallId, width: $0.widthM, height: $0.heightM, opening: $0.openingAreaM2)
        }
        let allIds = Set(ws.map(\.id))
        // Empty painted_wall_ids means "all walls".
        let paintedIds = r?.paintedWallIds ?? []
        let inc = paintedIds.isEmpty ? allIds : Set(paintedIds).intersection(allIds)

        _walls = State(initialValue: ws)
        _ceilingArea = State(initialValue: m?.ceilingAreaM2 ?? 0)
        _doorArea = State(initialValue: m?.doorAreaM2 ?? 0)
        _windowArea = State(initialValue: m?.windowAreaM2 ?? 0)
        _coats = State(initialValue: session.companyProfile?.coats ?? 2)
        _paintWalls = State(initialValue: r?.paintScope.walls ?? true)
        _paintCeiling = State(initialValue: r?.paintScope.ceiling ?? true)
        _included = State(initialValue: inc)
        _prepText = State(initialValue: (r?.preparationRequired ?? []).joined(separator: "\n"))
        _notesText = State(initialValue: (r?.specialNotes ?? []).joined(separator: "\n"))
        _verified = State(initialValue: m?.measurementsVerified ?? false)

        originalWalls = ws
        originalCeiling = m?.ceilingAreaM2 ?? 0
        originalDoor = m?.doorAreaM2 ?? 0
        originalWindow = m?.windowAreaM2 ?? 0
        originalCoats = session.companyProfile?.coats ?? 2
        originalWallsScope = r?.paintScope.walls ?? true
        originalCeilingScope = r?.paintScope.ceiling ?? true
        originalIncluded = inc
        originalPrep = r?.preparationRequired ?? []
        originalNotes = r?.specialNotes ?? []
        originalVerified = m?.measurementsVerified ?? false
        allWallIds = allIds
    }

    var body: some View {
        NavigationStack {
            Form {
                surfacesSection
                if !walls.isEmpty { wallsSection }
                roomSection
                coatsSection
                prepSection
                notesSection
                verificationSection
            }
            .navigationTitle("Edit Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onSave(nil, false, false); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: sections

    private var surfacesSection: some View {
        Section {
            Toggle("Paint walls", isOn: $paintWalls)
            Toggle("Paint ceiling", isOn: $paintCeiling)
            if paintWalls && !walls.isEmpty {
                ForEach(walls) { w in
                    Toggle(isOn: bindingForIncluded(w.id)) {
                        Text("Include \(w.id) · \(Format.squareMetres(max(w.width * w.height - w.opening, 0)))")
                    }
                }
            }
        } header: {
            Text("Surfaces")
        } footer: {
            Text("Turn off any wall the customer isn't having painted.")
        }
    }

    private var wallsSection: some View {
        Section("Wall Measurements (metres)") {
            ForEach($walls) { $w in
                VStack(alignment: .leading, spacing: 6) {
                    Text(w.id).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    numberRow("Width", value: $w.width)
                    numberRow("Height", value: $w.height)
                    numberRow("Openings (m²)", value: $w.opening)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var roomSection: some View {
        Section("Room") {
            numberRow("Ceiling area (m²)", value: $ceilingArea)
            numberRow("Door area (m²)", value: $doorArea)
            numberRow("Window area (m²)", value: $windowArea)
        }
    }

    private var coatsSection: some View {
        Section("Coats") {
            Stepper("\(coats) coat\(coats == 1 ? "" : "s")", value: $coats, in: 1 ... 5)
        }
    }

    private var prepSection: some View {
        Section {
            TextEditor(text: $prepText).frame(minHeight: 80)
        } header: {
            Text("Preparation")
        } footer: {
            Text("One item per line.")
        }
    }

    private var notesSection: some View {
        Section {
            TextEditor(text: $notesText).frame(minHeight: 70)
        } header: {
            Text("Customer Notes")
        } footer: {
            Text("Notes appear on the quote but don't change the visualization.")
        }
    }

    private var verificationSection: some View {
        Section {
            Toggle("I've verified these measurements on site", isOn: $verified)
        } footer: {
            Text("Clears the incomplete-scan warning. The original scan confidence is kept for the record.")
        }
    }

    // MARK: helpers

    private func numberRow(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField(label, value: value, format: .number.precision(.fractionLength(0 ... 2)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 90)
        }
    }

    private func bindingForIncluded(_ id: String) -> Binding<Bool> {
        Binding(
            get: { included.contains(id) },
            set: { on in if on { included.insert(id) } else { included.remove(id) } }
        )
    }

    private func lines(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func save() {
        let wallsChanged = zip(walls, originalWalls).contains { a, b in
            a.width != b.width || a.height != b.height || a.opening != b.opening
        } || walls.count != originalWalls.count
        let ceilingChanged = ceilingArea != originalCeiling
        let openingsChanged = doorArea != originalDoor || windowArea != originalWindow
        let coatsChanged = coats != originalCoats
        let scopeChanged = paintWalls != originalWallsScope || paintCeiling != originalCeilingScope
        let includedChanged = included != originalIncluded
        let prepChanged = lines(prepText) != originalPrep
        let notesChanged = lines(notesText) != originalNotes
        let verifiedChanged = verified != originalVerified

        // While the whole-room-fallback alert is active (an ungrounded
        // "paint only the wall with…" request), saving this sheet IS the
        // resolution: the painter is explicitly choosing the wall(s), so a
        // save must always go through — even if nothing was toggled.
        let resolvingWallScope = WallScopeAlert.reference(for: session.requirements) != nil
        let anyChange = wallsChanged || ceilingChanged || openingsChanged || coatsChanged
            || scopeChanged || includedChanged || prepChanged || notesChanged || verifiedChanged
            || resolvingWallScope
        guard anyChange else { onSave(nil, false, false); dismiss(); return }

        var payload = PlanEditPayload()
        if wallsChanged {
            payload.walls = walls.map {
                .init(wallId: $0.id, widthM: $0.width, heightM: $0.height, openingAreaM2: $0.opening)
            }
        }
        if ceilingChanged { payload.ceilingAreaM2 = ceilingArea }
        if doorArea != originalDoor { payload.doorAreaM2 = doorArea }
        if windowArea != originalWindow { payload.windowAreaM2 = windowArea }
        if coatsChanged { payload.coats = coats }
        if scopeChanged { payload.paintScope = PaintScope(walls: paintWalls, ceiling: paintCeiling) }
        if resolvingWallScope {
            // Resolving an ungrounded wall reference: send the selection
            // EXPLICITLY, including "all walls" as the full id list — the
            // usual empty-means-all shorthand would be indistinguishable
            // from the unresolved state and leave the alert stuck on.
            payload.paintedWallIds = Array(included)
        } else if includedChanged {
            // Empty = all walls; send the subset only when not everything is included.
            payload.paintedWallIds = included == allWallIds ? [] : Array(included)
        }
        if prepChanged { payload.preparationRequired = lines(prepText) }
        if notesChanged { payload.specialNotes = lines(notesText) }
        payload.measurementsVerified = verified

        // PDF is stale for any quote-relevant change (not a verification-only edit).
        let pdfStale = wallsChanged || ceilingChanged || openingsChanged || coatsChanged
            || scopeChanged || includedChanged || prepChanged || notesChanged
        // Visualization is stale only for surface/scope/prep changes.
        let visualStale = scopeChanged || includedChanged || prepChanged

        onSave(payload, pdfStale, visualStale)
        dismiss()
    }
}
