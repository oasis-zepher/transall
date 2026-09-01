#!/bin/zsh

set -euo pipefail

fail() {
  print -u2 -- "Release metadata validation failed: $1"
  exit 1
}

expect_raw_value() {
  local file_path="$1"
  local key_path="$2"
  local expected_value="$3"
  local label="$4"
  local actual_value

  if ! actual_value=$(plutil -extract "$key_path" raw "$file_path" 2>/dev/null); then
    fail "$label is missing."
  fi
  if [[ "$actual_value" != "$expected_value" ]]; then
    fail "$label must be '$expected_value', found '$actual_value'."
  fi
}

expect_json_value() {
  local actual_value="$1"
  local expected_value="$2"
  local label="$3"

  if [[ "$actual_value" != "$expected_value" ]]; then
    fail "$label does not match the reviewed App Store 1.0 declaration."
  fi
}

plutil -lint \
  Support/Info.plist \
  Support/Transall.entitlements \
  Support/Transall.Debug.entitlements \
  Resources/PrivacyInfo.xcprivacy

command -v jq >/dev/null || fail "jq is required for semantic plist validation."

expect_raw_value Support/Info.plist CFBundleDevelopmentRegion zh-Hans \
  "CFBundleDevelopmentRegion"
expect_raw_value Support/Info.plist CFBundleLocalizations 1 \
  "CFBundleLocalizations count"
expect_raw_value Support/Info.plist CFBundleLocalizations.0 zh-Hans \
  "CFBundleLocalizations[0]"
expect_raw_value Support/Info.plist CFBundleDisplayName Transall \
  "CFBundleDisplayName"
expect_raw_value Support/Info.plist CFBundleShortVersionString \
  '$(MARKETING_VERSION)' "CFBundleShortVersionString"
expect_raw_value Support/Info.plist CFBundleVersion \
  '$(CURRENT_PROJECT_VERSION)' "CFBundleVersion"
expect_raw_value Support/Info.plist ITSAppUsesNonExemptEncryption false \
  "ITSAppUsesNonExemptEncryption"
expect_raw_value Support/Info.plist LSApplicationCategoryType \
  public.app-category.productivity "LSApplicationCategoryType"
expect_raw_value Support/Info.plist TransallPrivacyPolicyURL \
  '$(TRANSALL_PRIVACY_POLICY_URL)' "TransallPrivacyPolicyURL"

readonly expected_entitlements='{"com.apple.security.app-sandbox":true,"com.apple.security.files.user-selected.read-write":true,"com.apple.security.network.client":true}'
for entitlement_file in \
  Support/Transall.entitlements \
  Support/Transall.Debug.entitlements; do
  entitlement_json=$(plutil -convert json -o - "$entitlement_file" | jq -S -c .) ||
    fail "$entitlement_file could not be normalized."
  expect_json_value "$entitlement_json" "$expected_entitlements" "$entitlement_file"
done

privacy_json=$(plutil -convert json -o - Resources/PrivacyInfo.xcprivacy) ||
  fail "PrivacyInfo.xcprivacy could not be normalized."

privacy_top_level_keys=$(print -r -- "$privacy_json" | jq -c 'keys') ||
  fail "PrivacyInfo.xcprivacy keys could not be inspected."
expect_json_value "$privacy_top_level_keys" \
  '["NSPrivacyAccessedAPITypes","NSPrivacyCollectedDataTypes","NSPrivacyTracking","NSPrivacyTrackingDomains"]' \
  "PrivacyInfo.xcprivacy top-level keys"

expect_raw_value Resources/PrivacyInfo.xcprivacy NSPrivacyTracking false \
  "NSPrivacyTracking"
expect_raw_value Resources/PrivacyInfo.xcprivacy NSPrivacyTrackingDomains 0 \
  "NSPrivacyTrackingDomains count"

collected_data_json=$(print -r -- "$privacy_json" | jq -c \
  '[.NSPrivacyCollectedDataTypes[] | {type: .NSPrivacyCollectedDataType, linked: .NSPrivacyCollectedDataTypeLinked, tracking: .NSPrivacyCollectedDataTypeTracking, purposes: (.NSPrivacyCollectedDataTypePurposes | sort)}] | sort_by(.type)') ||
  fail "NSPrivacyCollectedDataTypes could not be inspected."
expect_json_value "$collected_data_json" \
  '[{"type":"NSPrivacyCollectedDataTypeOtherUserContent","linked":true,"tracking":false,"purposes":["NSPrivacyCollectedDataTypePurposeAppFunctionality"]}]' \
  "NSPrivacyCollectedDataTypes"

accessed_api_json=$(print -r -- "$privacy_json" | jq -c \
  '[.NSPrivacyAccessedAPITypes[] | {type: .NSPrivacyAccessedAPIType, reasons: (.NSPrivacyAccessedAPITypeReasons | sort)}] | sort_by(.type)') ||
  fail "NSPrivacyAccessedAPITypes could not be inspected."
expect_json_value "$accessed_api_json" \
  '[{"type":"NSPrivacyAccessedAPICategoryFileTimestamp","reasons":["C617.1"]},{"type":"NSPrivacyAccessedAPICategoryUserDefaults","reasons":["CA92.1"]}]' \
  "NSPrivacyAccessedAPITypes"

print -- "Release metadata declarations are valid."
