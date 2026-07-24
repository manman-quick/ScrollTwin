#!/bin/zsh

set -euo pipefail

project_dir="${0:A:h:h}"
output_dir="${project_dir}/outputs"
app_dir="${output_dir}/ScrollTwin.app"
contents_dir="${app_dir}/Contents"
signing_identity="${SCROLLTWIN_CODESIGN_IDENTITY:--}"

cd "${project_dir}"
swift build -c release

mkdir -p "${contents_dir}/MacOS" "${contents_dir}/Resources"
cp ".build/release/ScrollTwin" "${contents_dir}/MacOS/ScrollTwin"
cp "Resources/Info.plist" "${contents_dir}/Info.plist"
chmod +x "${contents_dir}/MacOS/ScrollTwin"

xattr -cr "${app_dir}"
codesign_args=(--force --deep --sign "${signing_identity}")
if [[ "${signing_identity}" != "-" ]]; then
    codesign_args+=(--options runtime --timestamp)
fi
codesign "${codesign_args[@]}" "${app_dir}"
codesign --verify --deep --strict "${app_dir}"

echo "Code signing identity: ${signing_identity}"
echo "${app_dir}"
