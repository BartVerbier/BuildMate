import Foundation
import SwiftUI
import UIKit

/// The painter's business details shown on the quote. Simple app settings —
/// no CRM, no customer database.
struct BusinessIdentity {
    var companyName: String
    var painterName: String
    var phone: String
    var email: String
    var terms: String
    var logo: UIImage?

    static let defaultTerms = """
    This quotation is valid for 30 days. Prices include VAT. \
    Final pricing may be adjusted after inspection of surfaces. \
    Work is scheduled upon written acceptance of this quote.
    """

    var isEmpty: Bool {
        companyName.isEmpty && painterName.isEmpty && phone.isEmpty && email.isEmpty
    }

    var contactLine: String {
        [painterName, phone, email].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static var logoFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("company-logo.jpg")
    }

    @MainActor
    static func load() -> BusinessIdentity {
        let defaults = UserDefaults.standard
        return BusinessIdentity(
            companyName: defaults.string(forKey: "business.company") ?? "",
            painterName: defaults.string(forKey: "business.painter") ?? "",
            phone: defaults.string(forKey: "business.phone") ?? "",
            email: defaults.string(forKey: "business.email") ?? "",
            terms: defaults.string(forKey: "business.terms") ?? Self.defaultTerms,
            logo: UIImage(contentsOfFile: logoFileURL.path)
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
