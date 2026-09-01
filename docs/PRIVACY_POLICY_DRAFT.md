# Privacy Policy — DRAFT (milestone E)

> **Status: working draft, not published and not legal advice.** The App
> Store requires a hosted privacy policy URL and privacy nutrition labels
> before submission. Every `TODO(founder)` below is a decision only the
> founder can make, and the finished text needs a review by someone
> qualified in the target market's law (GDPR applies — the product records
> conversations in customers' homes in the EU).

## What the app actually collects (grounded in the code, 2026-09-01)

| Data | Where it goes | Why |
|---|---|---|
| 3D room geometry (RoomPlan scan) | Contractor's backend | Measurement |
| Audio of the visit conversation | Contractor's backend; transcribed **locally on the backend** by Whisper — the audio itself never goes to a third party | Requirements extraction |
| Transcript text | Anthropic API (one call per visit) | Structured requirements |
| Camera poses during the scan | Contractor's backend | Grounding "this wall" to geometry |
| Room photos (Before) | Contractor's backend; sent to Google (Gemini/Vertex) **only** when a visualization is requested | The "proposed result" image |
| Customer name and address | Contractor's backend; on the quote PDF | The quotation |
| Recording-consent confirmation + timestamp | Contractor's backend (`client_recording_consent*`) | Evidence the consent step happened |

Not collected: accounts, analytics, advertising identifiers, location.

## Consent

The conversation is recorded only after the painter confirms, in the app,
that the customer agreed. The confirmation and its timestamp are stored
with the visit. (Shipped 2026-09-01; the verbal ask remains the painter's
responsibility and local law may require more than verbal consent —
`TODO(founder): confirm per target market`.)

## Retention & deletion

- `TODO(founder):` how long are visit recordings kept? (Options: delete
  audio after transcription; keep N days; keep until visit deleted.)
- `TODO(founder):` the deletion process when a customer asks — today this
  is "delete the session directory", which works but needs a stated,
  reachable route (email? in-app?).

## Processors (to name in the published policy)

Railway (hosting — `TODO(founder): confirm region/EU data residency`),
Anthropic (transcript text), Google Cloud (visualization photos).

## Controller

`TODO(founder):` the legal entity name, address, and contact email that
stands behind this policy — this decides the boss/ownership question too.

## App Store privacy nutrition labels (draft answers)

- Contact Info: name, address — linked to the customer, not the user
- Audio Data: yes — app functionality only
- Photos: yes — app functionality only
- Data used to track: **none**; third-party advertising: **none**
