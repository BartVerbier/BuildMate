import Foundation

/// The contractor's editable business + pricing defaults — the foundation every
/// new estimate is built from. Local-first (one JSON file on the device); a
/// per-visit *snapshot* is what actually prices each visit, so editing these
/// defaults only affects future estimates, never historical quotes.
///
/// Design:
/// - This is the single source of truth for identity + pricing. `BusinessIdentity`
///   is now a display view built from either these settings (live) or a frozen
///   `BusinessSnapshot` (historical).
/// - `companyProfile()` maps the user-editable fields onto the backend's
///   `CompanyProfile` contract; fields the painter never sets (labour
///   productivity, prep labour factor) use the deterministic V1 defaults so the
///   default settings reproduce the current estimate exactly.
/// - Persisted with a `schemaVersion` so future shape changes migrate forward.
struct ContractorSettings: Codable, Equatable {
    var schemaVersion: Int = ContractorSettings.currentSchemaVersion
    var business: BusinessSettings = .default
    var pricing: PricingSettings = .default
    var paint: PaintSettings = .default
    var materials: MaterialsSettings = .default

    static let currentSchemaVersion = 1
    static let `default` = ContractorSettings()

    // Non-user-facing estimator inputs. Kept at the deterministic V1 defaults so
    // the out-of-the-box settings price identically to the pre-Settings build.
    // Exposed here (not hard-coded in the mapping) so they remain the one place
    // to change if productivity/prep modelling is ever surfaced.
    static let labourProductivityM2PerHour = 10.0
    static let prepLabourFactor = 0.15

    /// The backend pricing contract for a visit priced with these settings.
    /// Always built from a sanitized copy, so an out-of-range edit can never
    /// produce an invalid profile (negative rate, zero coverage, …).
    func companyProfile() -> CompanyProfilePayload {
        let s = sanitized()
        return CompanyProfilePayload(
            profileId: "contractor",
            labourRateEurPerHour: s.pricing.hourlyRate,
            paintCostEurPerLitre: s.paint.paintCostPerLitre,
            primerCostEurPerLitre: s.paint.primerCostPerLitre,
            paintCoverageM2PerLitre: s.paint.paintCoverageM2PerLitre,
            primerCoverageM2PerLitre: s.paint.primerCoverageM2PerLitre,
            labourM2PerHour: ContractorSettings.labourProductivityM2PerHour,
            coats: s.paint.coats,
            wasteFactor: s.paint.wasteFraction,
            prepFactor: ContractorSettings.prepLabourFactor,
            profitMargin: s.pricing.markupFraction,
            travelCostEur: s.pricing.travelCharge,
            vatRate: s.pricing.vatFraction,
            currency: s.business.currencyCode,
            minimumChargeEur: s.pricing.minimumCharge,
            discountRate: s.pricing.discountFraction,
            prepMaterialAllowanceEur: s.materials.prepAllowance,
            consumablesAllowanceEur: s.materials.consumablesAllowance,
            miscPercentage: s.materials.miscFraction
        )
    }

    /// A copy with every numeric field clamped to a sane, estimator-safe range.
    /// Rates/allowances non-negative, coverage strictly positive, coats ≥ 1,
    /// and the ratios (VAT/waste/misc/markup/discount) bounded so no edit can
    /// price a visit into nonsense.
    func sanitized() -> ContractorSettings {
        var copy = self
        copy.pricing.clamp()
        copy.paint.clamp()
        copy.materials.clamp()
        copy.business.quoteValidityDays = max(0, business.quoteValidityDays)
        return copy
    }
}

/// Business identity + terms shown on every quote. Currency is here (it governs
/// how money reads everywhere). Text fields stay verbatim — a blank field stays
/// blank on the quote, never a misleading placeholder or zero.
struct BusinessSettings: Codable, Equatable {
    var companyName = ""
    var contactName = ""
    var address = ""
    var phone = ""
    var email = ""
    var website = ""
    var vatNumber = ""          // VAT / CVR registration number (shown on the quote)
    var currencyCode = "EUR"    // ISO 4217; drives every money display
    var paymentTerms = BusinessSettings.defaultTerms
    var quoteValidityDays = 30

    static let defaultTerms = """
    This quotation is valid for 30 days. Prices include VAT. \
    Final pricing may be adjusted after inspection of surfaces. \
    Work is scheduled upon written acceptance of this quote.
    """

    static let `default` = BusinessSettings()
}

/// Labour rates, charges and commercial adjustments. Percentages are stored as
/// fractions (0.20 = 20 %); the UI presents whole percents. Per-surface rates
/// are captured now but not yet priced — a deliberate future estimator upgrade.
struct PricingSettings: Codable, Equatable {
    // Per-surface labour rates — STORED, not yet active in the estimator.
    var wallLabourRate = 0.0
    var ceilingLabourRate = 0.0
    var doorRate = 0.0
    var windowRate = 0.0
    var trimRate = 0.0

    // Active pricing inputs.
    var hourlyRate = 45.0
    var minimumCharge = 0.0
    var travelCharge = 25.0
    var markupFraction = 0.20
    var discountFraction = 0.0
    var vatFraction = 0.21

    static let `default` = PricingSettings()

    mutating func clamp() {
        wallLabourRate = max(0, wallLabourRate)
        ceilingLabourRate = max(0, ceilingLabourRate)
        doorRate = max(0, doorRate)
        windowRate = max(0, windowRate)
        trimRate = max(0, trimRate)
        hourlyRate = max(0, hourlyRate)
        minimumCharge = max(0, minimumCharge)
        travelCharge = max(0, travelCharge)
        markupFraction = min(max(0, markupFraction), 5.0)      // 0–500 %
        discountFraction = min(max(0, discountFraction), 0.9)  // 0–90 %
        vatFraction = min(max(0, vatFraction), 1.0)            // 0–100 %
    }
}

/// Paint & primer product defaults. Coverage must be > 0 (it divides area into
/// litres); coats ≥ 1. Product name is free text shown on the quote if set.
struct PaintSettings: Codable, Equatable {
    var productName = ""
    var paintCostPerLitre = 18.0
    var paintCoverageM2PerLitre = 12.0
    var coats = 2
    var wasteFraction = 0.10
    var primerCostPerLitre = 15.0
    var primerCoverageM2PerLitre = 10.0

    static let `default` = PaintSettings()

    mutating func clamp() {
        paintCostPerLitre = max(0, paintCostPerLitre)
        primerCostPerLitre = max(0, primerCostPerLitre)
        // Coverage divides area → must be strictly positive.
        paintCoverageM2PerLitre = max(0.1, paintCoverageM2PerLitre)
        primerCoverageM2PerLitre = max(0.1, primerCoverageM2PerLitre)
        coats = max(1, coats)
        wasteFraction = min(max(0, wasteFraction), 1.0)
    }
}

/// Flat and proportional additions to materials/overhead. All default to a
/// no-op (0), so the default settings price identically to the current build.
struct MaterialsSettings: Codable, Equatable {
    var prepAllowance = 0.0          // flat prep materials, per visit
    var consumablesAllowance = 0.0   // flat consumables (tape, sheeting…), per visit
    var miscFraction = 0.0           // % of materials+labour for overhead/misc

    static let `default` = MaterialsSettings()

    mutating func clamp() {
        prepAllowance = max(0, prepAllowance)
        consumablesAllowance = max(0, consumablesAllowance)
        miscFraction = min(max(0, miscFraction), 1.0)
    }
}

// MARK: - backend contract

/// Exactly the backend `CompanyProfile` shape (snake_case), sent as JSON in the
/// `company_profile` multipart field. Explicit CodingKeys — the field names
/// carry units and must match the server verbatim.
struct CompanyProfilePayload: Codable {
    let profileId: String
    let labourRateEurPerHour: Double
    let paintCostEurPerLitre: Double
    let primerCostEurPerLitre: Double
    let paintCoverageM2PerLitre: Double
    let primerCoverageM2PerLitre: Double
    let labourM2PerHour: Double
    let coats: Int
    let wasteFactor: Double
    let prepFactor: Double
    let profitMargin: Double
    let travelCostEur: Double
    let vatRate: Double
    let currency: String
    let minimumChargeEur: Double
    let discountRate: Double
    let prepMaterialAllowanceEur: Double
    let consumablesAllowanceEur: Double
    let miscPercentage: Double

    enum CodingKeys: String, CodingKey {
        case profileId = "profile_id"
        case labourRateEurPerHour = "labour_rate_eur_per_hour"
        case paintCostEurPerLitre = "paint_cost_eur_per_litre"
        case primerCostEurPerLitre = "primer_cost_eur_per_litre"
        case paintCoverageM2PerLitre = "paint_coverage_m2_per_litre"
        case primerCoverageM2PerLitre = "primer_coverage_m2_per_litre"
        case labourM2PerHour = "labour_m2_per_hour"
        case coats
        case wasteFactor = "waste_factor"
        case prepFactor = "prep_factor"
        case profitMargin = "profit_margin"
        case travelCostEur = "travel_cost_eur"
        case vatRate = "vat_rate"
        case currency
        case minimumChargeEur = "minimum_charge_eur"
        case discountRate = "discount_rate"
        case prepMaterialAllowanceEur = "prep_material_allowance_eur"
        case consumablesAllowanceEur = "consumables_allowance_eur"
        case miscPercentage = "misc_percentage"
    }

    func jsonData() -> Data? {
        try? JSONEncoder().encode(self)
    }
}

// MARK: - persistence + migration

/// Owns the on-device `contractor-settings.json`. Observable so the Settings
/// screen edits live. On first run it migrates the legacy `BusinessIdentity`
/// (UserDefaults + logo file) into settings without touching the originals, so
/// nothing an installed user has saved is lost.
@MainActor
final class ContractorSettingsStore: ObservableObject {
    @Published var settings: ContractorSettings {
        didSet { save() }
    }

    private let fileURL: URL
    private let defaults: UserDefaults

    init(fileURL: URL? = nil, defaults: UserDefaults = .standard) {
        self.fileURL = fileURL ?? FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("contractor-settings.json")
        self.defaults = defaults
        self.settings = ContractorSettingsStore.loadOrMigrate(fileURL: self.fileURL, defaults: defaults)
    }

    func resetToDefaults() {
        settings = .default
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Load the settings file; if absent, build it once from the legacy business
    /// identity + defaults. Future schema bumps migrate forward here.
    static func loadOrMigrate(fileURL: URL, defaults: UserDefaults) -> ContractorSettings {
        if let data = try? Data(contentsOf: fileURL),
           var decoded = try? JSONDecoder().decode(ContractorSettings.self, from: data) {
            if decoded.schemaVersion < ContractorSettings.currentSchemaVersion {
                decoded.schemaVersion = ContractorSettings.currentSchemaVersion // no field moves yet
            }
            return decoded
        }
        let migrated = migrateFromBusinessIdentity(defaults: defaults)
        if let data = try? JSONEncoder().encode(migrated) {
            try? data.write(to: fileURL, options: .atomic)
        }
        return migrated
    }

    /// Carry the existing business identity (company, painter, phone, email,
    /// terms — the fields the pre-Settings build stored) into new settings.
    /// The legacy UserDefaults keys and the logo file are left untouched.
    static func migrateFromBusinessIdentity(defaults: UserDefaults) -> ContractorSettings {
        var s = ContractorSettings.default
        s.business.companyName = defaults.string(forKey: "business.company") ?? ""
        s.business.contactName = defaults.string(forKey: "business.painter") ?? ""
        s.business.phone = defaults.string(forKey: "business.phone") ?? ""
        s.business.email = defaults.string(forKey: "business.email") ?? ""
        if let terms = defaults.string(forKey: "business.terms"), !terms.isEmpty {
            s.business.paymentTerms = terms
        }
        return s
    }
}
