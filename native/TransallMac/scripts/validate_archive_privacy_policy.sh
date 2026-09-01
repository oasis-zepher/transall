#!/bin/zsh

set -euo pipefail

if [[ $# -ne 1 ]]; then
  print -u2 -- "Usage: validate_archive_privacy_policy.sh <built Info.plist>"
  exit 64
fi

readonly info_plist=$1
if [[ ! -f "$info_plist" ]]; then
  print -u2 -- "Built Info.plist not found: ${info_plist}"
  exit 66
fi

if ! policy_url=$(plutil -extract TransallPrivacyPolicyURL raw "$info_plist" 2>/dev/null); then
  print -u2 -- "TransallPrivacyPolicyURL is missing from the archived app."
  exit 1
fi
readonly policy_url

if [[ -z "$policy_url" || "$policy_url" == *'$('* || "$policy_url" == *[[:space:]]* ]]; then
  print -u2 -- "TransallPrivacyPolicyURL must be a configured public HTTPS URL."
  exit 1
fi
if [[ "$policy_url" != https://* ]]; then
  print -u2 -- "TransallPrivacyPolicyURL must use HTTPS."
  exit 1
fi

readonly authority=${${policy_url#https://}%%[/?#]*}
if [[ -z "$authority" || "$authority" == *"@"* ]]; then
  print -u2 -- "TransallPrivacyPolicyURL must not contain credentials."
  exit 1
fi
readonly host=${authority%%:*}
if [[ "$authority" == *:* ]]; then
  readonly port=${authority##*:}
  if [[ "$port" != <-> || "$port" -lt 1 || "$port" -gt 65535 ]]; then
    print -u2 -- "TransallPrivacyPolicyURL contains an invalid port."
    exit 1
  fi
fi
readonly normalized_host=${host:l}
if [[ "$normalized_host" != *.* || "$normalized_host" == .* || "$normalized_host" == *. \
  || "$normalized_host" == *..* ]]; then
  print -u2 -- "TransallPrivacyPolicyURL must use a public hostname."
  exit 1
fi
if [[ "$normalized_host" == *[^a-z0-9.-]* || "$normalized_host" != *[a-z]* ]]; then
  print -u2 -- "TransallPrivacyPolicyURL contains an invalid hostname."
  exit 1
fi
for label in ${(s:.:)normalized_host}; do
  if [[ -z "$label" || "$label" == -* || "$label" == *- ]]; then
    print -u2 -- "TransallPrivacyPolicyURL contains an invalid hostname label."
    exit 1
  fi
done
case "$normalized_host" in
  localhost | *.example | *.invalid | *.local | *.localhost | *.test)
    print -u2 -- "TransallPrivacyPolicyURL must not use a reserved or local hostname."
    exit 1
    ;;
esac

print -- "Transall privacy policy URL: ${policy_url}"
