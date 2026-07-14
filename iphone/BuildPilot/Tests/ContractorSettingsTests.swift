@testable import BuildPilot
import XCTest

/// Business Settings & Pricing: migration preserves an installed user's data,
/// default settings reproduce the current estimate exactly, edits map onto the
/// backend contract, and out-of-range values are clamped before they can price
/// a visit into nonsense.
@MainActor
final class ContractorSettingsTests: XCTestCase {
    private func isolatedDefaults() -> UserDefaults {
        let suite = "settings-test-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-\(UUID().uuidString).json")
    }

    // MARK: - migration

    func testMigrationPreservesExistingBusinessIdentity() {
        let defaults = isolatedDefaults()
        defaults.set("Nordic Painting", forKey: "business.company")
        defaults.set("Ariana", forKey: "business.painter")
        defaults.set("+45 1234 5678", forKey: "business.phone")
        defaults.set("ariana@example.com", forKey: "business.email")
        defaults.set("Custom terms text.", forKey: "business.terms")

        let s = ContractorSettingsStore.migrateFromBusinessIdentity(defaults: defaults)
        XCTAssertEqual(s.business.companyName, "Nordic Painting")
        XCTAssertEqual(s.business.contactName, "Ariana")
        XCTAssertEqual(s.business.phone, "+45 1234 5678")
        XCTAssertEqual(s.business.email, "ariana@example.com")
        XCTAssertEqual(s.business.paymentTerms, "Custom terms text.")
        // Fields the old build never had default sensibly, not to blank/zero.
        XCTAssertEqual(s.business.currencyCode, "EUR")
        XCTAssertEqual(s.pricing.hourlyRate, 45.0)
    }

    func testMigrationWithNoSavedDataUsesDefaults() {
        let s = ContractorSettingsStore.migrateFromBusinessIdentity(defaults: isolatedDefaults())
        XCTAssertEqual(s, .default)
    }

    func testStoreMigratesOnceThenReadsBackFromFile() {
        let url = tempURL()
        let defaults = isolatedDefaults()
        defaults.set("Ariana Paints", forKey: "business.company")

        // First load migrates and persists.
        let first = ContractorSettingsStore.loadOrMigrate(fileURL: url, defaults: defaults)
        XCTAssertEqual(first.business.companyName, "Ariana Paints")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        // A later load reads the saved file, not the legacy defaults again —
        // even if the legacy value changed, the saved settings win.
        defaults.set("Something Else", forKey: "business.company")
        let second = ContractorSettingsStore.loadOrMigrate(fileURL: url, defaults: defaults)
        XCTAssertEqual(second.business.companyName, "Ariana Paints")
    }

    func testEditsPersistThroughStore() {
        let url = tempURL()
        let store = ContractorSettingsStore(fileURL: url, defaults: isolatedDefaults())
        store.settings.pricing.hourlyRate = 72
        store.settings.business.currencyCode = "DKK"

        let reopened = ContractorSettingsStore(fileURL: url, defaults: isolatedDefaults())
        XCTAssertEqual(reopened.settings.pricing.hourlyRate, 72)
        XCTAssertEqual(reopened.settings.business.currencyCode, "DKK")
    }

    // MARK: - backend mapping

    /// The out-of-the-box settings must price a visit identically to the
    /// pre-Settings build (backend DEFAULT_COMPANY_PROFILE).
    func testDefaultSettingsReproduceCurrentPricing() {
        let p = ContractorSettings.default.companyProfile()
        XCTAssertEqual(p.labourRateEurPerHour, 45.0)
        XCTAssertEqual(p.paintCostEurPerLitre, 18.0)
        XCTAssertEqual(p.primerCostEurPerLitre, 15.0)
        XCTAssertEqual(p.paintCoverageM2PerLitre, 12.0)
        XCTAssertEqual(p.primerCoverageM2PerLitre, 10.0)
        XCTAssertEqual(p.labourM2PerHour, 10.0)
        XCTAssertEqual(p.coats, 2)
        XCTAssertEqual(p.wasteFactor, 0.10, accuracy: 1e-9)
        XCTAssertEqual(p.prepFactor, 0.15, accuracy: 1e-9)
        XCTAssertEqual(p.profitMargin, 0.20, accuracy: 1e-9)
        XCTAssertEqual(p.travelCostEur, 25.0)
        XCTAssertEqual(p.vatRate, 0.21, accuracy: 1e-9)
        XCTAssertEqual(p.currency, "EUR")
        // Additive terms are a no-op by default.
        XCTAssertEqual(p.minimumChargeEur, 0)
        XCTAssertEqual(p.discountRate, 0)
        XCTAssertEqual(p.prepMaterialAllowanceEur, 0)
        XCTAssertEqual(p.consumablesAllowanceEur, 0)
        XCTAssertEqual(p.miscPercentage, 0)
    }

    func testEditsMapOntoProfile() {
        var s = ContractorSettings.default
        s.pricing.hourlyRate = 90
        s.pricing.minimumCharge = 5000
        s.pricing.discountFraction = 0.1
        s.business.currencyCode = "DKK"
        s.materials.prepAllowance = 40
        s.materials.miscFraction = 0.05
        let p = s.companyProfile()
        XCTAssertEqual(p.labourRateEurPerHour, 90)
        XCTAssertEqual(p.minimumChargeEur, 5000)
        XCTAssertEqual(p.discountRate, 0.1, accuracy: 1e-9)
        XCTAssertEqual(p.currency, "DKK")
        XCTAssertEqual(p.prepMaterialAllowanceEur, 40)
        XCTAssertEqual(p.miscPercentage, 0.05, accuracy: 1e-9)
    }

    /// The JSON uses the exact snake_case keys the backend contract expects.
    func testProfileJSONUsesBackendFieldNames() throws {
        let data = try XCTUnwrap(ContractorSettings.default.companyProfile().jsonData())
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for key in ["labour_rate_eur_per_hour", "paint_coverage_m2_per_litre",
                    "labour_m2_per_hour", "minimum_charge_eur", "discount_rate",
                    "prep_material_allowance_eur", "consumables_allowance_eur",
                    "misc_percentage", "vat_rate", "currency"] {
            XCTAssertNotNil(obj[key], "missing backend key \(key)")
        }
        XCTAssertEqual(obj["labour_rate_eur_per_hour"] as? Double, 45.0)
    }

    // MARK: - validation

    func testValidationClampsOutOfRangeValues() {
        var s = ContractorSettings.default
        s.pricing.hourlyRate = -10           // no negative rates
        s.pricing.markupFraction = 10        // 1000 % → capped at 500 %
        s.pricing.discountFraction = 2.0     // 200 % → capped at 90 %
        s.pricing.vatFraction = 3.0          // → capped at 100 %
        s.paint.paintCoverageM2PerLitre = 0  // must be > 0
        s.paint.coats = 0                    // must be ≥ 1
        s.materials.prepAllowance = -50      // no negative allowance

        let p = s.companyProfile()
        XCTAssertEqual(p.labourRateEurPerHour, 0)
        XCTAssertEqual(p.profitMargin, 5.0)
        XCTAssertEqual(p.discountRate, 0.9)
        XCTAssertEqual(p.vatRate, 1.0)
        XCTAssertGreaterThan(p.paintCoverageM2PerLitre, 0)
        XCTAssertEqual(p.coats, 1)
        XCTAssertEqual(p.prepMaterialAllowanceEur, 0)
    }

    // MARK: - blank optional fields

    func testBlankBusinessFieldsStayBlankNotZero() {
        let identity = BusinessIdentity.from(settings: .default)
        XCTAssertTrue(identity.website.isEmpty)
        XCTAssertTrue(identity.vatNumber.isEmpty)
        XCTAssertTrue(identity.address.isEmpty)
        // Snapshot round-trips blanks as blanks.
        let snap = BusinessSnapshot.capture(from: .default, visitID: "visit-test")
        XCTAssertEqual(snap.website, "")
        XCTAssertEqual(snap.vatNumber, "")
    }
}
