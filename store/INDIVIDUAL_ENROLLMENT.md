# Apple individual enrollment for Transall

## Decision

Transall will enroll in the Apple Developer Program as an individual.

The App Store seller name for an individual account is the member's verified legal name. `Zephyr` remains the product or studio brand, but it does not replace the legal seller name. Individual enrollment does not require a company, D-U-N-S Number, organization authorization, organization domain, or work email.

## Required personal material

| Item | What Apple expects | Transall status |
| --- | --- | --- |
| Legal name | The individual's real first and last name, matching identity records | Not recorded in source control |
| Apple Account | The same legal name, current address and phone, with two-factor authentication enabled | Verify before enrollment |
| Identity verification | Government-issued identification or device verification if Apple requests it | Complete only through Apple's official flow |
| Membership | Apple Developer Program enrollment accepted and annual fee paid | Pending |
| Public support email | A monitored address for App Store customers; it may differ from the Apple Account email | Placeholder only |
| Support and privacy URLs | Stable public HTTPS pages required for the App Store record | Local site ready; publication pending |

The Apple Account may use a personal email address. A dedicated custom-domain support address is still preferable for the public product page, but it is not an individual-enrollment requirement.

## Correct sequence

1. Confirm that the Apple Account uses the individual's legal name, current country or region, address, phone number, and two-factor authentication.
2. Enroll as an individual through Apple's official enrollment flow and complete identity verification if prompted.
3. Pay the membership fee shown by Apple and wait for activation.
4. Choose and register a stable, unique bundle identifier.
5. Select the individual's Apple Developer team in Xcode and let Xcode create or manage the required signing assets.
6. Complete the Paid Apps Agreement, tax questionnaire, and banking details in App Store Connect.
7. Replace the support-site placeholders and publish the support and privacy pages over HTTPS.
8. Create the App Store Connect app record and prepare the signed release candidate.

## Bundle identifier rule

The current `com.transall.mac` value is provisional. A bundle identifier must be unique and should remain stable for the life of the app. It does not require an organization-owned domain, but it should use a namespace you intend to keep, for example:

```text
com.<stable-namespace>.transall
```

Example only, not a reserved recommendation:

```text
com.zephyr.transall
```

Confirm availability in the Apple Developer portal before changing the Xcode project. Do not upload a build to the App Store Connect app record until the identifier is final, because the record's bundle ID cannot later be changed.

## Official Apple references

- [Apple Developer Program enrollment](https://developer.apple.com/programs/enroll/)
- [Choosing a membership](https://developer.apple.com/support/compare-memberships/)
- [Register a bundle ID](https://developer.apple.com/help/account/identifiers/register-an-app-id/)
