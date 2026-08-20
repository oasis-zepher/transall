# Transall support site

Local source for the public Transall support and privacy-policy website required by App Store Connect.

## Before publishing

Update `app/publication-config.ts` with:

- the individual developer's verified legal name;
- a monitored public support address (a dedicated custom-domain address is preferred but not required for individual enrollment);
- the final policy effective date, if it changes.

Do not publish while bracketed placeholders remain.

## Commands

```bash
npm install
npm run dev
npm test
```

The site has no account system, tracking, analytics, database, or file upload. Its root route is the App Store support URL, `/privacy` is the privacy-policy URL, and `/about` identifies the individual publisher.

Every route provides a keyboard-visible “跳到主要内容” link targeting the same focusable main landmark. The rendered-HTML tests verify this bypass together with the navigation landmarks, target sizes, contrast, and page metadata.

`public/og.png` is the site-wide social preview for the support homepage, and `public/icon.png` reuses the native App icon. The privacy and publisher pages intentionally use their own text metadata without inheriting the social image.
