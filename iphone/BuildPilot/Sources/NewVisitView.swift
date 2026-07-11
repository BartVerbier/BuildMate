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

/// The premium visit-start screen: who is this quote for, which trade,
/// one big action. Required: customer name + property address.
struct NewVisitView: View {
    let onStart: (CustomerInfo) -> Void
    let onCancel: () -> Void

    @State private var customer = CustomerInfo()
    @FocusState private var focusedField: Field?

    private enum Field { case name, address, phone, email }

    var body: some View {
        NavigationStack {
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
            .background(Color(.systemBackground))
            .safeAreaInset(edge: .bottom) { startButton }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
            .onAppear { focusedField = .name }
        }
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

    private var startButton: some View {
        Button {
            onStart(customer)
        } label: {
            Label("Start Visit", systemImage: "camera.metering.matrix")
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
}
