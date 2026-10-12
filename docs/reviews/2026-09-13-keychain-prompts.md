# Repeated Keychain authorization — 2026-09-13

## Cause

Startup environment checks, settings loading, translation preflight, and the job processor all read credentials independently. Reads also migrated/deleted legacy records. The frequently replaced local app has only an ad hoc linker signature; no valid code-signing identities are installed. Updating that binary can cause macOS to require authorization again.

## Repair

- Automatic environment checks and settings loading cannot initiate authentication. Data Protection Keychain reads use an LAContext with interactionNotAllowed. Legacy Keychain checks inspect item metadata only, never password data.
- Actual on-device probing showed that LAContext alone did not reliably prevent the legacy call from waiting for UI. The metadata-only fallback returned in 0.028 seconds with DeepSeek marked as requiring a deliberate read and OpenAI absent. The probe printed only status booleans, never credential contents.
- Successful credential reads are cached in the existing worker actor for this process. Translation preflight and processing reuse the same cache. Nothing is added to plaintext files or logs.
- Reads no longer migrate, update, or delete credential records. Existing protected and legacy credentials remain readable. Explicit saves retain protected storage/migration behavior.
- Save, removal, rollback reconciliation, and explicit refresh invalidate/update cached entries appropriately. Automatic rollback reconciliation is noninteractive.
- Settings show 尚未读取 as a neutral state and provide 授权读取钥匙串 as an explicit action. The main provider menu distinguishes authorization from a missing configuration.

## Verification

37 targeted credential/settings/provider/startup tests passed with strict concurrency and warnings as errors. Tests cover both protected and legacy storage, no automatic authentication, cache reuse, save/removal/refresh, transaction rollback and reconciliation, invalid keys, and preflight/processor access. Formatting and diff checks passed; Release build succeeded and was installed to the existing workspace-validation app path.

The updated App restored the current failed job promptly after launch. Opening settings twice returned the neutral 尚未读取 state with the explicit authorization button, without entering an authentication flow. No real credential was read interactively or changed during verification; no translation request was sent.

The current user job `cc451467-3571-4418-a5e6-998615663f5e` is a different, 35-page paper and has complete translated-region recovery data plus 34 layout failures. It was preserved. That translation/layout issue is not a success claim for this Keychain repair.

## Boundary

The OS may still request authorization when the user first starts translation or deliberately reads settings, particularly after a development-build replacement or Keychain lock. This repair prevents background/repeated accesses and does not bypass Keychain security, change access-control lists, or promise permanent trust across changing unsigned builds.
