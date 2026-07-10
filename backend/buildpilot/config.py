"""V1 configuration: the hard-coded default company profile.

Per FOUNDER_SPEC.md the company profile is hard-coded in V1 but modelled as
a first-class estimator input so it becomes configurable later without
touching estimation logic. Values are placeholder-realistic for an EU
painting contractor and are expected to be tuned by the founder.
"""

from buildpilot.models.session import CompanyProfile

DEFAULT_COMPANY_PROFILE = CompanyProfile(
    profile_id="default-v1",
    labour_rate_eur_per_hour=45.0,
    paint_cost_eur_per_litre=18.0,
    primer_cost_eur_per_litre=15.0,
    paint_coverage_m2_per_litre=12.0,   # typical emulsion: 10-14 m2/L per coat
    primer_coverage_m2_per_litre=10.0,
    labour_m2_per_hour=10.0,            # rolling + cutting in, per coat
    coats=2,
    waste_factor=0.10,
    prep_factor=0.15,
    profit_margin=0.20,
    travel_cost_eur=25.0,
    vat_rate=0.21,
    currency="EUR",
)
