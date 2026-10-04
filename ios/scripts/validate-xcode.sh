#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    printf '%s\n' 'This validation requires macOS with Xcode 26 or newer.' >&2
    exit 2
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/../.." && pwd)"
ios_dir="$repo_dir/ios"

xcode_version="$(xcodebuild -version)"
xcode_major="$(printf '%s\n' "$xcode_version" | awk '/^Xcode / { split($2, parts, "."); print parts[1]; exit }')"
if [[ ! "$xcode_major" =~ ^[0-9]+$ ]] || (( xcode_major < 26 )); then
    printf '%s\n' 'Select Xcode 26 or newer with xcode-select before running validation.' >&2
    exit 2
fi

if [[ -n "${FIRAS_IOS_VALIDATION_DIR:-}" ]]; then
    mkdir -p -- "$FIRAS_IOS_VALIDATION_DIR"
    validation_dir="$(mktemp -d "$FIRAS_IOS_VALIDATION_DIR/run.XXXXXX")"
else
    validation_dir="$(mktemp -d "${TMPDIR:-/tmp}/firas-ios-validation.XXXXXX")"
fi
printf '%s\n' "$xcode_version" | tee "$validation_dir/toolchain.txt"
xcrun swiftc --version | tee -a "$validation_dir/toolchain.txt"
mac_sdk="$(xcrun --sdk macosx --show-sdk-path)"
mac_target="$(uname -m)-apple-macosx14.0"
printf '%s\n' "Validation artifacts: $validation_dir"

run_policy_test() {
    local test_name="$1"
    shift
    printf '\n%s\n' "Checking $test_name"
    xcrun --sdk macosx swiftc \
        -sdk "$mac_sdk" \
        -target "$mac_target" \
        -swift-version 6 \
        -strict-concurrency=complete \
        -parse-as-library \
        "$@" \
        -o "$validation_dir/$test_name" 2>&1 | tee "$validation_dir/$test_name-build.log"
    if [[ "$test_name" == "media-transport" ]]; then
        "$validation_dir/$test_name" "$validation_dir/media-fixture-port.txt" | tee "$validation_dir/$test_name.log"
    elif [[ "$test_name" == "difficulty-policy" ]]; then
        "$validation_dir/$test_name" "$repo_dir/tools/fixtures/native-difficulty-contract.json" | tee "$validation_dir/$test_name.log"
    else
        "$validation_dir/$test_name" | tee "$validation_dir/$test_name.log"
    fi
}

run_policy_test client-policy \
    "$ios_dir/FirasAI/Models/IntentModels.swift" \
    "$ios_dir/FirasAI/Models/OmnixModels.swift" \
    "$ios_dir/FirasAI/Networking/CloudEndpointPolicy.swift" \
    "$script_dir/test-client-policy.swift"

run_policy_test omnix-cloud-policy \
    "$ios_dir/FirasAI/Models/OmnixCloudModels.swift" \
    "$script_dir/test-omnix-cloud-policy.swift"

run_policy_test account-skills \
    "$ios_dir/FirasAI/Models/AccountSkillModels.swift" \
    "$script_dir/test-account-skills.swift"

run_policy_test difficulty-policy \
    "$ios_dir/FirasAI/Models/DifficultyPolicy.swift" \
    "$script_dir/test-difficulty-policy.swift"

run_policy_test account-skills-store-races \
    "$ios_dir/FirasAI/Models/AccountSkillModels.swift" \
    "$ios_dir/FirasAI/Stores/AccountSkillsStore.swift" \
    "$script_dir/account-skills-store-test-fixtures.swift" \
    "$script_dir/test-account-skills-store-races.swift"

run_policy_test chat-rendering \
    "$ios_dir/FirasAI/Features/Chat/ChatTextRenderer.swift" \
    "$script_dir/test-chat-rendering.swift"

run_policy_test chat-view-projection \
    "$ios_dir/FirasAI/Features/Chat/ChatViewProjection.swift" \
    "$script_dir/test-chat-view-projection.swift"

run_policy_test chat-image-presentation \
    "$ios_dir/FirasAI/Models/ChatImagePresentation.swift" \
    "$script_dir/test-chat-image-presentation.swift"

run_policy_test chat-skill-selection \
    "$ios_dir/FirasAI/Models/CommonModels.swift" \
    "$ios_dir/FirasAI/Models/ChatModels.swift" \
    "$ios_dir/FirasAI/Models/AccountSkillModels.swift" \
    "$ios_dir/FirasAI/Models/ChatSkillSelection.swift" \
    "$script_dir/model-generation-test-fixtures.swift" \
    "$script_dir/test-chat-skill-selection.swift"

run_policy_test chat-store-races \
    "$ios_dir/FirasAI/Models/PromptEngineerInstructions.swift" \
    "$ios_dir/FirasAI/Models/PromptEngineerModels.swift" \
    "$ios_dir/FirasAI/Models/CommonModels.swift" \
    "$ios_dir/FirasAI/Models/ChatModels.swift" \
    "$ios_dir/FirasAI/Models/IntentModels.swift" \
    "$ios_dir/FirasAI/Models/AccountSkillModels.swift" \
    "$ios_dir/FirasAI/Models/ChatSkillSelection.swift" \
    "$ios_dir/FirasAI/Models/DifficultyPolicy.swift" \
    "$ios_dir/FirasAI/Models/ChatDifficultySelection.swift" \
    "$ios_dir/FirasAI/Models/MediaStudioModels.swift" \
    "$ios_dir/FirasAI/Stores/ChatStore.swift" \
    "$script_dir/chat-store-test-fixtures.swift" \
    "$script_dir/test-chat-store-races.swift"

run_policy_test chat-difficulty-selection \
    "$ios_dir/FirasAI/Models/DifficultyPolicy.swift" \
    "$ios_dir/FirasAI/Models/ChatDifficultySelection.swift" \
    "$script_dir/test-chat-difficulty-selection.swift"

run_policy_test chat-difficulty-store \
    "$ios_dir/FirasAI/Models/PromptEngineerInstructions.swift" \
    "$ios_dir/FirasAI/Models/PromptEngineerModels.swift" \
    "$ios_dir/FirasAI/Models/CommonModels.swift" \
    "$ios_dir/FirasAI/Models/ChatModels.swift" \
    "$ios_dir/FirasAI/Models/IntentModels.swift" \
    "$ios_dir/FirasAI/Models/AccountSkillModels.swift" \
    "$ios_dir/FirasAI/Models/ChatSkillSelection.swift" \
    "$ios_dir/FirasAI/Models/DifficultyPolicy.swift" \
    "$ios_dir/FirasAI/Models/ChatDifficultySelection.swift" \
    "$ios_dir/FirasAI/Models/MediaStudioModels.swift" \
    "$ios_dir/FirasAI/Stores/ChatStore.swift" \
    "$script_dir/chat-store-test-fixtures.swift" \
    "$script_dir/test-chat-difficulty-store.swift"

run_policy_test prompt-engineer \
    "$ios_dir/FirasAI/Models/CommonModels.swift" \
    "$ios_dir/FirasAI/Models/ChatModels.swift" \
    "$ios_dir/FirasAI/Models/IntentModels.swift" \
    "$ios_dir/FirasAI/Models/AccountSkillModels.swift" \
    "$ios_dir/FirasAI/Models/ChatSkillSelection.swift" \
    "$ios_dir/FirasAI/Models/DifficultyPolicy.swift" \
    "$ios_dir/FirasAI/Models/ChatDifficultySelection.swift" \
    "$ios_dir/FirasAI/Models/MediaStudioModels.swift" \
    "$ios_dir/FirasAI/Models/PromptEngineerInstructions.swift" \
    "$ios_dir/FirasAI/Models/PromptEngineerModels.swift" \
    "$ios_dir/FirasAI/Networking/PromptEngineerAPI.swift" \
    "$ios_dir/FirasAI/Stores/ChatStore.swift" \
    "$ios_dir/FirasAI/Stores/PromptEngineerStore.swift" \
    "$script_dir/chat-store-test-fixtures.swift" \
    "$script_dir/prompt-engineer-test-fixtures.swift" \
    "$script_dir/test-prompt-engineer.swift"

run_policy_test model-generation \
    "$ios_dir/FirasAI/Models/CommonModels.swift" \
    "$ios_dir/FirasAI/Models/ChatModels.swift" \
    "$ios_dir/FirasAI/Models/SettingsModels.swift" \
    "$script_dir/model-generation-test-fixtures.swift" \
    "$script_dir/test-model-generation.swift"

run_policy_test code-store-races \
    "$ios_dir/FirasAI/Models/CommonModels.swift" \
    "$ios_dir/FirasAI/Models/ChatModels.swift" \
    "$ios_dir/FirasAI/Models/IntentModels.swift" \
    "$ios_dir/FirasAI/Models/CodeModels.swift" \
    "$ios_dir/FirasAI/Stores/CodeStore.swift" \
    "$script_dir/chat-store-test-fixtures.swift" \
    "$script_dir/code-store-test-fixtures.swift" \
    "$script_dir/test-code-store-races.swift"

run_policy_test media-wire \
    "$ios_dir/FirasAI/Models/MediaStudioModels.swift" \
    "$script_dir/test-media-wire.swift"

run_policy_test media-source-selection \
    "$ios_dir/FirasAI/Models/MediaStudioModels.swift" \
    "$ios_dir/FirasAI/Models/MediaSourceSelection.swift" \
    "$script_dir/test-media-source-selection.swift"

run_policy_test media-store-races \
    "$ios_dir/FirasAI/Models/CommonModels.swift" \
    "$ios_dir/FirasAI/Models/MediaStudioModels.swift" \
    "$ios_dir/FirasAI/Stores/MediaStudioStore.swift" \
    "$script_dir/media-store-test-fixtures.swift" \
    "$script_dir/test-media-store-races.swift"

# Only this runner-owned child serves synthetic loopback files. No live account
# or service is contacted, and only this child's PID is stopped on any exit.
media_fixture_pid=""
stop_media_fixture() {
    if [[ -n "$media_fixture_pid" ]]; then
        kill "$media_fixture_pid" 2>/dev/null || true
        wait "$media_fixture_pid" 2>/dev/null || true
        media_fixture_pid=""
    fi
}
trap stop_media_fixture EXIT
command -v python3 >/dev/null || { printf '%s\n' 'Python 3 is required for the synthetic media transport fixtures.' >&2; exit 2; }
python3 "$script_dir/media-transport-fixtures.py" \
    --port-file "$validation_dir/media-fixture-port.txt" \
    >"$validation_dir/media-fixture.log" 2>&1 &
media_fixture_pid="$!"
for ((attempt = 0; attempt < 50; attempt++)); do
    [[ -s "$validation_dir/media-fixture-port.txt" ]] && break
    kill -0 "$media_fixture_pid" 2>/dev/null || break
    sleep 0.1
done
if [[ ! -s "$validation_dir/media-fixture-port.txt" ]]; then
    printf '%s\n' "Synthetic media fixture failed to start; see $validation_dir/media-fixture.log" >&2
    exit 2
fi
run_policy_test media-transport \
    "$ios_dir/FirasAI/Models/CommonModels.swift" \
    "$ios_dir/FirasAI/Models/MediaStudioModels.swift" \
    "$ios_dir/FirasAI/Networking/CloudEndpointPolicy.swift" \
    "$ios_dir/FirasAI/Networking/APIClient.swift" \
    "$script_dir/model-generation-test-fixtures.swift" \
    "$script_dir/test-media-transport.swift"
stop_media_fixture

# A generic simulator destination checks every app source without depending on
# a particular device name or requiring provisioning credentials. This builds
# the app; device interaction and Instruments recording are separate checks.
destination="${FIRAS_IOS_DESTINATION:-generic/platform=iOS Simulator}"
for configuration in Debug Release; do
    printf '\n%s\n' "Building FirasAI $configuration for Simulator"
    xcodebuild \
        -project "$ios_dir/FirasAI.xcodeproj" \
        -scheme FirasAI \
        -configuration "$configuration" \
        -sdk iphonesimulator \
        -destination "$destination" \
        -derivedDataPath "$validation_dir/DerivedData" \
        -clonedSourcePackagesDirPath "$validation_dir/SourcePackages" \
        -resultBundlePath "$validation_dir/FirasAI-$configuration.xcresult" \
        CODE_SIGNING_ALLOWED=NO \
        build 2>&1 | tee "$validation_dir/FirasAI-$configuration.log"
done

printf '\n%s\n' 'PASS: native policy tests and Debug/Release Simulator builds.'
printf '%s\n' "Validation artifacts: $validation_dir"
printf '%s\n' 'Handset interaction, accessibility, APNs, and performance traces remain required before release.'
