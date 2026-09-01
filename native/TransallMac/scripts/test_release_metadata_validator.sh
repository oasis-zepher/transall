#!/bin/zsh

set -euo pipefail

readonly project_root="${0:A:h:h}"
readonly validator="$project_root/scripts/validate_release_metadata.sh"
readonly temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/transall-metadata-tests.XXXXXX")"
typeset -gi fixture_count=0
typeset -g fixture_root=""

cleanup() {
  rm -rf "$temporary_root"
}
trap cleanup EXIT

prepare_fixture() {
  fixture_count=$((fixture_count + 1))
  fixture_root="$temporary_root/fixture-$fixture_count"
  mkdir -p "$fixture_root/Support" "$fixture_root/Resources"
  cp "$project_root/Support/Info.plist" "$fixture_root/Support/Info.plist"
  cp "$project_root/Support/Transall.entitlements" \
    "$fixture_root/Support/Transall.entitlements"
  cp "$project_root/Support/Transall.Debug.entitlements" \
    "$fixture_root/Support/Transall.Debug.entitlements"
  cp "$project_root/Resources/PrivacyInfo.xcprivacy" \
    "$fixture_root/Resources/PrivacyInfo.xcprivacy"
}

expect_fixture_passes() {
  local label="$1"
  if ! (cd "$fixture_root" && zsh "$validator") >/dev/null; then
    print -u2 -- "Expected metadata fixture to pass: $label"
    exit 1
  fi
}

expect_fixture_fails() {
  local label="$1"
  if (cd "$fixture_root" && zsh "$validator") >/dev/null 2>&1; then
    print -u2 -- "Expected metadata fixture to fail: $label"
    exit 1
  fi
}

prepare_fixture
expect_fixture_passes "unmodified release metadata"

readonly entitlement_keys=(
  com.apple.security.app-sandbox
  com.apple.security.files.user-selected.read-write
  com.apple.security.network.client
)
for entitlement_name in Transall.entitlements Transall.Debug.entitlements; do
  for entitlement_key in $entitlement_keys; do
    prepare_fixture
    /usr/libexec/PlistBuddy -c "Delete :$entitlement_key" \
      "$fixture_root/Support/$entitlement_name"
    expect_fixture_fails "$entitlement_name missing $entitlement_key"

    prepare_fixture
    /usr/libexec/PlistBuddy -c "Set :$entitlement_key false" \
      "$fixture_root/Support/$entitlement_name"
    expect_fixture_fails "$entitlement_name disables $entitlement_key"
  done

  prepare_fixture
  /usr/libexec/PlistBuddy -c \
    'Add :com.apple.security.device.audio-input bool true' \
    "$fixture_root/Support/$entitlement_name"
  expect_fixture_fails "$entitlement_name adds an unreviewed capability"
done

replace_info_string_and_expect_failure() {
  local key_path="$1"
  local replacement="$2"
  prepare_fixture
  plutil -replace "$key_path" -string "$replacement" \
    "$fixture_root/Support/Info.plist"
  expect_fixture_fails "Info.plist changes $key_path"
}

replace_info_string_and_expect_failure CFBundleDevelopmentRegion en
replace_info_string_and_expect_failure CFBundleLocalizations.0 en
replace_info_string_and_expect_failure CFBundleDisplayName Other
replace_info_string_and_expect_failure CFBundleShortVersionString 9.9.9
replace_info_string_and_expect_failure CFBundleVersion 999
replace_info_string_and_expect_failure LSApplicationCategoryType \
  public.app-category.utilities
replace_info_string_and_expect_failure TransallPrivacyPolicyURL \
  https://privacy.invalid

prepare_fixture
plutil -insert CFBundleLocalizations.1 -string en \
  "$fixture_root/Support/Info.plist"
expect_fixture_fails "Info.plist adds an undeclared localization"

prepare_fixture
plutil -replace ITSAppUsesNonExemptEncryption -bool true \
  "$fixture_root/Support/Info.plist"
expect_fixture_fails "Info.plist changes export-compliance declaration"

privacy_file() {
  print -r -- "$fixture_root/Resources/PrivacyInfo.xcprivacy"
}

prepare_fixture
plutil -replace NSPrivacyTracking -bool true "$(privacy_file)"
expect_fixture_fails "privacy manifest enables tracking"

prepare_fixture
plutil -insert NSPrivacyTrackingDomains.0 -string tracking.invalid "$(privacy_file)"
expect_fixture_fails "privacy manifest adds a tracking domain"

prepare_fixture
plutil -replace NSPrivacyCollectedDataTypes.0.NSPrivacyCollectedDataType \
  -string NSPrivacyCollectedDataTypeEmailAddress "$(privacy_file)"
expect_fixture_fails "privacy manifest changes the collected data type"

prepare_fixture
plutil -replace NSPrivacyCollectedDataTypes.0.NSPrivacyCollectedDataTypeLinked \
  -bool false "$(privacy_file)"
expect_fixture_fails "privacy manifest changes linked-data disclosure"

prepare_fixture
plutil -replace NSPrivacyCollectedDataTypes.0.NSPrivacyCollectedDataTypeTracking \
  -bool true "$(privacy_file)"
expect_fixture_fails "privacy manifest changes collected-data tracking"

prepare_fixture
plutil -replace NSPrivacyCollectedDataTypes.0.NSPrivacyCollectedDataTypePurposes.0 \
  -string NSPrivacyCollectedDataTypePurposeAnalytics "$(privacy_file)"
expect_fixture_fails "privacy manifest changes collected-data purpose"

prepare_fixture
plutil -replace NSPrivacyAccessedAPITypes.0.NSPrivacyAccessedAPIType \
  -string NSPrivacyAccessedAPICategoryDiskSpace "$(privacy_file)"
expect_fixture_fails "privacy manifest changes UserDefaults API category"

prepare_fixture
plutil -replace NSPrivacyAccessedAPITypes.0.NSPrivacyAccessedAPITypeReasons.0 \
  -string WRONG.1 "$(privacy_file)"
expect_fixture_fails "privacy manifest changes UserDefaults reason"

prepare_fixture
plutil -replace NSPrivacyAccessedAPITypes.1.NSPrivacyAccessedAPIType \
  -string NSPrivacyAccessedAPICategorySystemBootTime "$(privacy_file)"
expect_fixture_fails "privacy manifest changes file-timestamp API category"

prepare_fixture
plutil -replace NSPrivacyAccessedAPITypes.1.NSPrivacyAccessedAPITypeReasons.0 \
  -string WRONG.2 "$(privacy_file)"
expect_fixture_fails "privacy manifest changes file-timestamp reason"

prepare_fixture
plutil -remove NSPrivacyAccessedAPITypes.1 "$(privacy_file)"
expect_fixture_fails "privacy manifest removes one Required Reason API"

prepare_fixture
plutil -insert UnexpectedKey -string unexpected "$(privacy_file)"
expect_fixture_fails "privacy manifest adds an unreviewed top-level declaration"

print -- "Release metadata validator regressions passed ($fixture_count fixtures)."
