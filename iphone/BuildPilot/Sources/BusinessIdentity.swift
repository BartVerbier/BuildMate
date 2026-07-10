import Foundation
import SwiftUI

/// The painter's business details shown on the quote. Simple app settings —
/// no CRM, no customer database.
struct BusinessIdentity {
    var companyName: String
    var painterName: String
    var phone: String
    var email: String

    var isEmpty: Bool {
        companyName.isEmpty && painterName.isEmpty && phone.isEmpty && email.isEmpty
    }

    var contactLine: String {
        [painterName, phone, email].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @MainActor
    static func load() -> BusinessIdentity {
        let defaults = UserDefaults.standard
        return BusinessIdentity(
            companyName: defaults.string(forKey: "business.company") ?? "",
            painterName: defaults.string(forKey: "business.painter") ?? "",
            phone: defaults.string(forKey: "business.phone") ?? "",
            email: defaults.string(forKey: "business.email") ?? ""
        )
    }
}
