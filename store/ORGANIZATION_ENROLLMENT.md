# Apple organization enrollment for Transall

## Decision

“团队开发” is not a display-name option on an individual Apple Developer account. To enroll as an organization, the publisher must be a registered legal entity that can sign contracts with Apple. Apple states that a DBA, trade name, fictitious business name, or branch is not accepted, and the organization's legal entity name is displayed as the seller name.

`Zephyr` can be used as product branding only. It will not become the seller name unless it is part of the verified legal entity name or Apple separately permits it as the developer name in App Store Connect.

## Required organization material

| Item | What Apple expects | Transall status |
| --- | --- | --- |
| Legal entity | Registered entity with authority to enter contracts | Missing |
| Legal entity name | Exact registered name; must match D&B records | Missing |
| D-U-N-S Number | D&B identifier used by Apple to verify the organization | Missing |
| Account Holder | Owner/founder, executive, senior project lead, or authorized employee with binding authority | Person not designated |
| Apple Account | Legal first and last name, two-factor authentication enabled | Verify before enrollment |
| Work email | Email associated with the organization's own domain | Missing |
| Phone | Reachable organization phone number | Missing |
| Website | Public, functional, associated with the organization and not merely a social page or minimal placeholder | Local template ready; domain and publication missing |
| Annual membership | Apple Developer Program enrollment fee shown in local currency | Not paid for organization |

## Correct sequence

1. Register or select the actual legal entity that will own Transall. Obtain accounting or legal advice for the jurisdiction; do not create a shell entity only to change the App Store display name.
2. Confirm the exact legal entity name, registered address, phone number, and authorized representative.
3. Check or request the entity's D-U-N-S Number and make sure the D&B record matches the registration documents.
4. Register an organization-controlled domain.
5. Create domain mailboxes such as `developer@domain` for the Apple Account and `support@domain` for customers. Avoid QQ and personal Gmail for organization verification.
6. Publish a functional organization website. The prepared Transall support and privacy pages can be part of it, but the site must also identify the organization and its real activity.
7. Enroll through Apple as an organization using the authorized person's Apple Account.
8. After approval, add other developers in Users and Access; keep the original enrollee as Account Holder unless a formal transfer is needed.

## Bundle identifier rule

The current `com.transall.mac` value is provisional. Register the final explicit App ID only after the organization domain is selected. Use reverse-DNS form owned by the publisher, for example:

```text
com.<organization-domain>.transall
```

Example only, not a reserved recommendation:

```text
com.example.transall
```

Do not create App Store Connect records with a speculative identifier: a bundle ID cannot be changed after a build is uploaded to that app record.

## Official Apple references

- [Apple Developer Program enrollment](https://developer.apple.com/programs/enroll/)
- [D-U-N-S Number](https://developer.apple.com/help/account/membership/D-U-N-S/)
- [Apple Developer Program roles](https://developer.apple.com/help/account/access/roles/)
