# Transall support site

Local source for the public Transall support and privacy-policy website required by App Store Connect.

## Before publishing

Update `app/publication-config.ts` with:

- the organization's registered legal name;
- a support address on the organization's domain;
- the final policy effective date, if it changes.

Do not publish while bracketed placeholders remain.

## Commands

```bash
npm install
npm run dev
npm test
```

The site has no account system, tracking, analytics, database, or file upload. Its root route is the App Store support URL, `/privacy` is the privacy-policy URL, and `/about` identifies the publisher for organization verification.
