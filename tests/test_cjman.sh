#!/usr/bin/env bash

# This suite intentionally avoids Bats and Bash 4-only features so it can run
# with the Bash 3.2 bundled with macOS.

TEST_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$TEST_DIR/.." && pwd)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/cjman-tests.XXXXXX") || exit 1

TESTS_RUN=0
TESTS_FAILED=0

cleanup() {
    case "$TEST_TMP" in
        "${TMPDIR:-/tmp}"/cjman-tests.*)
            rm -rf -- "$TEST_TMP"
            ;;
    esac
}
trap cleanup EXIT HUP INT TERM

fail() {
    printf '    %s\n' "$*" >&2
    return 1
}

assert_equal() {
    local expected actual context
    expected=$1
    actual=$2
    context=${3:-values differ}

    if [ "$expected" != "$actual" ]; then
        fail "$context" \
            "expected: <$expected>" \
            "actual:   <$actual>"
        return 1
    fi
}

assert_not_equal() {
    local unexpected actual context
    unexpected=$1
    actual=$2
    context=${3:-values unexpectedly match}

    if [ "$unexpected" = "$actual" ]; then
        fail "$context" "both values: <$actual>"
        return 1
    fi
}

assert_function() {
    local function_name
    function_name=$1
    if [ "$(type -t "$function_name" 2>/dev/null)" != "function" ]; then
        fail "expected function '$function_name' to be defined"
        return 1
    fi
}

assert_not_function() {
    local name
    name=$1
    if [ "$(type -t "$name" 2>/dev/null)" = "function" ]; then
        fail "unexpected global function '$name' was defined"
        return 1
    fi
}

assert_output() {
    local expected actual status
    expected=$1
    shift

    actual=$("$@")
    status=$?
    if [ "$status" -ne 0 ]; then
        fail "command failed with status $status: $*"
        return 1
    fi
    assert_equal "$expected" "$actual" "unexpected output from: $*"
}

assert_failure() {
    local status
    "$@" >/dev/null 2>&1
    status=$?
    if [ "$status" -eq 0 ]; then
        fail "command unexpectedly succeeded: $*"
        return 1
    fi
}

run_test() {
    local test_name
    test_name=$1
    shift
    TESTS_RUN=$((TESTS_RUN + 1))

    if ( "$@" ); then
        printf 'ok %s - %s\n' "$TESTS_RUN" "$test_name"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        printf 'not ok %s - %s\n' "$TESTS_RUN" "$test_name"
    fi
}

mkdir -p "$TEST_TMP/cjman-home" "$TEST_TMP/fake-home/.cjman"
# Older cjman revisions load common from CJMAN_HOME. Keeping an isolated copy
# lets a failure exercise the new API contract instead of the developer's home.
cp "$PROJECT_ROOT/common" "$TEST_TMP/cjman-home/common"
cp "$PROJECT_ROOT/common" "$TEST_TMP/fake-home/.cjman/common"

unset CANGJIE_BUNDLES BASE_URL VERSIONS_URL
export HOME="$TEST_TMP/fake-home"
export CJMAN_HOME="$TEST_TMP/cjman-home"
export CJMAN_METADATA_DIR="$TEST_DIR/fixtures/metadata-v2"
export CJMAN_HOST_OS="MSYS_NT-10.0-22631"
export CJMAN_HOST_ARCH="AMD64"

# Sourcing cjman must not download anything. Unit tests below call only its pure
# selection and path helpers.
FUNCTIONS_BEFORE_SOURCE=$(declare -F | awk '{ printf "%s ", $3 }')
. "$PROJECT_ROOT/cjman"
SOURCE_STATUS=$?
FUNCTIONS_AFTER_SOURCE=$(declare -F | awk '{ printf "%s ", $3 }')

test_source_and_namespace() {
    local function_name
    assert_equal "0" "$SOURCE_STATUS" "sourcing cjman failed" || return 1
    assert_equal "$TEST_TMP/cjman-home" "$CJMAN_HOME" \
        "CJMAN_HOME override was not preserved" || return 1
    assert_equal "$TEST_DIR/fixtures/metadata-v2" "$CJMAN_METADATA_DIR" \
        "CJMAN_METADATA_DIR override was not preserved" || return 1
    assert_equal "MSYS_NT-10.0-22631" "$CJMAN_HOST_OS" \
        "CJMAN_HOST_OS override was not preserved" || return 1
    assert_equal "AMD64" "$CJMAN_HOST_ARCH" \
        "CJMAN_HOST_ARCH override was not preserved" || return 1

    assert_function cjman || return 1
    assert_function __cjman_normalize_os || return 1
    assert_function __cjman_normalize_arch || return 1
    assert_function __cjman_resolve_stable_alias || return 1
    assert_function __cjman_select_stable_sdk || return 1
    assert_function __cjman_pick_stdx_asset || return 1
    assert_function __cjman_install_dir || return 1

    # "source cjman" must not shadow ordinary commands in the caller's shell.
    assert_not_function list || return 1
    assert_not_function install || return 1
    assert_not_function use || return 1
    assert_not_function update || return 1
    assert_not_function usage || return 1

    for function_name in $FUNCTIONS_AFTER_SOURCE; do
        case " $FUNCTIONS_BEFORE_SOURCE " in
            *" $function_name "*)
                continue
                ;;
        esac
        case "$function_name" in
            cjman | __cjman_*)
                ;;
            *)
                fail "sourcing cjman leaked public function '$function_name'"
                return 1
                ;;
        esac
    done
}

test_os_normalization() {
    assert_output linux __cjman_normalize_os Linux || return 1
    assert_output linux __cjman_normalize_os Linux-gnu || return 1
    assert_output mac __cjman_normalize_os Darwin || return 1
    assert_output mac __cjman_normalize_os Darwin24.6.0 || return 1
    assert_output windows __cjman_normalize_os MINGW64_NT-10.0-22631 || return 1
    assert_output windows __cjman_normalize_os MINGW32_NT-6.2 || return 1
    assert_output windows __cjman_normalize_os MSYS_NT-10.0-22631 || return 1
    assert_output windows __cjman_normalize_os CYGWIN_NT-10.0-22631 || return 1
    assert_failure __cjman_normalize_os FreeBSD
}

test_arch_normalization() {
    assert_output x64 __cjman_normalize_arch x86_64 || return 1
    assert_output x64 __cjman_normalize_arch amd64 || return 1
    assert_output x64 __cjman_normalize_arch AMD64 || return 1
    assert_output x64 __cjman_normalize_arch X64 || return 1
    assert_output aarch64 __cjman_normalize_arch aarch64 || return 1
    assert_output aarch64 __cjman_normalize_arch arm64 || return 1
    assert_output aarch64 __cjman_normalize_arch ARM64 || return 1
    assert_output arm32 __cjman_normalize_arch armv7l || return 1
    assert_output arm32 __cjman_normalize_arch arm32 || return 1
    assert_failure __cjman_normalize_arch mips64
}

test_stable_aliases() {
    assert_function __cjman_resolve_stable_alias || return 1
    assert_output 1.1.3 __cjman_resolve_stable_alias latest || return 1
    assert_output 1.0.1 __cjman_resolve_stable_alias lts || return 1
    assert_output 1.1.3 __cjman_resolve_stable_alias sts || return 1
    assert_output 1.0.1 __cjman_resolve_stable_alias LTS || return 1
    assert_output 1.1.3 __cjman_resolve_stable_alias STS || return 1
    assert_output 1.0.1 __cjman_resolve_stable_alias 1.0.1
}

test_stable_sdk_exact_native_selection() {
    local manifest expected actual status
    assert_function __cjman_select_stable_sdk || return 1
    manifest=$(sed -n '1,$p' \
        "$CJMAN_METADATA_DIR/releases/1.1.3.tsv")
    expected=$(printf '%s\n' "$manifest" | awk -F '	' \
        '$1 == "sdk" && $2 == "linux" && $3 == "x64" &&
         $4 == "native" && $5 == "x64" && $6 == "default" {
             print
             exit
         }')

    actual=$(__cjman_select_stable_sdk \
        "$manifest" "linux" "x64" "native" "x64" "default")
    status=$?
    if [ "$status" -ne 0 ]; then
        fail "stable native SDK selector failed with status $status"
        return 1
    fi
    assert_equal "$expected" "$actual" \
        "stable selector did not return the exact native SDK row"
}

test_stable_sdk_windows_prefers_zip() {
    local manifest expected actual status
    assert_function __cjman_select_stable_sdk || return 1
    manifest=$(sed -n '1,$p' \
        "$CJMAN_METADATA_DIR/releases/1.1.3.tsv")
    expected=$(printf '%s\n' "$manifest" | awk -F '	' \
        '$1 == "sdk" && $2 == "windows" && $3 == "x64" &&
         $4 == "native" && $5 == "x64" && $6 == "default" &&
         $7 == "zip" {
             print
             exit
         }')

    actual=$(__cjman_select_stable_sdk \
        "$manifest" "windows" "x64" "native" "x64" "default")
    status=$?
    if [ "$status" -ne 0 ]; then
        fail "Windows stable SDK selector failed with status $status"
        return 1
    fi
    assert_equal "$expected" "$actual" \
        "Windows auto-install must select the zip archive, never the exe"
}

test_stable_sdk_selects_mac_aarch64_host() {
    local manifest expected actual status
    assert_function __cjman_select_stable_sdk || return 1
    manifest=$(sed -n '1,$p' \
        "$CJMAN_METADATA_DIR/releases/1.1.3.tsv")
    expected=$(printf '%s\n' "$manifest" | awk -F '	' \
        '$1 == "sdk" && $2 == "mac" && $3 == "aarch64" &&
         $4 == "native" && $5 == "aarch64" && $6 == "default" {
             print
             exit
         }')

    actual=$(__cjman_select_stable_sdk \
        "$manifest" "mac" "aarch64" "native" "aarch64" "default")
    status=$?
    if [ "$status" -ne 0 ]; then
        fail "aarch64 stable SDK selector failed with status $status"
        return 1
    fi
    assert_equal "$expected" "$actual" \
        "selector did not return the aarch64 host SDK"
}

test_stable_sdk_matches_cross_target_and_any_arch() {
    local manifest expected actual status
    assert_function __cjman_select_stable_sdk || return 1
    manifest=$(sed -n '1,$p' \
        "$CJMAN_METADATA_DIR/releases/1.1.3.tsv")
    expected=$(printf '%s\n' "$manifest" | awk -F '	' \
        '$1 == "sdk" && $2 == "linux" && $3 == "x64" &&
         $4 == "android" && $5 == "any" && $6 == "default" {
             print
             exit
         }')

    actual=$(__cjman_select_stable_sdk \
        "$manifest" "linux" "x64" "android" "aarch64" "default")
    status=$?
    if [ "$status" -ne 0 ]; then
        fail "Android SDK selector failed with status $status"
        return 1
    fi
    assert_equal "$expected" "$actual" \
        "selector confused the Android SDK with another target"
}

test_stable_sdk_no_exact_match_fails() {
    local manifest status
    assert_function __cjman_select_stable_sdk || return 1
    manifest=$(sed -n '1,$p' \
        "$CJMAN_METADATA_DIR/releases/1.1.3.tsv")

    __cjman_select_stable_sdk \
        "$manifest" "linux" "x64" "ios" "aarch64" "default" \
        >/dev/null 2>&1
    status=$?
    if [ "$status" -eq 0 ]; then
        fail "stable selector accepted a non-existent target"
        return 1
    fi
}

test_stdx_numeric_patch_selection() {
    local assets expected actual status
    assert_function __cjman_pick_stdx_asset || return 1
    assets=$(printf '%s\n' \
        'cangjie-stdx-linux-x64-1.0.1.1.zip	https://example.invalid/stdx-1.0.1.1.zip' \
        'cangjie-stdx-linux-x64-1.0.1.2.zip	https://example.invalid/stdx-1.0.1.2.zip' \
        'cangjie-stdx-linux-aarch64-1.0.1.99.zip	https://example.invalid/wrong-target.zip' \
        'cangjie-stdx-linux-x64-1.0.10.99.zip	https://example.invalid/wrong-sdk.zip' \
        'cangjie-stdx-linux-x64-1.0.1.10.zip	https://example.invalid/stdx-1.0.1.10.zip')
    expected='cangjie-stdx-linux-x64-1.0.1.10.zip	https://example.invalid/stdx-1.0.1.10.zip'

    actual=$(printf '%s\n' "$assets" |
        __cjman_pick_stdx_asset "1.0.1" "linux-x64")
    status=$?
    if [ "$status" -ne 0 ]; then
        fail "__cjman_pick_stdx_asset failed with status $status"
        return 1
    fi
    assert_equal "$expected" "$actual" \
        "stdx patch selection must compare .1/.2/.10 numerically"
}

test_stdx_no_match_fails() {
    local status
    assert_function __cjman_pick_stdx_asset || return 1
    printf '%s\n' \
        'cangjie-stdx-linux-x64-1.0.10.1.zip	https://example.invalid/stdx.zip' |
        __cjman_pick_stdx_asset "1.0.1" "linux-x64" >/dev/null 2>&1
    status=$?
    if [ "$status" -eq 0 ]; then
        fail "stdx selector accepted an asset for a different SDK version"
        return 1
    fi
}

test_install_directories_are_isolated() {
    local native native_aarch64 android ohos ohos_arm32
    assert_function __cjman_install_dir || return 1
    native=$(__cjman_install_dir "1.1.3" "linux" "x64" "native" "x64") ||
        return 1
    native_aarch64=$(__cjman_install_dir \
        "1.1.3" "linux" "aarch64" "native" "aarch64") || return 1
    android=$(__cjman_install_dir "1.1.3" "linux" "x64" "android" "aarch64") ||
        return 1
    ohos=$(__cjman_install_dir "1.1.3" "linux" "x64" "ohos" "aarch64") ||
        return 1
    ohos_arm32=$(__cjman_install_dir \
        "1.1.3" "linux" "x64" "ohos" "arm32") || return 1

    assert_equal \
        "$CJMAN_HOME/bundles/cangjie-1.1.3-linux-x64-native-x64" \
        "$native" "native install directory lost host identity" || return 1
    assert_equal \
        "$CJMAN_HOME/bundles/cangjie-1.1.3-linux-aarch64-native-aarch64" \
        "$native_aarch64" \
        "native install directory lost host architecture" || return 1
    assert_equal \
        "$CJMAN_HOME/bundles/cangjie-1.1.3-linux-x64-android-aarch64" \
        "$android" "Android install directory lost target identity" || return 1
    assert_equal \
        "$CJMAN_HOME/bundles/cangjie-1.1.3-linux-x64-ohos-aarch64" \
        "$ohos" "OpenHarmony install directory lost target identity" || return 1
    assert_equal \
        "$CJMAN_HOME/bundles/cangjie-1.1.3-linux-x64-ohos-arm32" \
        "$ohos_arm32" \
        "OpenHarmony install directory lost target architecture" || return 1
    assert_not_equal "$native" "$android" || return 1
    assert_not_equal "$native" "$native_aarch64" || return 1
    assert_not_equal "$native" "$ohos" || return 1
    assert_not_equal "$android" "$ohos" || return 1
    assert_not_equal "$ohos" "$ohos_arm32"
}

test_windows_cross_target_directory() {
    local actual
    assert_function __cjman_install_dir || return 1
    actual=$(__cjman_install_dir \
        "1.1.3" "windows" "x64" "android" "aarch64") || return 1
    assert_equal \
        "$CJMAN_HOME/bundles/cangjie-1.1.3-windows-x64-android-aarch64" \
        "$actual"
}

test_legacy_native_install_fallback() {
    local legacy resolved
    CANGJIE_BUNDLES="$TEST_TMP/legacy-layout/bundles"
    legacy="$CANGJIE_BUNDLES/cangjie-1.0.5"
    mkdir -p "$legacy" || return 1
    printf 'return 0\n' > "$legacy/envsetup.sh" || return 1

    resolved=$(__cjman_resolve_install_dir \
        1.0.5 mac aarch64 native aarch64 1) || return 1
    assert_equal "$legacy" "$resolved" \
        "legacy native SDK is no longer discoverable" || return 1

    resolved=$(__cjman_resolve_install_dir \
        1.0.5 mac x64 native x64 1 0) || return 1
    assert_equal \
        "$CANGJIE_BUNDLES/cangjie-1.0.5-mac-x64-native-x64" \
        "$resolved" "explicit host override reused a legacy native SDK" ||
        return 1

    resolved=$(__cjman_resolve_install_dir \
        1.0.5 mac aarch64 ios aarch64 1) || return 1
    assert_equal \
        "$CANGJIE_BUNDLES/cangjie-1.0.5-mac-aarch64-ios-aarch64" \
        "$resolved" "legacy native SDK leaked into a cross-target lookup"
}

test_nightly_windows_exe_fallback() {
    local version assets selected component_version
    version='1.1.0-alpha.20260510010057'
    assets=$(printf '%s\n' \
        "cangjie-sdk-windows-x64-${version}.exe	https://example.invalid/sdk.exe")

    selected=$(printf '%s\n' "$assets" |
        __cjman_pick_nightly_sdk windows x64 native x64) || return 1
    component_version=$(__cjman_nightly_sdk_version \
        "${selected%%	*}" windows x64 native x64) || return 1

    assert_equal "cangjie-sdk-windows-x64-${version}.exe" \
        "${selected%%	*}" "EXE-only Windows Nightly was rejected" || return 1
    assert_equal "exe" "${selected##*	}" \
        "EXE-only Windows Nightly has the wrong archive format" || return 1
    assert_equal "$version" "$component_version" \
        "could not derive the SDK build version from an EXE asset" || return 1

    assets=$(printf '%s\n' \
        "cangjie-sdk-windows-x64-${version}.exe	https://example.invalid/sdk.exe" \
        "cangjie-sdk-windows-x64-${version}.zip	https://example.invalid/sdk.zip")
    selected=$(printf '%s\n' "$assets" |
        __cjman_pick_nightly_sdk windows x64 native x64) || return 1
    assert_equal "cangjie-sdk-windows-x64-${version}.zip" \
        "${selected%%	*}" "Nightly selector did not prefer ZIP over EXE"
}

test_nightly_uses_enumerated_asset_names() {
    local tag json assets sdk component_version frontend stdx
    tag='1.3.0-alpha.20260726010034'
    json='{"tag_name":"1.3.0-alpha.20260726010034","assets":['
    json="${json}"'{"type": "attach", "name":"cangjie-sdk-windows-x64-1.3.0-alpha.20260725010034.zip", "browser_download_url":"https://api.invalid/sdk"},'
    json="${json}"'{"name":"cangjie-frontend-windows-x64-1.3.0-alpha.20260725010034.zip","type":"attach","browser_download_url": "https://api.invalid/frontend"},'
    json="${json}"'{"browser_download_url":"https://api.invalid/stdx-1", "type":"attach", "name":"cangjie-stdx-windows-x64-1.3.0-alpha.20260725010034.1.zip"},'
    json="${json}"'{"browser_download_url":"https://api.invalid/wrong-build", "type":"attach", "name":"cangjie-stdx-windows-x64-1.3.0-alpha.20260724010034.99.zip"},'
    json="${json}"'{"browser_download_url":"https://api.invalid/stdx-10", "type":"attach", "name":"cangjie-stdx-windows-x64-1.3.0-alpha.20260725010034.10.zip"}]}'

    assets=$(__cjman_nightly_assets "$tag" "$json") || return 1
    sdk=$(printf '%s\n' "$assets" |
        __cjman_pick_nightly_sdk windows x64 native x64) || return 1
    component_version=$(__cjman_nightly_sdk_version \
        "${sdk%%	*}" windows x64 native x64) || return 1
    frontend=$(printf '%s\n' "$assets" |
        __cjman_pick_nightly_frontend windows x64 "$component_version") ||
        return 1
    stdx=$(printf '%s\n' "$assets" |
        __cjman_pick_nightly_stdx windows-x64 "$component_version") ||
        return 1

    assert_equal '1.3.0-alpha.20260725010034' "$component_version" \
        "Nightly SDK build version was derived from the release tag" || return 1
    assert_equal \
        'cangjie-sdk-windows-x64-1.3.0-alpha.20260725010034.zip' \
        "${sdk%%	*}" "Nightly SDK name was synthesized from its tag" || return 1
    assert_equal \
        'cangjie-frontend-windows-x64-1.3.0-alpha.20260725010034.zip' \
        "${frontend%%	*}" "Nightly frontend name was synthesized from its tag" || return 1
    assert_equal \
        'cangjie-stdx-windows-x64-1.3.0-alpha.20260725010034.10.zip' \
        "${stdx%%	*}" \
        "Nightly stdx did not match the SDK build and highest numeric patch" || return 1
    case "$sdk" in
        *"https://gitcode.com/Cangjie/nightly_build/releases/download/${tag}/"*)
            ;;
        *)
            fail "Nightly URL did not combine the release tag with the actual asset name"
            return 1
            ;;
    esac
}

test_path_cleanup_respects_directory_boundary() {
    local root original expected actual deduped
    root='/opt/cangjie-1.0.1'
    original="/usr/bin:${root}/bin:/opt/cangjie-1.0.10/bin:${root}:/bin"
    expected='/usr/bin:/opt/cangjie-1.0.10/bin:/bin'
    actual=$(__cjman_strip_root_from_path "$original" "$root") || return 1
    assert_equal "$expected" "$actual" \
        "PATH cleanup removed a different version with the same prefix" || return 1
    deduped=$(__cjman_dedupe_path '/usr/bin:/home/test/.cjpm/bin:/bin:/home/test/.cjpm/bin') ||
        return 1
    assert_equal '/usr/bin:/home/test/.cjpm/bin:/bin' "$deduped" \
        "PATH cleanup retained duplicate .cjpm/bin entries"
}

test_native_arch_must_match_host() {
    local status
    status=0
    CJMAN_HOST_OS=linux CJMAN_HOST_ARCH=x64 \
        __cjman_parse_target_options --target native --target-arch arm32 \
        >/dev/null 2>&1 || status=$?
    if [ "$status" -eq 0 ]; then
        fail "native arm32 was accepted for an x64 host"
        return 1
    fi
}

test_unchecksummed_cache_self_heals() {
    local root payload valid destination output result
    root="$TEST_TMP/cache-recovery"
    payload="$root/payload"
    valid="$root/valid.tar.gz"
    CANGJIE_BUNDLES="$root/bundles"
    destination="$CANGJIE_BUNDLES/downloads/nightly.tar.gz"
    mkdir -p "$payload" "$CANGJIE_BUNDLES/downloads" || return 1
    printf 'valid\n' > "$payload/file.txt" || return 1
    tar -czf "$valid" -C "$payload" . || return 1
    printf 'truncated cache\n' > "$destination" || return 1

    curl() {
        output=''
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --output)
                    output=$2
                    shift 2
                    ;;
                *)
                    shift
                    ;;
            esac
        done
        [ -n "$output" ] || return 1
        cp "$valid" "$output"
    }

    result=$(__cjman_download \
        'https://example.invalid/nightly.tar.gz' \
        'nightly.tar.gz' '' 2>/dev/null) || return 1
    assert_equal "$destination" "$result" \
        "cache recovery returned the wrong path" || return 1
    tar -tzf "$destination" >/dev/null 2>&1 ||
        fail "invalid cached Nightly archive was not replaced"
}

test_stdx_upgrades_existing_patch() {
    local release installed
    CANGJIE_BUNDLES="$TEST_TMP/stdx-upgrade/bundles"
    release=$(__cjman_install_dir 1.0.1 linux x64 native x64) || return 1
    mkdir -p "$release/stdx" || return 1
    printf 'return 0\n' > "$release/envsetup.sh" || return 1
    printf 'old\n' > "$release/stdx/old.txt" || return 1
    __cjman_write_marker "$release" 1.0.1 lts linux x64 native x64 \
        sdk.tar.gz '' 1.0.1.1 linux-x64 || return 1

    __cjman_resolve_stable_alias() {
        printf '1.0.1\n'
    }
    __cjman_fetch_catalog() {
        printf 'version\tchannel\tdisplay_name\tpublished_at\n'
        printf '1.0.1\tLTS\tCangjie 1.0.1\t2025-08-22\n'
    }
    __cjman_find_stdx_asset() {
        printf 'cangjie-stdx-linux-x64-1.0.1.2.zip\thttps://example.invalid/stdx.zip\n'
    }
    __cjman_download() {
        printf '%s/fake.zip\n' "$TEST_TMP"
    }
    __cjman_extract_archive() {
        printf 'new\n' > "$3/new.txt"
    }

    __cjman_install_stdx 1.0.1 \
        --host-os linux --host-arch x64 \
        --target native --target-arch x64 >/dev/null 2>&1 || return 1
    [ ! -e "$release/stdx/old.txt" ] ||
        fail "old stdx payload remained after an upgrade" || return 1
    [ -f "$release/stdx/new.txt" ] ||
        fail "new stdx payload was not installed" || return 1
    installed=$(__cjman_marker_value "$release" stdx_version) || return 1
    assert_equal '1.0.1.2' "$installed" \
        "stdx marker was not upgraded to the highest patch"
}

test_activation_failure_restores_environment() {
    local release status
    CANGJIE_BUNDLES="$TEST_TMP/activation-rollback/bundles"
    release=$(__cjman_install_dir 9.9.9 linux x64 native x64) || return 1
    mkdir -p "$release" || return 1
    {
        printf 'PATH=/broken; export PATH\n'
        printf 'LD_LIBRARY_PATH=/broken; export LD_LIBRARY_PATH\n'
        printf 'DYLD_LIBRARY_PATH=/broken; export DYLD_LIBRARY_PATH\n'
        printf 'CANGJIE_HOME=/broken; export CANGJIE_HOME\n'
        printf 'SDKROOT=/broken; export SDKROOT\n'
        printf 'return 7\n'
    } > "$release/envsetup.sh" || return 1

    __cjman_resolve_stable_alias() {
        printf '9.9.9\n'
    }
    CJMAN_HOST_OS=linux
    CJMAN_HOST_ARCH=x64
    PATH='/old/sdk/bin:/usr/bin:/bin'
    LD_LIBRARY_PATH='/old/sdk/lib:/usr/lib'
    DYLD_LIBRARY_PATH='/old/sdk/lib:/usr/lib'
    CANGJIE_HOME='/old/sdk'
    SDKROOT='/old/sdkroot'
    CJMAN_ACTIVE_ROOT='/old/sdk'
    CJMAN_STDX_ROOT='/old/sdk/stdx'
    export CJMAN_HOST_OS CJMAN_HOST_ARCH PATH LD_LIBRARY_PATH DYLD_LIBRARY_PATH
    export CANGJIE_HOME SDKROOT CJMAN_ACTIVE_ROOT CJMAN_STDX_ROOT

    status=0
    __cjman_use 9.9.9 >/dev/null 2>&1 || status=$?
    assert_equal 7 "$status" "activation returned the wrong failure status" || return 1
    assert_equal '/old/sdk/bin:/usr/bin:/bin' "$PATH" "PATH was not restored" || return 1
    assert_equal '/old/sdk/lib:/usr/lib' "$LD_LIBRARY_PATH" \
        "LD_LIBRARY_PATH was not restored" || return 1
    assert_equal '/old/sdk/lib:/usr/lib' "$DYLD_LIBRARY_PATH" \
        "DYLD_LIBRARY_PATH was not restored" || return 1
    assert_equal '/old/sdk' "$CANGJIE_HOME" "CANGJIE_HOME was not restored" || return 1
    assert_equal '/old/sdkroot' "$SDKROOT" "SDKROOT was not restored" || return 1
    assert_equal '/old/sdk' "$CJMAN_ACTIVE_ROOT" \
        "CJMAN_ACTIVE_ROOT was not restored" || return 1
    assert_equal '/old/sdk/stdx' "$CJMAN_STDX_ROOT" \
        "CJMAN_STDX_ROOT was not restored"
}

test_stale_lock_is_recovered() {
    local lock owner
    lock="$TEST_TMP/stale-install.lock"
    mkdir "$lock" || return 1
    printf '99999999\n' > "$lock/pid" || return 1
    __cjman_acquire_lock "$lock" 2>/dev/null || return 1
    owner=$(sed -n '1p' "$lock/pid") || return 1
    assert_equal "$$" "$owner" "stale lock did not receive the current owner" || return 1
    __cjman_release_lock "$lock" || return 1
    [ ! -e "$lock" ] || fail "released install lock still exists"
}

printf 'TAP version 13\n'
run_test "source is override-safe and only exports cjman" \
    test_source_and_namespace
run_test "normalizes Linux, macOS, MinGW, MSYS, and Cygwin" \
    test_os_normalization
run_test "normalizes all supported architecture aliases" \
    test_arch_normalization
run_test "resolves latest, LTS, STS, and exact versions" \
    test_stable_aliases
run_test "selects an exact native SDK row from v2 TSV" \
    test_stable_sdk_exact_native_selection
run_test "selects Windows zip instead of the exe installer" \
    test_stable_sdk_windows_prefers_zip
run_test "selects a macOS aarch64 native SDK row" \
    test_stable_sdk_selects_mac_aarch64_host
run_test "selects an exact cross-target SDK with any target arch" \
    test_stable_sdk_matches_cross_target_and_any_arch
run_test "rejects a missing stable SDK target" \
    test_stable_sdk_no_exact_match_fails
run_test "selects the highest numeric stdx patch" \
    test_stdx_numeric_patch_selection
run_test "rejects stdx assets for a different SDK" \
    test_stdx_no_match_fails
run_test "isolates native, Android, and OpenHarmony installs" \
    test_install_directories_are_isolated
run_test "includes Windows host identity in cross-target installs" \
    test_windows_cross_target_directory
run_test "keeps legacy native SDKs discoverable without cross-target reuse" \
    test_legacy_native_install_fallback
run_test "uses enumerated names for historical Nightly assets" \
    test_nightly_uses_enumerated_asset_names
run_test "supports an EXE-only Windows Nightly and still prefers ZIP" \
    test_nightly_windows_exe_fallback
run_test "cleans PATH only within the active SDK root" \
    test_path_cleanup_respects_directory_boundary
run_test "rejects a native target architecture that differs from the host" \
    test_native_arch_must_match_host
run_test "replaces an invalid unchecksummed Nightly cache" \
    test_unchecksummed_cache_self_heals
run_test "upgrades an existing stdx installation to the highest patch" \
    test_stdx_upgrades_existing_patch
run_test "restores the previous shell after activation failure" \
    test_activation_failure_restores_environment
run_test "recovers a lock left by a dead process" \
    test_stale_lock_is_recovered

printf '1..%s\n' "$TESTS_RUN"
if [ "$TESTS_FAILED" -ne 0 ]; then
    printf '# %s of %s tests failed\n' "$TESTS_FAILED" "$TESTS_RUN" >&2
    exit 1
fi

printf '# all %s tests passed\n' "$TESTS_RUN"
