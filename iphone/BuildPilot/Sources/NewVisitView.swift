import SwiftUI

/// Who the quote is for. Captured before the scan; attached to the visit.
struct CustomerInfo: Equatable {
    var name = ""
    var address = ""
    var phone = ""
    var email = ""

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !address.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// The visit-start sequence, three screens in order (VisitSetupFlow):
/// 1. Customer details — no light-check activity at all.
/// 2. Light check — the walk-through survey; the gate's ARSession starts
///    here, on this screen's appearance, and not a moment earlier.
/// 3. Light report — the walk's verdict; Start Visit lives here and is
///    disabled while the worst reading is in the dark band.
struct NewVisitView: View {
    /// Starts the visit; the Date is when recording consent was confirmed.
    let onStart: (CustomerInfo, Date) -> Void
    let onCancel: () -> Void

    @State private var customer = CustomerInfo()
    @State private var flow = VisitSetupFlow()
    /// Set the moment the painter confirms the customer agreed to the
    /// recording; nil until then, and Start Visit stays disabled.
    @State private var consentConfirmedAt: Date?
    @FocusState private var focusedField: Field?
    @StateObject private var lightGate = LightingGateController()

    private enum Field { case name, address, phone, email }

    var body: some View {
        NavigationStack {
            Group {
                switch flow.step {
                case .details: detailsScreen
                case .lightCheck: lightCheckScreen
                case .report: reportScreen
                }
            }
            .background(Color(.systemBackground))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
            .onDisappear { lightGate.stop() }
            .onChange(of: lightGate.status) { _, status in
                // The survey's terminal states (Done Checking, or the
                // fail-open unavailable paths) advance to the report.
                switch status {
                case .complete, .unavailable: flow.surveyEnded()
                case .idle, .checking, .surveying: break
                }
            }
        }
    }

    // MARK: - 1. customer details (no light-check activity here)

    private var detailsScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header

                VStack(spacing: 14) {
                    field("Customer name", text: $customer.name,
                          symbol: "person.fill", focus: .name,
                          contentType: .name, required: true)
                    field("Property address", text: $customer.address,
                          symbol: "mappin.and.ellipse", focus: .address,
                          contentType: .fullStreetAddress, required: true)
                    field("Phone", text: $customer.phone,
                          symbol: "phone.fill", focus: .phone,
                          contentType: .telephoneNumber, keyboard: .phonePad)
                    field("Email", text: $customer.email,
                          symbol: "envelope.fill", focus: .email,
                          contentType: .emailAddress, keyboard: .emailAddress)
                }

                tradeSelector
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
        }
        .safeAreaInset(edge: .bottom) { nextButton }
        .onAppear { focusedField = .name }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("New Visit")
                .font(.system(.largeTitle, design: .rounded).bold())
            Text("Who is this quote for?")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private var nextButton: some View {
        Button {
            focusedField = nil
            flow.advanceToLightCheck(customerValid: customer.isValid)
        } label: {
            Label("Next: Check the Light", systemImage: "lightbulb")
                .font(.title3.weight(.bold))
                .frame(maxWidth: .infinity, minHeight: 58)
        }
        .buttonStyle(.borderedProminent)
        .tint(.yellow)
        .foregroundStyle(.black)
        .disabled(!customer.isValid)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(.bar)
    }

    private func field(
        _ placeholder: String, text: Binding<String>, symbol: String,
        focus: Field, contentType: UITextContentType? = nil,
        keyboard: UIKeyboardType = .default, required: Bool = false
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(focusedField == focus ? Color.yellow : .secondary)
                .frame(width: 24)
            TextField(required ? "\(placeholder) *" : placeholder, text: text, axis: placeholder.contains("address") ? .vertical : .horizontal)
                .textContentType(contentType)
                .keyboardType(keyboard)
                .autocorrectionDisabled(keyboard != .default)
                .textInputAutocapitalization(keyboard == .emailAddress ? .never : .words)
                .focused($focusedField, equals: focus)
                .submitLabel(focus == .email ? .done : .next)
                .onSubmit { advanceFocus(from: focus) }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(focusedField == focus ? Color.yellow.opacity(0.7) : .clear, lineWidth: 1.5)
        )
    }

    private func advanceFocus(from field: Field) {
        switch field {
        case .name: focusedField = .address
        case .address: focusedField = .phone
        case .phone: focusedField = .email
        case .email: focusedField = nil
        }
    }

    private var tradeSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TRADE")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .kerning(0.6)
            HStack(spacing: 10) {
                Label("Painter", systemImage: "paintbrush.fill")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(Color.yellow.opacity(0.18))
                    .foregroundStyle(Color.yellow)
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(Color.yellow, lineWidth: 1.5))
                Text("More trades coming")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - 2. the walk-through light check

    private var lightCheckScreen: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Check the Light")
                    .font(.system(.largeTitle, design: .rounded).bold())
                Text(LightingGateCopy.walkInstruction)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 12)

            Spacer()

            // The live meter — walk the room, watch it move.
            VStack(spacing: 14) {
                switch lightGate.status {
                case .checking:
                    ProgressView().controlSize(.large)
                    Text(LightingGateCopy.checking)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                case .surveying(let worst):
                    Image(systemName: worst == .dark ? "lightbulb.slash" : "lightbulb.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(worst == .dark ? Color.orange : Color.yellow)
                    Text(lightGate.liveReadout ?? LightingGateCopy.checking)
                        .font(.title2.weight(.semibold).monospacedDigit())
                    if let message = lightGate.status.message {
                        // A dark spot — say so while they stand in it.
                        Text(message)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                default:
                    EmptyView() // terminal states advance to the report
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Light survey in progress. Walk the room, then tap Done Checking.")

            Spacer()

            VStack(spacing: 10) {
                Button {
                    lightGate.finishSurvey()
                } label: {
                    Label(LightingGateCopy.doneChecking, systemImage: "checkmark")
                        .font(.title3.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: 58)
                }
                .buttonStyle(.borderedProminent)
                .tint(.yellow)
                .foregroundStyle(.black)
                .disabled(!lightGate.status.canFinish)

                Button("Back to details") {
                    lightGate.stop()
                    flow.backToDetails()
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                #if DEBUG
                debugFootnote
                #endif
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .onAppear { lightGate.start() } // NOT earlier — details stay camera-free
    }

    /// Recording consent: the conversation is recorded to draft the
    /// estimate, and the customer must have agreed out loud before the
    /// microphone starts. The painter confirms that here; the confirmation
    /// (with its timestamp) is stored with the visit.
    private var consentCard: some View {
        Toggle(isOn: Binding(
            get: { consentConfirmedAt != nil },
            set: { consentConfirmedAt = $0 ? Date() : nil }
        )) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Customer agreed to recording")
                    .font(.body.weight(.semibold))
                Text("The visit conversation is recorded to draft the estimate. Ask the customer before starting.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .tint(.green)
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityHint("Required before the visit can start")
    }

    // MARK: - 3. the light report

    private var reportScreen: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Light Report")
                    .font(.system(.largeTitle, design: .rounded).bold())
                Text("What the walk-through found.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 12)

            reportContent

            Spacer()

            consentCard

            VStack(spacing: 10) {
                Button {
                    // Teardown BEFORE the RoomPlan capture starts — the
                    // sampling ARSession must never overlap the
                    // RoomCaptureSession.
                    lightGate.stop()
                    onStart(customer, consentConfirmedAt ?? Date())
                } label: {
                    Label("Start Visit", systemImage: "camera.metering.matrix")
                        .font(.title3.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: 58)
                }
                .buttonStyle(.borderedProminent)
                .tint(.yellow)
                .foregroundStyle(.black)
                .disabled(!VisitStartRules.canStart(
                    lightAllowsStart: lightGate.status.allowsStart,
                    recordingConsentConfirmed: consentConfirmedAt != nil))

                #if DEBUG
                debugFootnote
                #endif
            }
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private var reportContent: some View {
        switch lightGate.status {
        case .complete(let worst):
            VStack(alignment: .leading, spacing: 16) {
                Label(
                    lightGate.status.message ?? LightingGateCopy.lightGoodThroughout,
                    systemImage: worst == .good ? "checkmark.circle.fill" : "lightbulb.slash"
                )
                .font(.body.weight(.semibold))
                .foregroundStyle(worst == .good ? Color.green : Color.orange)

                VStack(spacing: 0) {
                    if let worstLumens = lightGate.worstLumens {
                        reportRow("Lowest reading", "\(Int(worstLumens)) lm")
                    }
                    if lightGate.lowLightMoments > 0 {
                        Divider().padding(.vertical, 8)
                        reportRow("Low-light spots flagged", "\(lightGate.lowLightMoments)")
                    }
                }
                .padding(16)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                if worst != .good {
                    // Dim: advisory. Dark: Start stays disabled until a
                    // re-walk clears it — same fail-safe, judged on the
                    // walk's worst point.
                    Button {
                        lightGate.checkAgain()
                        flow.reWalk()
                    } label: {
                        Label(LightingGateCopy.checkAgain, systemImage: "arrow.clockwise")
                            .font(.body.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                }
            }
            .accessibilityElement(children: .combine)
        case .unavailable:
            // Fail open, but say so — a skipped check must not look like
            // a passed one.
            Label(LightingGateCopy.checkUnavailable, systemImage: "questionmark.circle")
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
        case .idle, .checking, .surveying:
            EmptyView() // transient — the flow only lands here on terminal states
        }
    }

    private func reportRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
        }
    }

    #if DEBUG
    // Debug builds always show the live gate state — "working and silent"
    // must never look identical to "dead and silent" on a test device.
    private var debugFootnote: some View {
        Text(lightGate.debugReadout)
            .font(.caption2.monospaced())
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    #endif
}
