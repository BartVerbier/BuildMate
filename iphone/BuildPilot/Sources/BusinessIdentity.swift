import Foundation
import SwiftUI
import UIKit

/// The painter's business details as they appear on ONE quote. This is now a
/// display view, built from either the current `ContractorSettings` (a live
/// quote) or a frozen `BusinessSnapshot` (a historical quote). It never reads
/// global settings directly, so a settings change can't rewrite an old PDF.
struct BusinessIdentity {
    var companyName: String
    var painterName: String
    var phone: String
    var email: String
    var website: String
    var address: String
    var vatNumber: String
    var currencyCode: String
    var terms: String
    var logo: UIImage?

    static let defaultTerms = BusinessSettings.defaultTerms

    var isEmpty: Bool {
        companyName.isEmpty && painterName.isEmpty && phone.isEmpty && email.isEmpty
    }

    var contactLine: String {
        [painterName, phone, email].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The painter's own logo file. Their logo wins; the bundled placeholder is
    /// the fallback so every quote still looks like it came from a real company.
    static var logoFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("company-logo.jpg")
    }

    private static var currentLogo: UIImage? {
        UIImage(contentsOfFile: logoFileURL.path) ?? UIImage(named: "DefaultLogo")
    }

    /// The live identity from the current settings — used for a quote that isn't
    /// yet snapshotted (a brand-new visit before its record is saved).
    @MainActor
    static func load() -> BusinessIdentity {
        from(settings: ContractorSettingsStore.loadOrMigrate(
            fileURL: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("contractor-settings.json"),
            defaults: .standard
        ))
    }

    static func from(settings: ContractorSettings) -> BusinessIdentity {
        let b = settings.business
        return BusinessIdentity(
            companyName: b.companyName, painterName: b.contactName,
            phone: b.phone, email: b.email, website: b.website, address: b.address,
            vatNumber: b.vatNumber, currencyCode: b.currencyCode,
            terms: b.paymentTerms, logo: currentLogo
        )
    }

    /// The identity frozen onto a visit at creation — the authoritative source
    /// for that visit's PDF. Logo comes from the per-visit freeze (falls back to
    /// the current/bundled logo only if none was frozen).
    static func from(snapshot: BusinessSnapshot, visitID: String) -> BusinessIdentity {
        BusinessIdentity(
            companyName: snapshot.companyName, painterName: snapshot.contactName,
            phone: snapshot.phone, email: snapshot.email, website: snapshot.website,
            address: snapshot.address, vatNumber: snapshot.vatNumber,
            currencyCode: snapshot.currencyCode, terms: snapshot.terms,
            logo: VisitBranding.logo(visitID: visitID) ?? currentLogo
        )
    }

    @MainActor
    static func saveLogo(_ image: UIImage?) {
        if let image, let data = image.jpegData(compressionQuality: 0.9) {
            try? data.write(to: logoFileURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: logoFileURL)
        }
    }
}

/// The business identity frozen onto a single visit. Text is stored verbatim
/// (a blank field stays blank on the quote); the logo is frozen separately as a
/// per-visit image file. This is what guarantees a historical quote keeps the
/// details that were active the day it was created.
struct BusinessSnapshot: Codable, Equatable {
    var companyName: String
    var contactName: String
    var phone: String
    var email: String
    var website: String
    var address: String
    var vatNumber: String
    var currencyCode: String
    var terms: String

    /// Freeze the current settings + logo onto `visitID`. Copies the painter's
    /// logo into a per-visit file so a later logo change can't alter this quote.
    @MainActor
    static func capture(from settings: ContractorSettings, visitID: String) -> BusinessSnapshot {
        VisitBranding.freeze(visitID: visitID)
        let b = settings.business
        return BusinessSnapshot(
            companyName: b.companyName, contactName: b.contactName,
            phone: b.phone, email: b.email, website: b.website, address: b.address,
            vatNumber: b.vatNumber, currencyCode: b.currencyCode, terms: b.paymentTerms
        )
    }
}

/// Per-visit logo freezing: a quote's logo is copied at creation so editing the
/// company logo later never rewrites past quotes.
enum VisitBranding {
    private static var dir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("visit-logos", isDirectory: true)
    }

    private static func fileURL(visitID: String) -> URL {
        dir.appendingPathComponent("\(visitID).jpg")
    }

    /// Copy the painter's current logo (if any) into this visit's frozen slot.
    @MainActor
    static func freeze(visitID: String) {
        let source = BusinessIdentity.logoFileURL
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = fileURL(visitID: visitID)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: source, to: dest)
    }

    static func logo(visitID: String) -> UIImage? {
        UIImage(contentsOfFile: fileURL(visitID: visitID).path)
    }
}
