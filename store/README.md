# Transall App Store submission package

This directory contains the non-code material required to move the native macOS app toward a paid App Store release.

## Package map

| Path | Purpose | Status |
| --- | --- | --- |
| `INDIVIDUAL_ENROLLMENT.md` | Personal identity and Apple individual enrollment requirements | Individual account selected; enrollment pending |
| `PAID_APP_SUBMISSION_CHECKLIST.md` | Agreements, banking, tax, pricing, compliance, and submission sequence | Prepared checklist |
| `APP_REVIEW_NOTES.md` | Draft notes and test steps for App Review | Draft complete; review API key missing |
| `SCREENSHOT_PLAN.md` | Required screenshot scenes, sizes, and privacy rules | Capture plan ready |
| `../output/pdf/review-samples/` | Synthetic PDFs for screenshots and App Review | Generated and visually verified |
| `support-site/` | Local support and privacy-policy website | Builds locally; not published |
| `../native/TransallMac/APP_STORE_METADATA.md` | Product-page copy and privacy answers | Draft complete; publisher fields missing |
| `../native/TransallMac/APP_STORE_READINESS.md` | Technical and account blockers | Current status |

## Do not submit until these values are final

1. Individual membership approved and the seller's legal name verified by Apple.
2. Final bundle identifier registered to the individual's Apple Developer team.
3. Public support email plus stable HTTPS support and privacy-policy URLs; the exact policy URL must also be supplied as `TRANSALL_PRIVACY_POLICY_URL` when archiving the app.
4. Paid Apps Agreement, tax forms, and bank account status in App Store Connect.
5. Published pages with no bracketed placeholders.
6. App Review test API key with a strict usage limit, entered only in App Store Connect.
7. Screenshots captured from the signed release candidate.

No legal name, address, email, bank, tax, or signing values should be invented in source control.
