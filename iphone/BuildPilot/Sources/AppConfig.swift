import Foundation

/// Who this device is acting as, and how it authenticates — the client half of
/// the backend's per-contractor identity model.
///
/// Every project on the backend belongs to exactly one contractor. The phone
/// declares which one via the `X-Contractor-Id` header (see
/// `HTTPBackendClient.authorizedRequest`). V1 ships single-tenant, so the id
/// defaults to `"default"` (matching the backend's `DEFAULT_CONTRACTOR_ID`);
/// when real per-contractor accounts land, only this type and the backend
/// resolver change — the request plumbing already carries the identity.
///
/// Both values are read from the app's Info.plist, which is populated at build
/// time from build settings (see `Secrets.xcconfig`). Nothing sensitive lives
/// in source: the shared API token is no longer a Swift literal.
struct ContractorIdentity {
    /// Which contractor owns the projects created from this device.
    let contractorId: String
    /// Shared bearer token for the protected backend; empty for pure-local
    /// development, where the Mac runs with authentication disabled.
    let apiToken: String

    static let current = ContractorIdentity(
        contractorId: AppConfig.string("BuildMateContractorId") ?? "default",
        apiToken: AppConfig.string("BuildMateAPIToken") ?? ""
    )
}

/// Reads build-time configuration from the Info.plist.
enum AppConfig {
    /// Returns a trimmed non-empty Info.plist string, or nil. Guards against an
    /// unexpanded build variable (`$(NAME)`) reaching runtime as a literal —
    /// treated as "not configured" rather than sent verbatim.
    static func string(_ key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value.hasPrefix("$(") { return nil }
        return value
    }
}
