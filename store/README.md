# Transall App Store submission package

This directory contains the non-code material required to move the native macOS app toward a paid App Store release.

## Package map

| Path | Purpose | Status |
| --- | --- | --- |
| `ORGANIZATION_ENROLLMENT.md` | Legal-entity and Apple organization enrollment requirements | Waiting for publisher decisions |
| `PAID_APP_SUBMISSION_CHECKLIST.md` | Agreements, banking, tax, pricing, compliance, and submission sequence | Prepared checklist |
| `APP_REVIEW_NOTES.md` | Draft notes and test steps for App Review | Draft complete; review API key missing |
| `SCREENSHOT_PLAN.md` | Required screenshot scenes, sizes, and privacy rules | Capture plan ready |
| `support-site/` | Local support and privacy-policy website | Builds locally; not published |
| `../native/TransallMac/APP_STORE_METADATA.md` | Product-page copy and privacy answers | Draft complete; publisher fields missing |
| `../native/TransallMac/APP_STORE_READINESS.md` | Technical and account blockers | Current status |

## Do not submit until these values are final

1. Registered legal entity name and D-U-N-S Number.
2. Organization-owned domain, public organization website, and domain email.
3. Final bundle identifier registered to the organization team.
4. Paid Apps Agreement, tax forms, and bank account status in App Store Connect.
5. Published support and privacy URLs with no bracketed placeholders.
6. App Review test API key with a strict usage limit, entered only in App Store Connect.
7. Screenshots captured from the signed release candidate.

No legal entity, domain, email, bank, tax, or signing values should be invented in source control.
