import SwiftUI

/// The sales moment before the price: the painter reads the agreed scope
/// back to the customer in their own words, asks "anything else?", and only
/// then reveals the quote. Shown once per live visit — reopening a visit
/// from history goes straight to the quote.
struct ReadbackView: View {
    let session: SessionResponse
    let onShowQuote: () -> Void
    let onScanAgain: () -> Void

    @State private var confirmRescan = false

    private var requirements: RequirementExtraction? { session.requirements }
    private var hasConversation: Bool { requirements?.transcriptAvailable ?? false }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if hasConversation {
                        discussedCard
                    } else {
                        noConversationCard
                    }
                    salesPrompt
                }
                .padding(.horizontal, 20)
                .padding(.top, 28)
            }

            actions
        }
        .background(Color(.systemGroupedBackground))
    }

    private var header: some View {
        Text("Today we've discussed")
            .font(.system(.largeTitle, design: .rounded).bold())
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var discussedCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let r = requirements {
                ForEach(r.scopeOfWork, id: \.self) { item in
                    ReadbackLine(symbol: "checkmark.circle.fill", tint: .green, text: item)
                }
                ForEach(r.preparationRequired, id: \.self) { item in
                    ReadbackLine(symbol: "wrench.and.screwdriver.fill", tint: .green, text: item)
                }
                ForEach(r.exclusions, id: \.self) { item in
                    ReadbackLine(symbol: "minus.circle.fill", tint: .secondary, text: item)
                }
                ForEach(r.specialNotes, id: \.self) { item in
                    ReadbackLine(symbol: "text.bubble.fill", tint: .secondary, text: item)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// Honest fallback: without a usable conversation the scope is a default —
    /// the painter must know before turning the phone around.
    private var noConversationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("The conversation wasn't captured", systemImage: "exclamationmark.triangle.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.orange)
            Text("The quote uses the standard scope — walls and ceiling, two coats. Confirm the details with your customer before showing the price.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var salesPrompt: some View {
        Text("“Is there anything else you'd like included before I prepare your quote?”")
            .font(.system(.title3, design: .serif).italic())
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button(action: onShowQuote) {
                Label("Show the Quote", systemImage: "eurosign.circle.fill")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.borderedProminent)

            Button {
                confirmRescan = true
            } label: {
                Text("Something's missing — scan again")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(.bar)
        .confirmationDialog(
            "Start a new visit?",
            isPresented: $confirmRescan,
            titleVisibility: .visible
        ) {
            Button("New Visit") { onScanAgain() }
            Button("Stay Here", role: .cancel) {}
        } message: {
            Text("This visit is saved under Visits. Start a new one to capture anything that was missed.")
        }
    }
}

private struct ReadbackLine: View {
    let symbol: String
    let tint: Color
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .font(.body)
                .accessibilityHidden(true)
            Text(text)
                .font(.title3)
        }
    }
}
