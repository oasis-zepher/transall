#!/bin/zsh

set -euo pipefail

readonly required_version=2.46.0
readonly script_directory=${0:a:h}
readonly project_root=${script_directory:h}

if ! xcodegen_binary=$(command -v xcodegen); then
  print -u2 -- "XcodeGen ${required_version} is required to verify Transall.xcodeproj."
  exit 69
fi
readonly xcodegen_binary

readonly actual_version=$("$xcodegen_binary" --version)
if [[ "$actual_version" != "Version: ${required_version}" ]]; then
  print -u2 -- "Expected XcodeGen ${required_version}, found: ${actual_version}"
  exit 1
fi

temporary_root=""
cleanup() {
  if [[ -n "$temporary_root" && -d "$temporary_root" && "$temporary_root" == */transall-xcodegen.* ]]; then
    rm -rf -- "$temporary_root"
  fi
}
trap cleanup EXIT

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/transall-xcodegen.XXXXXX")
cp "$project_root/project.yml" "$temporary_root/project.yml"
cp -R "$project_root/Sources" "$temporary_root/Sources"
cp -R "$project_root/Resources" "$temporary_root/Resources"
cp -R "$project_root/Tests" "$temporary_root/Tests"

"$xcodegen_binary" generate \
  --spec "$temporary_root/project.yml" \
  --project "$temporary_root" \
  --project-root "$temporary_root" \
  --no-env \
  --quiet

readonly committed_file_list="$temporary_root/committed-project-files.txt"
readonly generated_file_list="$temporary_root/generated-project-files.txt"

(
  cd "$project_root"
  git ls-files -- Transall.xcodeproj | LC_ALL=C sort
) > "$committed_file_list"
(
  cd "$temporary_root"
  find Transall.xcodeproj -type f -print | LC_ALL=C sort
) > "$generated_file_list"

if ! diff -u "$committed_file_list" "$generated_file_list"; then
  print -u2 -- "The committed Transall.xcodeproj file set differs from XcodeGen output."
  exit 1
fi

while IFS= read -r relative_path; do
  if ! diff -u "$project_root/$relative_path" "$temporary_root/$relative_path"; then
    print -u2 -- "${relative_path} differs from project.yml. Regenerate with XcodeGen ${required_version}."
    exit 1
  fi
done < "$generated_file_list"

if ! diff -u "$project_root/Support/Info.plist" "$temporary_root/Support/Info.plist"; then
  print -u2 -- "Support/Info.plist differs from project.yml. Regenerate it with XcodeGen ${required_version}."
  exit 1
fi
