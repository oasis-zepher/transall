#!/bin/zsh

set -euo pipefail

plutil -lint \
  Support/Info.plist \
  Support/Transall.entitlements \
  Support/Transall.Debug.entitlements \
  Resources/PrivacyInfo.xcprivacy

test "$(plutil -extract CFBundleDevelopmentRegion raw Support/Info.plist)" = "zh-Hans"
test "$(plutil -extract CFBundleLocalizations.0 raw Support/Info.plist)" = "zh-Hans"
test "$(plutil -extract TransallPrivacyPolicyURL raw Support/Info.plist)" = \
  '$(TRANSALL_PRIVACY_POLICY_URL)'
