# Pricing Rules Proposal — founder review (2026-09-01)

The app's Settings let a company set five pricing values that currently do
nothing: no rule ever defined how they change the price. This proposes a
rule for each, written to be marked up by a painter. **Nothing here is
implemented until reviewed** — after markup, the backend CompanyProfile
gains the fields, the estimator implements the agreed order of operations
with a visible line in the assumptions trail for every step, and the quote
PDF shows discount and minimum as lines the customer can see.

## The proposed order of operations

```
materials   = paint + primer + prep allowance + consumables allowance
subtotal    = materials + labour + travel
misc        = subtotal × misc %
with margin = (subtotal + misc) × (1 + profit margin)
discounted  = with margin × (1 − discount %)
floored     = max(discounted, minimum charge)        ← both ex-VAT
quote       = floored × (1 + VAT)
```

Worked example (small room): materials €120, labour €400, travel €25 →
subtotal €545; +5% misc = €572.25; +20% margin = €686.70; no discount;
above the €350 minimum; +21% VAT = **€830.91**.

## The five rules, one by one

### 1. Minimum charge
**Recommended:** a floor on the job total *excluding VAT*, applied after
margin and discount. If the arithmetic lands below it, the quote becomes
the minimum, VAT goes on top, and the quote says so ("Minimum call-out
applied").
**Why ex-VAT:** the VAT line on the PDF stays honest arithmetic instead of
being back-computed. **Alternative:** treat it as the bottom line the
customer pays (incl. VAT) — say so if that's how you think about it.
**Note:** the floor beats the discount — you never discount below your
minimum.
**Suggested starting value:** your call — the number below which the job
isn't worth loading the van.

### 2. Discount %
**Recommended:** off the *whole job* (after margin, before the minimum
floor), shown as its own line on the quote — customers respond to a
visible discount line. **Alternative:** labour-only discount; some firms
never discount materials. Default stays 0 — it's a per-quote sales tool,
not a standing setting, so ALSO worth deciding: should this live in
Settings at all, or be a per-visit control on the estimate screen?

### 3. Prep materials allowance (€ flat, per visit)
**Recommended:** added straight into the materials line (filler, caulk,
tape, sanding). Margin applies on top, same as paint. Typical range
€25–€60 per residential visit.

### 4. Consumables allowance (€ flat, per visit)
**Recommended:** same treatment — materials line (rollers, sleeves,
brushes, blades, sheeting). Typical range €15–€40. Kept separate from
prep so you can tune them independently; say the word if one combined
"sundries" number is closer to how you actually price.

### 5. Miscellaneous %
**Recommended:** a contingency on subtotal (materials + labour + travel),
before margin — the "every job has surprises" buffer. Typical 3–7%.
**Alternative:** fold it into the profit margin and delete the setting —
two stacked percentages are easy to double-count. If you never price
with a separate contingency, deleting is the honest move.

## Also found while reading Settings (for a later pass, not tonight)

- **Per-surface labour rates** (wall / ceiling / door / window / trim,
  €/m² or per item) exist in Settings, default 0, are never sent to the
  backend, and have no rules either. They imply a whole second pricing
  model (per-surface instead of per-hour). Worth deciding deliberately.
- **Quote validity days** (default 30) — displayed nowhere yet; the PDF
  should say "valid until <date>".

## What happens after your markup

Backend model + estimator implement exactly what you approve (tests
first, every step in the assumptions trail), the PDF gains the visible
lines, and the settings screen gets help text quoting the agreed rule so
future-you remembers what each number does.
