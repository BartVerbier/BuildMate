import SwiftUI

/// Customer name and address for the quotation document. Stored on the
/// visit record only — no CRM, no customer database.
struct CustomerDetailsSheet: View {
    @State var name: String
    @State var address: String
    let onSave: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Customer") {
                    TextField("Name", text: $name)
                        .textContentType(.name)
                    TextField("Address", text: $address, axis: .vertical)
                        .textContentType(.fullStreetAddress)
                        .lineLimit(2...4)
                }
            }
            .navigationTitle("Customer Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(name, address)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct PhotoThumbnail: View {
    let photo: VisitPhoto
    let visitID: String

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let image = PhotoStore.load(photo, visitID: visitID) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary)
                    .frame(width: 84, height: 84)
            }
            Text(photo.kind.label)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(4)
        }
        .accessibilityLabel("\(photo.kind.label) photo")
    }
}
