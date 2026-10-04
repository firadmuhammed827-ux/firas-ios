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
    compile)
        xcodebuild \
            -project "$repo_dir/ios/FirasAI.xcodeproj" \
            -scheme FirasAI \
            -configuration Debug \
            -sdk iphonesimulator \
            -destination 'generic/platform=iOS Simulator' \
            -derivedDataPath "$qa_root/DerivedData" \
            -clonedSourcePackagesDirPath "$qa_root/SourcePackages" \
            -resultBundlePath "$qa_root/DebugCompile.xcresult" \
            CODE_SIGNING_ALLOWED=NO \
            CODE_SIGNING_REQUIRED=NO \
            'CODE_SIGN_IDENTITY=' \
            'DEVELOPMENT_TEAM=' \
            build 2>&1 | tee "$qa_root/debug-compile.log"
        ;;
    media-diagnostic)
        # Independent visibility only. The primary nineteen-suite/archive gate
        # remains authoritative; this mode never builds or packages an app.
        ios_dir="$repo_dir/ios"
        fixture_dir="$ios_dir/scripts"
        validation_dir="$qa_root/media-diagnostic"
        mkdir -p -- "$validation_dir"
        mac_sdk="$(xcrun --sdk macosx --show-sdk-path)"
        mac_target="$(uname -m)-apple-macosx14.0"
        fixture_pid=""
        stop_diagnostic_fixture() {
            if [[ -n "$fixture_pid" ]]; then
                kill "$fixture_pid" 2>/dev/null || true
                wait "$fixture_pid" 2>/dev/null || true
                fixture_pid=""
            fi
        }
        trap stop_diagnostic_fixture EXIT
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM
        printf 'suite=media-transport\npurpose=parallel_diagnostic_only\n' >"$validation_dir/media-transport-status.log"
        command -v python3 >/dev/null || { printf '%s\n' 'Python 3 is required for synthetic loopback media.' >&2; exit 2; }
        [[ ! -e "$validation_dir/media-fixture-port.txt" ]] || { printf '%s\n' 'A fresh diagnostic port file is required.' >&2; exit 2; }
        python3 "$fixture_dir/media-transport-fixtures.py" \
            --port-file "$validation_dir/media-fixture-port.txt" \
            >"$validation_dir/media-fixture.log" 2>&1 &
        fixture_pid="$!"
        for ((attempt = 0; attempt < 300; attempt++)); do
            [[ -s "$validation_dir/media-fixture-port.txt" ]] && break
            kill -0 "$fixture_pid" 2>/dev/null || break
            sleep 0.1
        done
        if [[ ! -s "$validation_dir/media-fixture-port.txt" ]]; then
            printf 'fixture_startup=failed\nruntime=skipped_fixture_startup\n' >>"$validation_dir/media-transport-status.log"
            printf '%s\n' 'Synthetic fixture did not publish its owned port within thirty seconds.' >&2
            exit 2
        fi
        printf 'fixture_startup=ready\n' >>"$validation_dir/media-transport-status.log"
        if xcrun --sdk macosx swiftc \
            -sdk "$mac_sdk" \
            -target "$mac_target" \
            -swift-version 6 \
            -strict-concurrency=complete \
            -parse-as-library \
            "$ios_dir/FirasAI/Models/CommonModels.swift" \
            "$ios_dir/FirasAI/Models/MediaStudioModels.swift" \
            "$ios_dir/FirasAI/Networking/CloudEndpointPolicy.swift" \
            "$ios_dir/FirasAI/Networking/APIClient.swift" \
            "$fixture_dir/model-generation-test-fixtures.swift" \
            "$fixture_dir/test-media-transport.swift" \
            -o "$validation_dir/media-transport" 2>&1 | tee "$validation_dir/media-transport-build.log"; then
            compile_exit_codes=("${PIPESTATUS[@]}")
        else
            compile_exit_codes=("${PIPESTATUS[@]}")
        fi
        printf 'compile_exit=%s\ncompile_log_exit=%s\n' "${compile_exit_codes[0]}" "${compile_exit_codes[1]}" >>"$validation_dir/media-transport-status.log"
        if (( compile_exit_codes[0] != 0 || compile_exit_codes[1] != 0 )); then
            printf 'runtime=skipped_compile_failure\n' >>"$validation_dir/media-transport-status.log"
            exit 1
        fi
        if "$validation_dir/media-transport" "$validation_dir/media-fixture-port.txt" 2>&1 | tee "$validation_dir/media-transport.log"; then
            runtime_exit_codes=("${PIPESTATUS[@]}")
        else
            runtime_exit_codes=("${PIPESTATUS[@]}")
        fi
        printf 'runtime_exit=%s\nruntime_log_exit=%s\n' "${runtime_exit_codes[0]}" "${runtime_exit_codes[1]}" >>"$validation_dir/media-transport-status.log"
        if (( runtime_exit_codes[0] != 0 || runtime_exit_codes[1] != 0 )); then
            exit 1
        fi
        printf '%s\n' 'PASS: independent media transport diagnostic; primary validation still required.'
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
        printf '%s\n' 'Usage: native-ios-artifact.sh toolchain|validate|compile|media-diagnostic|archive|collect' >&2
        exit 2
        ;;
esac
