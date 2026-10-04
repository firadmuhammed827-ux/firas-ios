#!/usr/bin/env bash
set -euo pipefail

# Review artifacts only. No signing account, Release, provider call or deploy.
qa_root="${FIRAS_NATIVE_QA_ROOT:?Set FIRAS_NATIVE_QA_ROOT to a runner-owned output directory.}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/../.." && pwd)"
mkdir -p -- "$qa_root"

case "${1:-}" in
    toolchain)
        [[ "$(uname -s)" == "Darwin" ]] || { printf '%s\n' 'macOS is required.' >&2; exit 2; }
        os_major="$(sw_vers -productVersion | cut -d . -f 1)"
        [[ "$os_major" == 26 ]] || { printf '%s\n' 'This review selects the macOS 26 runner.' >&2; exit 2; }
        [[ -d "${DEVELOPER_DIR:-}" ]] || { printf '%s\n' 'The pinned Xcode 26.6 installation is unavailable.' >&2; exit 2; }
        xcode_version="$(xcodebuild -version)"
        xcode_release="$(printf '%s\n' "$xcode_version" | awk '/^Xcode / { print $2; exit }')"
        [[ "$xcode_release" == 26.6 ]] || { printf '%s\n' 'Select the pinned Xcode 26.6 before validation.' >&2; exit 2; }
        {
            sw_vers
            printf '%s\n' "$xcode_version"
            xcrun swiftc --version
            xcrun --sdk iphoneos --show-sdk-version
            xcrun --sdk iphonesimulator --show-sdk-version
            printf 'Selected developer directory: %s\n' "$DEVELOPER_DIR"
        } | tee "$qa_root/toolchain.txt"
        [[ -f "$repo_dir/ios/FirasAI.xcodeproj/project.pbxproj" ]]
        [[ -f "$repo_dir/ios/FirasAI.xcodeproj/xcshareddata/xcschemes/FirasAI.xcscheme" ]]
        [[ -f "$repo_dir/tools/fixtures/native-difficulty-contract.json" ]]
        ;;
    validate)
        export FIRAS_IOS_VALIDATION_DIR="$qa_root/validation"
        bash "$repo_dir/ios/scripts/validate-xcode.sh" 2>&1 | tee "$qa_root/validate-xcode.log"
        ;;
    archive)
        archive_path="$qa_root/FirasAI-unsigned.xcarchive"
        xcodebuild \
            -project "$repo_dir/ios/FirasAI.xcodeproj" \
            -scheme FirasAI \
            -configuration Release \
            -sdk iphoneos \
            -destination 'generic/platform=iOS' \
            -derivedDataPath "$qa_root/DeviceDerivedData" \
            -clonedSourcePackagesDirPath "$qa_root/DeviceSourcePackages" \
            -archivePath "$archive_path" \
            -resultBundlePath "$qa_root/DeviceArchive.xcresult" \
            CODE_SIGNING_ALLOWED=NO \
            CODE_SIGNING_REQUIRED=NO \
            'CODE_SIGN_IDENTITY=' \
            'DEVELOPMENT_TEAM=' \
            archive 2>&1 | tee "$qa_root/device-archive.log"
        app_path="$archive_path/Products/Applications/FirasAI.app"
        [[ -f "$app_path/Info.plist" && -f "$app_path/FirasAI" ]]
        mkdir -p -- "$qa_root/artifacts" "$qa_root/ipa-stage/Payload"
        ditto "$app_path" "$qa_root/ipa-stage/Payload/FirasAI.app"
        ditto -c -k --sequesterRsrc --keepParent "$qa_root/ipa-stage/Payload" "$qa_root/artifacts/FirasAI-unsigned-review.ipa"
        ditto -c -k --keepParent "$archive_path" "$qa_root/artifacts/FirasAI-unsigned.xcarchive.zip"
        python3 - "$app_path/Info.plist" "$qa_root/artifacts/archive-metadata.json" <<'PY'
import json, plistlib, sys
from pathlib import Path
with Path(sys.argv[1]).open('rb') as stream:
    info = plistlib.load(stream)
if info.get('CFBundleIdentifier') != 'org.firasai.FirasAI':
    raise SystemExit('The archive is not the current native FirasAI target.')
report = {'status': 'unsigned-review-package-only', 'signing': 'disabled',
          'bundle_identifier': info.get('CFBundleIdentifier'),
          'executable': info.get('CFBundleExecutable'),
          'version': info.get('CFBundleShortVersionString'),
          'build': info.get('CFBundleVersion'),
          'sdk': info.get('DTSDKName'),
          'installable_signed_ipa': False, 'released_or_deployed': False}
Path(sys.argv[2]).write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
PY
        (cd -- "$qa_root/artifacts" && shasum -a 256 FirasAI-unsigned-review.ipa FirasAI-unsigned.xcarchive.zip archive-metadata.json > SHA256SUMS.txt)
        printf '%s\n' 'Unsigned review artifacts packaged. This is not an installable signed IPA or a GitHub Release.'
        ;;
    collect)
        python3 - "$qa_root" <<'PY'
import os, shutil, sys
from pathlib import Path
root = Path(sys.argv[1])
destination = root / 'diagnostics'
destination.mkdir(parents=True, exist_ok=True)
excluded = {'diagnostics', 'artifacts', 'ipa-stage', 'DeviceDerivedData', 'DeviceSourcePackages',
            'DerivedData', 'SourcePackages'}
for directory, names, files in os.walk(root):
    here = Path(directory)
    names[:] = [name for name in names if name not in excluded and not name.endswith('.xcarchive')]
    for name in list(names):
        if name.endswith('.xcresult'):
            source = here / name
            target = destination / source.relative_to(root)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copytree(source, target, dirs_exist_ok=True)
            names.remove(name)
    for name in files:
        if Path(name).suffix in {'.log', '.txt'}:
            source = here / name
            target = destination / source.relative_to(root)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
PY
        ;;
    *)
        printf '%s\n' 'Usage: native-ios-artifact.sh toolchain|validate|archive|collect' >&2
        exit 2
        ;;
esac
