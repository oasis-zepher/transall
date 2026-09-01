# Paid macOS App submission checklist

## 1. Account and commercial setup

- [ ] Individual enrollment approved and Apple Developer Program membership active.
- [ ] Account Holder signs the Paid Apps Agreement. Apple notes that this acceptance cannot be undone.
- [ ] Legal name, address, and contact data in Agreements, Tax, and Banking match the individual's official records.
- [ ] Bank account added for one supported payout currency; its account-holder name should match the individual developer's verified name. Prepare the account type, bank territory, bank code, account number, and IBAN/SWIFT or local fields where applicable.
- [ ] Account Holder approves any banking change initiated by an Admin or Finance user.
- [ ] Complete the tax questionnaire Apple presents for the individual's country or region. A non-US individual is commonly directed to Form W-8BEN, but the App Store Connect questionnaire is authoritative and may require a different form.
- [ ] Resolve all Agreements, Tax, and Banking status warnings before setting the app to paid.

## 2. App record

| Field | Prepared value |
| --- | --- |
| Platform | macOS |
| Name | Transall, subject to App Store availability |
| Primary language | Simplified Chinese |
| SKU | `TRANSALL-MAC-001` |
| Bundle ID | `com.transall.mac` is provisional; waiting for a final unique identifier and Apple registration |
| Version | `1.0.0` |
| Primary category | Productivity |
| Secondary category | Utilities |
| Age rating | Draft 4+; complete Apple's current questionnaire |
| Business model | One-time paid download; no In-App Purchases in 1.0 |
| Price | Publisher decision required; select an App Store Connect price point and review local proceeds |
| Availability | Publisher decision required by country/region |

## 3. Privacy and compliance

- [ ] Publish the support site and privacy policy over stable HTTPS.
- [ ] Replace the legal publisher and email placeholders in `support-site/app/publication-config.ts`.
- [x] Add an easily accessible first-party privacy-policy entry in Settings and block Release archives whose configured destination is missing or unsafe.
- [ ] Set `TRANSALL_PRIVACY_POLICY_URL` to the exact published `/privacy` URL, archive, and confirm the Settings link opens that same page.
- [ ] App Privacy: disclose `User Content → Other User Content` for `App Functionality` because translation text is transmitted to DeepSeek or OpenAI and may be retained by those providers.
- [ ] App Privacy: mark that user content may be linked to the user's provider account through the API key unless both providers' current terms and the configured account prove de-identification.
- [ ] App Privacy: Tracking = No.
- [ ] Explain in review notes that PDF editing, OCR, extraction, and conversion remain on device; only extracted translation text leaves the device.
- [ ] Confirm the PrivacyInfo.xcprivacy manifest still matches all Required Reason APIs at the time of submission.
- [x] Declare UserDefaults (`CA92.1`) and app-container file timestamps (`C617.1`) in the current privacy manifest.
- [ ] Encryption: verify the App Store Connect export-compliance answers for HTTPS through Apple frameworks; `ITSAppUsesNonExemptEncryption` is currently `false`.
- [ ] Declare Digital Services Act trader status. An individual selling a paid app in the EU may be treated as a trader; if declared as a trader, prepare the address, phone number, and email Apple requires for verification and public display.
- [ ] Confirm content rights for every sample document, icon, screenshot, and marketing image.

Why the privacy label is conservative: Apple defines collection as data transmitted off device and made accessible to the developer or third-party partners longer than needed for a real-time request. Translation is a normal product feature, so it does not meet all optional-disclosure criteria.

## 4. Build and signing

- [x] Install and accept the license for Apple-supported Xcode 26.6; tests, analysis, and the unsigned archive pass with this toolchain.
- [ ] Set the individual's Apple Developer Team and final bundle identifier in Xcode.
- [ ] Create or allow Xcode to manage the Mac App Distribution certificate and Mac Installer Distribution certificate/profile required by the current workflow.
- [ ] Archive a distribution-signed Release with App Sandbox enabled and the published `TRANSALL_PRIVACY_POLICY_URL`; the earlier unsigned universal preflight passed, and the current archive gate correctly rejects a missing URL.
- [ ] In the distribution-signed build, save, reload, and delete a disposable review API key to verify Data Protection Keychain access and legacy-key migration under the final application identifier.
- [ ] Validate the archive in Organizer.
- [x] Confirm the unsigned preflight archive has no Python, Homebrew paths, local server, prohibited private frameworks, or nested executables.
- [ ] Upload the archive and wait for processing before attaching it to version 1.0.0.

## 5. Product page and review

- [ ] Paste the final product copy from `native/TransallMac/APP_STORE_METADATA.md`.
- [ ] Upload screenshots from the signed release candidate using `SCREENSHOT_PLAN.md`.
- [x] Generate and visually verify synthetic screenshot and App Review files in `output/pdf/review-samples/`.
- [ ] Enter the published support URL and privacy-policy URL.
- [ ] Enter copyright using the verified individual rights-holder name.
- [ ] Add App Review contact details and the notes from `APP_REVIEW_NOTES.md`.
- [ ] Provide a rate-limited DeepSeek or OpenAI test API key to App Review through the secure review-information field, never in Git or screenshots.
- [ ] Test every route once in the signed sandbox build before submission.
- [ ] Choose manual or automatic release only after pricing, territories, and agreements are confirmed.

## Official Apple references

- [Sign and update agreements](https://developer.apple.com/help/app-store-connect/manage-agreements/sign-and-update-agreements/)
- [Provide tax information](https://developer.apple.com/help/app-store-connect/manage-tax-information/provide-tax-information/)
- [Enter banking information](https://developer.apple.com/help/app-store-connect/manage-banking-information/enter-banking-information/)
- [Set a price](https://developer.apple.com/help/app-store-connect/manage-app-pricing/set-a-price/)
- [App privacy details](https://developer.apple.com/app-store/app-privacy-details/)
- [EU DSA trader requirements](https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements/)
