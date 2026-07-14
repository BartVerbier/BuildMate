import SwiftUI

/// BuildMate's visual language in one place: the existing dark, yellow-accent
/// system codified into tokens and reusable components so every screen is
/// consistent. This is the M2 "codify" pass (Decision 33) — it unifies what
/// already exists; a visual refresh is a later milestone.
///
/// Screens should compose these instead of re-deriving spacing, radii, colours,
/// cards, rows, and buttons ad hoc.

// MARK: - Tokens

enum BPSpacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 28
}

enum BPRadius {
    static let control: CGFloat = 12
    static let card: CGFloat = 16
    static let hero: CGFloat = 20
}

enum BPColor {
    /// The single brand accent. Change here to restyle the whole app.
    static let accent = Color.yellow
    static let onAccent = Color.black
    static let screen = Color(.systemGroupedBackground)
    static let card = Color(.secondarySystemGroupedBackground)
}

extension CGFloat {
    /// Standard minimum tap target (Apple HIG).
    static let bpTapTarget: CGFloat = 44
}

// MARK: - Card

/// The standard grouped-content container used across every screen.
struct BPCard<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BPSpacing.m) {
            if let title {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .kerning(0.6)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(BPSpacing.l)
        .background(BPColor.card)
        .clipShape(RoundedRectangle(cornerRadius: BPRadius.card, style: .continuous))
    }
}

// MARK: - Labeled row

/// A label · optional detail · value row, with an optional leading SF Symbol.
struct BPLabeledRow: View {
    let label: String
    let detail: String?
    let value: String
    let symbol: String?

    init(_ label: String, detail: String? = nil, value: String, symbol: String? = nil) {
        self.label = label
        self.detail = detail
        self.value = value
        self.symbol = symbol
    }

    var body: some View {
        HStack(spacing: BPSpacing.s + 2) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.footnote)
                    .foregroundStyle(BPColor.accent)
                    .frame(width: 22)
                    .accessibilityHidden(true)
            }
            Text(label)
            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(value)
                .font(.body.weight(.medium).monospacedDigit())
        }
        .padding(.vertical, BPSpacing.xs)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Bullet list

struct BPBulletList: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: BPSpacing.s - 2) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: BPSpacing.s) {
                    Circle()
                        .fill(.tertiary)
                        .frame(width: 5, height: 5)
                        .offset(y: -2)
                    Text(item)
                }
            }
        }
    }
}

// MARK: - Buttons

/// The primary call-to-action: filled yellow, black label. Use for the one
/// dominant action on a screen (Start Visit, Share Quote).
struct BPPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.bold))
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(BPColor.accent)
            .foregroundStyle(BPColor.onAccent)
            .clipShape(RoundedRectangle(cornerRadius: BPRadius.control, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Secondary action: bordered, yellow tint. Use for supporting actions.
struct BPSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(BPColor.accent.opacity(0.14))
            .foregroundStyle(BPColor.accent)
            .clipShape(RoundedRectangle(cornerRadius: BPRadius.control, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Empty state

/// The standard "nothing here yet" screen: icon, title, message, optional CTA.
struct BPEmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: BPSpacing.l) {
            Image(systemName: symbol)
                .font(.system(size: 44))
                .foregroundStyle(BPColor.accent)
                .accessibilityHidden(true)
            Text(title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, BPSpacing.xxl)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(BPPrimaryButtonStyle())
                    .padding(.horizontal, BPSpacing.xxl)
                    .padding(.top, BPSpacing.xs)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Success banner

/// A brief, reassuring confirmation ("Quote saved"). Transient success message.
struct BPSuccessBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "checkmark.circle.fill")
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, BPSpacing.l)
            .padding(.vertical, BPSpacing.m - 2)
            .background(.green.opacity(0.18))
            .foregroundStyle(.green)
            .clipShape(Capsule())
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .combine)
    }
}
