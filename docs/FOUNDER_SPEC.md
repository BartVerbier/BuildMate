# FOUNDER_SPEC.md

# BuildPilot -- Founder Specification (V1)

## Mission

Build an AI assistant that automates the site visit for painting
companies.

The objective is **not** to reinvent estimating software. The objective
is to automate the manual work between arriving at a customer's property
and producing a draft estimate.

------------------------------------------------------------------------

# Version One Scope

Support **painting companies only**.

Everything outside painting is explicitly out of scope for V1.

------------------------------------------------------------------------

# Success Criteria

A painter should be able to:

1.  Press **Start Visit**.
2.  Walk naturally around a room while talking with the customer.
3.  Press **Finish Visit**.
4.  Review a draft estimate generated from the room scan and
    conversation.

If this workflow works reliably, Version One is successful.

------------------------------------------------------------------------

# User Experience

The interface should be extremely simple.

Buttons:

-   Start Visit
-   Finish Visit
-   Review Estimate

No unnecessary menus or complexity.

------------------------------------------------------------------------

# Start Visit

When Start Visit is pressed:

-   Start RoomPlan
-   Start LiDAR
-   Start room capture
-   Start microphone recording

The user should simply walk around the room while speaking naturally
with the customer.

------------------------------------------------------------------------

# Finish Visit

When Finish Visit is pressed:

Stop:

-   RoomPlan
-   LiDAR
-   Camera capture
-   Microphone

Send all captured data to the local development server running on the
founder's Mac.

Assume both devices are on the same Wi-Fi network.

No cloud infrastructure is required for V1.

------------------------------------------------------------------------

# Required Technologies

Use Apple's native technologies wherever possible.

-   RoomPlan
-   RoomCaptureSession
-   ARKit
-   LiDAR
-   RealityKit (only where required)

Do **not** build a custom room-scanning engine.

------------------------------------------------------------------------

# Measurements

The application should calculate:

-   Gross wall area
-   Net wall area
-   Ceiling area
-   Floor area
-   Door area
-   Window area
-   Paintable surface area
-   Confidence score

Export structured JSON suitable for downstream AI processing.

------------------------------------------------------------------------

# Conversation Understanding

Convert the customer's conversation into structured requirements.

Example:

Customer: - Paint these walls. - Leave the ceiling. - Repair these
cracks.

Output: - Scope of work - Exclusions - Preparation required - Special
notes

------------------------------------------------------------------------

# Company Profile (Hard-coded for V1)

-   Hourly labour rate
-   Paint coverage per litre
-   Paint cost
-   Primer cost
-   Number of coats
-   Waste percentage
-   Preparation factor
-   Profit margin

------------------------------------------------------------------------

# Estimate Output

Generate a draft estimate containing:

-   Paint quantity
-   Primer quantity
-   Labour hours
-   Material cost
-   Labour cost
-   Suggested quotation

The estimate is advisory only.

The painter always has final approval.

------------------------------------------------------------------------

# Version One Does NOT Include

-   Multi-trade support
-   CRM
-   Scheduling
-   Invoicing
-   Customer management
-   Analytics
-   Notifications
-   Image generation
-   Visualisations
-   Cloud deployment
-   Authentication
-   Billing

------------------------------------------------------------------------

# Architecture Principles

-   The iPhone is the capture device.
-   The Mac is the AI processing engine during development.
-   Keep AI providers modular and replaceable.
-   Prioritise simplicity over cleverness.
-   Build the smallest possible prototype that proves the workflow.

------------------------------------------------------------------------

# Development Philosophy

Do not optimise prematurely.

Do not over-engineer.

Use proven technologies wherever possible.

The competitive advantage is not room scanning---it is automating the
site visit and transforming captured data into a professional draft
estimate.
