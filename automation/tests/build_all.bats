#!/usr/bin/env bats
# Critical tests for automation/build_all.sh
#
# Requires BATS: https://github.com/bats-core/bats-core
#   dnf install bats   OR   git clone --depth 1 https://github.com/bats-core/bats-core tests/bats-core
#
# Run: bats tests/build_all.bats

SCRIPT="$BATS_TEST_DIRNAME/../build_all.sh"

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    MOCK_BIN="$TEST_TMPDIR/bin"
    FIXTURE_ROOT="$TEST_TMPDIR/repo"
    export INVOCATION_LOG="$TEST_TMPDIR/invocations.log"
    export BATS_TMPDIR="$TEST_TMPDIR"

    mkdir -p "$MOCK_BIN"
    mkdir -p "$FIXTURE_ROOT/publish/rocky/8"
    mkdir -p "$FIXTURE_ROOT/publish/rocky/9"
    mkdir -p "$FIXTURE_ROOT/publish/rocky/10"
    mkdir -p "$FIXTURE_ROOT/daisy"

    # Minimal wf.json fixtures — content doesn't matter, daisy is mocked.
    touch "$FIXTURE_ROOT/publish/rocky/8/rocky_linux_8.wf.json"
    touch "$FIXTURE_ROOT/publish/rocky/9/rocky_linux_9.wf.json"
    touch "$FIXTURE_ROOT/publish/rocky/10/rocky_linux_10.wf.json"

    export PATH="$MOCK_BIN:$PATH"
    export REPO_ROOT="$FIXTURE_ROOT"
    export LOG_DIR="$TEST_TMPDIR/logs"
    # Never fall through to installed cloud/container commands, even in tests
    # that intentionally omit a specialised mock.
    for tool in gcloud daisy podman; do
        printf '#!/bin/bash\necho "UNEXPECTED %s $*" >> "$INVOCATION_LOG"\nexit 99\n' "$tool" > "$MOCK_BIN/$tool"
        chmod +x "$MOCK_BIN/$tool"
    done
    _mock_gcloud_pass
    mkdir -p "$TEST_TMPDIR/creds"
    printf '{"type":"authorized_user"}\n' > "$TEST_TMPDIR/creds/adc.json"
    export GOOGLE_APPLICATION_CREDENTIALS="$TEST_TMPDIR/creds/adc.json"
    export CLOUDSDK_CONFIG="$TEST_TMPDIR/creds"
    for v in 8 9 10; do
        cp "$BATS_TEST_DIRNAME/../../publish/rocky/$v/rocky_linux_$v.publish.json" "$FIXTURE_ROOT/publish/rocky/$v/rocky_linux_$v.publish.json"
    done
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

# ---------------------------------------------------------------------------
# Mock helpers
# ---------------------------------------------------------------------------

# Mock daisy that always succeeds, writes a valid serial log URL to stdout,
# and records "CWD args" to INVOCATION_LOG.
_mock_daisy_pass() {
    cat > "$MOCK_BIN/daisy" <<'MOCK'
#!/bin/bash
echo "$PWD $*" >> "$INVOCATION_LOG"
wf=$(basename "${@: -1}" .wf.json)
echo "[${wf}]: CreateInstances: Streaming instance \"inst-build-${wf}-abc\" serial port 1 output to https://storage.cloud.google.com/test-bucket/daisy/user/daisy-${wf}/logs/inst-build-${wf}-abc-serial-port1.log"
echo 'CreateImages: Creating image "rocky-linux-8-v1234567890"'
exit 0
MOCK
    chmod +x "$MOCK_BIN/daisy"
}

# Mock daisy that fails with exit 1 for $FAILING_WF on its first call only.
# Subsequent calls (retries) succeed. Uses a per-workflow count file.
_mock_daisy_fail_once() {
    cat > "$MOCK_BIN/daisy" <<'MOCK'
#!/bin/bash
wf=$(basename "${@: -1}" .wf.json)
count_file="$BATS_TMPDIR/count_${wf}"
count=$(cat "$count_file" 2>/dev/null || echo 0)
count=$((count + 1))
echo $count > "$count_file"
echo "$PWD $*" >> "$INVOCATION_LOG"
if [[ "$wf" == "$FAILING_WF" && $count -eq 1 ]]; then
    exit 1
fi
echo "[${wf}]: CreateInstances: Streaming instance \"inst-build-${wf}-abc\" serial port 1 output to https://storage.cloud.google.com/test-bucket/daisy/user/daisy-${wf}/logs/inst-build-${wf}-abc-serial-port1.log"
echo 'CreateImages: Creating image "rocky-linux-8-v1234567890"'
exit 0
MOCK
    chmod +x "$MOCK_BIN/daisy"
}

# Mock daisy that always fails (no output, exit 1).
_mock_daisy_always_fail() {
    cat > "$MOCK_BIN/daisy" <<'MOCK'
#!/bin/bash
echo "$PWD $*" >> "$INVOCATION_LOG"
exit 1
MOCK
    chmod +x "$MOCK_BIN/daisy"
}

# Mock gcloud that handles both serial log and daisy log requests.
_mock_gcloud_pass() {
    cat > "$MOCK_BIN/gcloud" <<'MOCK'
#!/bin/bash
echo "gcloud $*" >> "$INVOCATION_LOG"
if [[ "$*" == *"serial-port1.log"* ]]; then
    echo "Installation complete"
elif [[ "$*" == *'images describe'* ]]; then
    if [[ "$*" == *'--quiet'* && "${IMAGE_EXISTS:-}" != yes ]]; then
        project=gce-ciq-images
        for arg in "$@"; do [[ "$arg" != --project=* ]] || project=${arg#--project=}; done
        echo "The resource 'projects/$project/global/images/$4' was not found" >&2
        exit 1
    fi
    if [[ "${VERIFY_FAIL:-}" == yes ]]; then echo '{}'; exit 0; fi
    project=gce-ciq-images
    for arg in "$@"; do [[ "$arg" != --project=* ]] || project=${arg#--project=}; done
    if [[ -n "${READBACK_SOURCE:-}" ]]; then
        printf '{"name":"%s","selfLink":"https://www.googleapis.com/compute/v1/projects/%s/global/images/%s","id":"123456","status":"READY","rawDisk":{"source":"%s"}}\n' "$4" "$project" "$4" "$READBACK_SOURCE"
    else
    printf '{"name":"%s","selfLink":"https://www.googleapis.com/compute/v1/projects/%s/global/images/%s","id":"123456","status":"READY"}\n' "$4" "$project" "$4"
    fi
elif [[ "$*" == *"daisy.log"* ]]; then
    echo 'CreateImages: Creating image "rocky-linux-8-v1234567890"'
fi
exit 0
MOCK
    chmod +x "$MOCK_BIN/gcloud"
}

# Mock podman that always succeeds and records its args.
_mock_podman_pass() {
    cat > "$MOCK_BIN/podman" <<'MOCK'
#!/bin/bash
echo "podman $*" >> "$INVOCATION_LOG"
exit 0
MOCK
    chmod +x "$MOCK_BIN/podman"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "production GPU publication uses template target for lookup readback and mixed summary" {
    gpu=rocky_linux_9_optimized_gcp_nvidia_latest
    cp "$BATS_TEST_DIRNAME/../../publish/rocky/9/$gpu.publish.json" "$FIXTURE_ROOT/publish/rocky/9/"
    touch "$FIXTURE_ROOT/publish/rocky/9/$gpu.wf.json"
    _mock_podman_pass
    run bash "$SCRIPT" --versions 9 --source-version v123 --environment prod --yes
    [ "$status" -eq 0 ]
    grep -q "images describe rocky-linux-9-optimized-gcp-nvidia-latest-.*--project=rocky-linux-accelerator-cloud --quiet" "$INVOCATION_LOG"
    grep -q "images describe rocky-linux-9-optimized-gcp-nvidia-latest-.*--project=rocky-linux-accelerator-cloud --format=json" "$INVOCATION_LOG"
    grep -qx 'TARGET_PROJECT=rocky-linux-accelerator-cloud' "$LOG_DIR/results/$gpu.result"
    python3 - "$LOG_DIR/summary.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
assert s['options']['target_project'] is None
assert s['options']['target_projects'] == ['rocky-linux-accelerator-cloud', 'rocky-linux-cloud']
by_name = {w['name']: w for w in s['workflows']}
assert by_name['rocky_linux_9']['target_project'] == 'rocky-linux-cloud'
w = by_name['rocky_linux_9_optimized_gcp_nvidia_latest']
assert w['target_project'] == 'rocky-linux-accelerator-cloud'
assert '/projects/rocky-linux-accelerator-cloud/' in w['publish']['images'][0]['selfLink']
PY
}

@test "all actual publisher templates resolve literal test and production targets" {
    run python3 - "$BATS_TEST_DIRNAME/.." <<'PY'
import importlib.util, pathlib, sys
root = pathlib.Path(sys.argv[1]).resolve()
spec = importlib.util.spec_from_file_location('data', root / 'build_all_data.py')
data = importlib.util.module_from_spec(spec)
spec.loader.exec_module(data)
paths = sorted((root.parent / 'publish/rocky').glob('*/*.publish.json'))
assert len(paths) == 25
for path in paths:
    assert data.target_project(path, 'test') == 'gce-ciq-images', path
    expected = 'rocky-linux-accelerator-cloud' if '_nvidia_' in path.name else 'rocky-linux-cloud'
    assert data.target_project(path, 'prod') == expected, path
PY
    [ "$status" -eq 0 ]
}

@test "missing dynamic duplicate or unsupported publisher metadata fails before approval and cloud" {
    file="$FIXTURE_ROOT/publish/rocky/8/rocky_linux_8.publish.json"
    for metadata in \
        '{"Images":[]}' \
        '{"PublishProject":"gce-ciq-images","PublishProject":"rocky-linux-cloud"}' \
        '{"PublishProject":{{$work_project}}}' \
        '{"PublishProject":"rocky-{{$time}}-cloud"}' \
        '{{if .environment}}{"PublishProject":"rocky-linux-cloud"}{{end}}' \
        '{{if eq .environment "test" -}}{"PublishProject":"gce-ciq-images"}{{else}}{"PublishProject":"rocky-linux-cloud"}{{end}}'; do
        printf '%s\n' "$metadata" > "$file"
        run bash "$SCRIPT" --versions 8 --source-version v123 --environment prod
        [ "$status" -ne 0 ]
        [[ "$output" == *'data validation failed'* ]]
        [ ! -e "$INVOCATION_LOG" ]
        [ ! -e "$LOG_DIR" ]
    done
    rm "$file"
    run bash "$SCRIPT" --versions 8 --dry-run
    [ "$status" -ne 0 ]
    [ ! -e "$INVOCATION_LOG" ]
}

@test "production GPU skip and dryrun use the selected template project" {
    gpu=rocky_linux_9_optimized_gcp_nvidia_latest
    cp "$BATS_TEST_DIRNAME/../../publish/rocky/9/$gpu.publish.json" "$FIXTURE_ROOT/publish/rocky/9/"
    touch "$FIXTURE_ROOT/publish/rocky/9/$gpu.wf.json"
    run bash "$SCRIPT" --versions 9 --workflows "$gpu" --source-version v123 --environment prod --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *'[target]  rocky-linux-accelerator-cloud'* ]]
    [ ! -e "$INVOCATION_LOG" ]
    run bash -c "printf 'n\\n' | script -qec \"bash '$SCRIPT' --versions 9 --workflows '$gpu' --source-version v123 --environment prod\" /dev/null"
    [ "$status" -ne 0 ]
    [[ "$output" == *'target=rocky-linux-accelerator-cloud  source=v123  publish=v'* ]]
    [ ! -e "$INVOCATION_LOG" ]
    export IMAGE_EXISTS=yes
    run bash "$SCRIPT" --versions 9 --workflows "$gpu" --source-version v123 --environment prod --yes --if-image-exists skip
    [ "$status" -eq 0 ]
    grep -q -- '--project=rocky-linux-accelerator-cloud --quiet' "$INVOCATION_LOG"
    ! grep -q 'podman' "$INVOCATION_LOG" || return 1
    grep -qx 'PUBLISH_REASON=existing-image-unverified' "$LOG_DIR/results/$gpu.result"
    python3 - "$LOG_DIR/summary.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
assert s['options']['target_project'] == 'rocky-linux-accelerator-cloud'
assert s['options']['target_projects'] == ['rocky-linux-accelerator-cloud']
assert s['workflows'][0]['target_project'] == 'rocky-linux-accelerator-cloud'
PY
}

@test "invalid options fail with diagnostics before cloud access" {
    for args in '--versions 7' '--versions 8,' '--versions ,8' '--versions 8,8' '--workflows absent' '--workflows rocky_linux_9 --versions 8' '--retries -1' '--retries 1+1' '--retries 9999999999999999999999' '--source-version nope' '--versions' '--source-results' '--workflows' '--retries' '--environment' '--if-image-exists' '--source-version'; do
        run bash "$SCRIPT" $args --dry-run
        [ "$status" -ne 0 ]
        [[ "$output" == *'ERROR:'* ]]
        [ ! -e "$INVOCATION_LOG" ]
    done
}

@test "help succeeds without credentials or cloud" {
    run bash "$SCRIPT" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *'--yes'* ]]
    [ ! -e "$INVOCATION_LOG" ]
}

@test "daisy is invoked with correct zone, workflow file, and working directory" {
    _mock_daisy_pass
    _mock_gcloud_pass
    _mock_podman_pass

    run bash "$SCRIPT" --versions 8

    [ "$status" -eq 0 ]
    # Invoked from the rocky/8 publish directory
    grep -q "$FIXTURE_ROOT/publish/rocky/8" "$INVOCATION_LOG"
    # Invoked with the correct zone for rocky 8
    grep -q "\-zone us-central1-b" "$INVOCATION_LOG"
    # Invoked with the correct workflow filename
    grep -q "rocky_linux_8.wf.json" "$INVOCATION_LOG"
}

@test "only the failed workflow is retried; the passing workflow runs exactly once" {
    export FAILING_WF="rocky_linux_8"
    _mock_daisy_fail_once
    _mock_gcloud_pass
    _mock_podman_pass

    run bash "$SCRIPT" --versions 8,9 --retries 1

    [ "$status" -eq 0 ]
    # rocky_linux_8 failed then was retried — expect 2 invocations
    count=$(grep -c "rocky_linux_8.wf.json" "$INVOCATION_LOG")
    [ "$count" -eq 2 ]
    # rocky_linux_9 passed first time — expect exactly 1 invocation
    count=$(grep -c "rocky_linux_9.wf.json" "$INVOCATION_LOG")
    [ "$count" -eq 1 ]
}

@test "script exits non-zero and stops after exhausting retries" {
    _mock_daisy_always_fail
    _mock_gcloud_pass

    run bash "$SCRIPT" --versions 8 --retries 2

    # Must exit non-zero when all retries are exhausted
    [ "$status" -ne 0 ]
    # initial attempt + 2 retries = 3 total invocations
    count=$(grep -c "rocky_linux_8.wf.json" "$INVOCATION_LOG")
    [ "$count" -eq 3 ]
    grep -qx 'BUILD_REASON=daisy-exited-1' "$LOG_DIR/results/rocky_linux_8.result"
}

@test "--source-version skips build and invokes publish with the correct version" {
    _mock_daisy_pass
    _mock_podman_pass

    run bash "$SCRIPT" --versions 8 --source-version v1234567890

    [ "$status" -eq 0 ]
    # daisy must never be called
    if [[ -f "$INVOCATION_LOG" ]]; then
        ! grep -q "daisy" "$INVOCATION_LOG" || return 1
    fi
    # podman must be called with the correct source_version
    grep -q "\-source_version v1234567890" "$INVOCATION_LOG"
}

@test "--source-version shows SKIPPED build status in summary" {
    _mock_podman_pass

    run bash "$SCRIPT" --versions 8 --source-version v1234567890

    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIPPED (--source-version)"* ]]
}

@test "--source-version dry-run shows SKIPPED instead of daisy command" {
    run bash "$SCRIPT" --versions 8 --source-version v1234567890 --dry-run

    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIPPED (--source-version=v1234567890)"* ]]
    ! [[ "$output" == *"daisy -zone"* ]] || return 1
}

@test "--skip-publish builds but does not invoke publish" {
    _mock_daisy_pass
    _mock_gcloud_pass
    _mock_podman_pass

    run bash "$SCRIPT" --versions 8 --skip-publish

    [ "$status" -eq 0 ]
    # daisy must be called (build runs normally)
    grep -q "rocky_linux_8.wf.json" "$INVOCATION_LOG"
    # podman must not be called (publish skipped)
    ! grep -q "podman" "$INVOCATION_LOG" || return 1
    [[ "$output" == *"SKIPPED (--skip-publish)"* ]]
}

@test "--skip-publish dry-run shows SKIPPED publish but still shows daisy command" {
    run bash "$SCRIPT" --versions 8 --skip-publish --dry-run

    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIPPED (--skip-publish)"* ]]
    ! [[ "$output" == *"gce_image_publish"* ]] || return 1
    [[ "$output" == *"daisy -zone"* ]]
}

@test "--skip-publish with --source-version rejects no-op" {
    _mock_podman_pass

    run bash "$SCRIPT" --versions 8 --skip-publish --source-version v1234567890

    [ "$status" -ne 0 ]
    [[ "$output" == *'ERROR:'* ]]
    [ ! -e "$INVOCATION_LOG" ]
}

# ---------------------------------------------------------------------------
# --environment tests
# ---------------------------------------------------------------------------

@test "--environment prod requires --source-version" {
    run bash "$SCRIPT" --versions 8 --environment prod

    [ "$status" -ne 0 ]
    [[ "$output" == *"--source-version or --source-results is required when --environment=prod"* ]]
}

@test "--environment prod rejects --if-image-exists=delete" {
    run bash "$SCRIPT" --versions 8 --environment prod --source-version v123 --if-image-exists delete

    [ "$status" -ne 0 ]
    [[ "$output" == *"--if-image-exists=delete is not allowed when --environment=prod"* ]]
}

@test "--environment rejects invalid values" {
    run bash "$SCRIPT" --versions 8 --environment staging

    [ "$status" -ne 0 ]
    [[ "$output" == *"--environment must be one of: test, prod"* ]]
}

@test "--environment prod dry-run shows prod environment without rollout_rate" {
    run bash "$SCRIPT" --versions 8 --source-version v123 --environment prod --dry-run

    [ "$status" -eq 0 ]
    [[ "$output" == *"var:environment=prod"* ]]
    ! [[ "$output" == *"rollout_rate"* ]] || return 1
}

@test "default environment is test with rollout_rate 0 in dry-run" {
    run bash "$SCRIPT" --versions 8 --source-version v123 --dry-run

    [ "$status" -eq 0 ]
    [[ "$output" == *"var:environment=test"* ]]
    [[ "$output" == *"rollout_rate 0"* ]]
}

@test "--environment prod publishes with prod environment and no rollout_rate" {
    _mock_podman_pass

    run bash "$SCRIPT" --versions 8 --source-version v123 --environment prod --yes

    [ "$status" -eq 0 ]
    grep -q "var:environment=prod" "$INVOCATION_LOG"
    ! grep -q "rollout_rate" "$INVOCATION_LOG" || return 1
}

@test "--environment prod aborts when confirmation denied" {
    _mock_podman_pass

    run bash -c "printf 'n\n' | script -qec \"bash '$SCRIPT' --versions 8 --source-version v123 --environment prod\" /dev/null"

    [ "$status" -ne 0 ]
    [[ "$output" == *"Aborted"* ]]
}

@test "--environment prod shows confirmation prompt with workflow details" {
    _mock_podman_pass

    run bash -c "printf 'n\n' | script -qec \"bash '$SCRIPT' --versions 8 --source-version v123 --environment prod\" /dev/null"

    [[ "$output" == *"PRODUCTION PUBLISH"* ]]
    [[ "$output" == *"rocky-linux-cloud"* ]]
    [[ "$output" == *"rocky_linux_8"* ]]
}

@test "source results reject malformed duplicate and failed builds as data" {
    mkdir "$TEST_TMPDIR/source"
    for content in $'BUILD_VERSION=v123\nBUILD_STATUS=FAIL' $'BUILD_VERSION=v123\nBUILD_VERSION=v456\nBUILD_STATUS=PASS' $'BUILD_VERSION=v123\nBUILD_STATUS=PASS\nBUILD_STATUS=PASS' $'BUILD_VERSION=$(touch BAD)\nBUILD_STATUS=PASS' $'BUILD_VERSION=v123\nBUILD_STATUS=PASS\nnot-a-field' $'BUILD_VERSION=v123'; do
        printf '%s\n' "$content" > "$TEST_TMPDIR/source/rocky_linux_8.result"
        run bash "$SCRIPT" --versions 8 --source-results "$TEST_TMPDIR/source" --dry-run
        [ "$status" -ne 0 ]
        [[ "$output" == *'ERROR:'* ]]
        [ ! -e "$INVOCATION_LOG" ]
    done
}

@test "source results permit retry after publish failure preserving literal version" {
    _mock_podman_pass
    mkdir "$TEST_TMPDIR/source"
    printf 'BUILD_STATUS=PASS\nBUILD_VERSION=v000123\nPUBLISH_STATUS=FAIL\n' > "$TEST_TMPDIR/source/rocky_linux_8.result"
    run bash "$SCRIPT" --versions 8 --source-results "$TEST_TMPDIR/source"
    [ "$status" -eq 0 ]
    grep -q -- '-source_version v000123' "$INVOCATION_LOG"
}

@test "existing prod image skip uses target project and is explicitly unverified" {
    export IMAGE_EXISTS=yes
    run bash "$SCRIPT" --versions 8 --source-version v123 --environment prod --yes --if-image-exists skip
    [ "$status" -eq 0 ]
    grep -q -- '--project=rocky-linux-cloud' "$INVOCATION_LOG"
    grep -qx 'BUILD_STATUS=SKIPPED' "$LOG_DIR/results/rocky_linux_8.result"
    grep -qx 'PUBLISH_REASON=existing-image-unverified' "$LOG_DIR/results/rocky_linux_8.result"
    ! grep -q podman "$INVOCATION_LOG" || return 1
}

@test "image lookup permission errors fail closed without publishing" {
    _mock_podman_pass
    cat > "$MOCK_BIN/gcloud" <<'MOCK'
#!/bin/bash
if [[ "$*" == *'images describe'* ]]; then echo 'PERMISSION_DENIED' >&2; exit 1; fi
exit 0
MOCK
    run bash "$SCRIPT" --versions 8 --source-version v123 --if-image-exists skip
    [ "$status" -ne 0 ]
    ! grep -q podman "$INVOCATION_LOG" || return 1
    grep -qx 'PUBLISH_REASON=image-lookup-failed' "$LOG_DIR/results/rocky_linux_8.result"
}

@test "image deletion failure is fatal" {
    _mock_podman_pass
    cat > "$MOCK_BIN/gcloud" <<'MOCK'
#!/bin/bash
if [[ "$*" == *'images delete'* ]]; then exit 1; fi
exit 0
MOCK
    run bash "$SCRIPT" --versions 8 --source-version v123 --if-image-exists delete
    [ "$status" -ne 0 ]
    ! grep -q podman "$INVOCATION_LOG" || return 1
    grep -qx 'PUBLISH_REASON=image-delete-failed' "$LOG_DIR/results/rocky_linux_8.result"
}

@test "worker crash produces a complete terminal result" {
    cat > "$MOCK_BIN/daisy" <<'MOCK'
#!/bin/bash
kill -KILL "$PPID"
exit 7
MOCK
    run bash "$SCRIPT" --versions 8 --skip-publish
    [ "$status" -ne 0 ]
    result="$LOG_DIR/results/rocky_linux_8.result"
    [ -f "$result" ]
    grep -qx 'BUILD_STATUS=FAIL' "$result"
    grep -qx 'BUILD_REASON=worker-exited-137' "$result"
    grep -qx 'PUBLISH_STATUS=NOT_ATTEMPTED' "$result"
    grep -q '^BUILD_VERSION=' "$result"
    grep -q '^PUBLISH_ATTEMPTS=0$' "$result"
    [ "$(find "$LOG_DIR/results" -type f | wc -l)" -eq 1 ]
}

@test "publish retries never rebuild and failed publishing retains successful build" {
    _mock_daisy_pass
    cat > "$MOCK_BIN/podman" <<'MOCK'
#!/bin/bash
 echo podman >> "$INVOCATION_LOG"
 exit 4
MOCK
    run bash "$SCRIPT" --versions 8 --retries 2
    [ "$status" -ne 0 ]
    [ "$(grep -c 'rocky_linux_8.wf.json' "$INVOCATION_LOG")" -eq 1 ]
    [ "$(grep -c '^podman' "$INVOCATION_LOG")" -eq 3 ]
    grep -qx 'BUILD_STATUS=PASS' "$LOG_DIR/results/rocky_linux_8.result"
    grep -qx 'BUILD_VERSION=v1234567890' "$LOG_DIR/results/rocky_linux_8.result"
    grep -qx 'PUBLISH_ATTEMPTS=3' "$LOG_DIR/results/rocky_linux_8.result"
    grep -q '^BUILD_REASON=' "$LOG_DIR/results/rocky_linux_8.result"
}

@test "publish success requires verified readback not merely container success" {
    _mock_podman_pass
    export VERIFY_FAIL=yes
    run bash "$SCRIPT" --versions 8 --source-version v123 --retries 0
    [ "$status" -ne 0 ]
    grep -qx 'BUILD_STATUS=SKIPPED' "$LOG_DIR/results/rocky_linux_8.result"
    grep -qx 'PUBLISH_STATUS=FAIL' "$LOG_DIR/results/rocky_linux_8.result"
    grep -qx 'PUBLISH_REASON=publish-verification-failed' "$LOG_DIR/results/rocky_linux_8.result"
}

@test "malformed image readback structures produce controlled errors" {
    helper="${SCRIPT%/*}/build_all_data.py"
    for content in '[]' 'null' '{"name":"image","selfLink":"https://www.googleapis.com/compute/v1/projects/project/global/images/image","id":"1","status":"READY","rawDisk":null}'; do
        printf '%s\n' "$content" > "$TEST_TMPDIR/readback.json"
        run python3 "$helper" verify "$TEST_TMPDIR/readback.json" project image gs://bucket/image.tar.gz
        [ "$status" -ne 0 ]
        [[ "$output" == *'ERROR:'* ]]
        [[ "$output" != *'Traceback'* ]]
    done
}

@test "publisher freezes UTC version and stores actual readback identifier" {
    _mock_podman_pass
    run bash "$SCRIPT" --versions 8 --source-version v000123
    [ "$status" -eq 0 ]
    version="v$(date -u +%Y%m%d)"
    grep -q -- "-publish_version $version" "$INVOCATION_LOG"
    ! grep -q -- '-date_version' "$INVOCATION_LOG" || return 1
    grep -q 'PUBLISHED_IMAGES=.*"id": "123456"' "$LOG_DIR/results/rocky_linux_8.result"
    grep -q "projects/gce-ciq-images/global/images/rocky-linux-8-$version" "$LOG_DIR/results/rocky_linux_8.result"
}

@test "credentials are explicit and publisher mounts WIF file dependencies read-only" {
    _mock_podman_pass
    printf 'OIDC-SECRET' > "$TEST_TMPDIR/creds/subject.jwt"
    printf '{"type":"external_account","credential_source":{"file":"%s/creds/subject.jwt"}}' "$TEST_TMPDIR" > "$GOOGLE_APPLICATION_CREDENTIALS"
    run bash "$SCRIPT" --versions 8 --source-version v123
    [ "$status" -eq 0 ]
    grep -q -- "$GOOGLE_APPLICATION_CREDENTIALS:$GOOGLE_APPLICATION_CREDENTIALS:ro,z" "$INVOCATION_LOG"
    grep -q -- "$TEST_TMPDIR/creds/subject.jwt:$TEST_TMPDIR/creds/subject.jwt:ro,z" "$INVOCATION_LOG"
    ! grep -R -q 'OIDC-SECRET' "$LOG_DIR" || return 1
    ! grep -R -q "$TEST_TMPDIR/creds" "$LOG_DIR" || return 1
}

@test "malformed credential structures fail cleanly before cloud" {
    for content in '[]' 'null' '"credential"' '{"type":"external_account","credential_source":null}' '{"type":"external_account","credential_source":{"file":[]}}'; do
        printf '%s\n' "$content" > "$GOOGLE_APPLICATION_CREDENTIALS"
        run bash "$SCRIPT" --versions 8 --source-version v123
        [ "$status" -ne 0 ]
        [[ "$output" == *'ERROR:'* ]]
        [[ "$output" != *'Traceback'* ]]
        [ ! -e "$INVOCATION_LOG" ]
    done
}

@test "unsupported WIF executable arrangement fails clearly before cloud" {
    printf '{"type":"external_account","credential_source":{"executable":{"command":"danger"}}}' > "$GOOGLE_APPLICATION_CREDENTIALS"
    run bash "$SCRIPT" --versions 8 --source-version v123
    [ "$status" -ne 0 ]
    [[ "$output" == *'unsupported credential arrangement'* ]]
    [ ! -e "$INVOCATION_LOG" ]
}

@test "dryrun has no credential cloud or persistent artifact requirements" {
    unset GOOGLE_APPLICATION_CREDENTIALS
    export CLOUDSDK_CONFIG="$TEST_TMPDIR/absent"
    run bash "$SCRIPT" --versions 8 --source-version v123 --environment prod --dry-run
    [ "$status" -eq 0 ]
    [ ! -d "$LOG_DIR" ]
    [ ! -e "$INVOCATION_LOG" ]
    [[ "$output" != *'/creds'* ]]
}

@test "missing credentials fail before cloud with no paths or contents" {
    unset GOOGLE_APPLICATION_CREDENTIALS
    export CLOUDSDK_CONFIG="$TEST_TMPDIR/absent"
    run bash "$SCRIPT" --versions 8 --skip-publish
    [ "$status" -ne 0 ]
    [[ "$output" == *'credentials'* ]]
    [[ "$output" != *"$CLOUDSDK_CONFIG"* ]]
    [ ! -e "$INVOCATION_LOG" ]
}

@test "JSON summary matches terminal results and safe effective options" {
    _mock_podman_pass
    run bash "$SCRIPT" --versions 8 --source-version v000123 --retries 0
    [ "$status" -eq 0 ]
    python3 - "$LOG_DIR/summary.json" "$LOG_DIR/results/rocky_linux_8.result" <<'PY'
import json, sys
s=json.load(open(sys.argv[1]))
r=dict(line.rstrip('\n').split('=',1) for line in open(sys.argv[2]))
assert s['dry_run'] is False
assert s['options']['versions'] == [8]
assert s['options']['source_version'] == 'v000123'
assert s['options']['retries'] == 0
assert s['options']['environment'] == 'test'
assert s['repo_commit'] is None
assert len(s['workflows']) == 1
w=s['workflows'][0]
assert w['name'] == 'rocky_linux_8'
assert w['build']['status'] == r['BUILD_STATUS'] == 'SKIPPED'
assert w['publish']['status'] == r['PUBLISH_STATUS'] == 'PASS'
assert w['publish']['images'] == json.loads(r['PUBLISHED_IMAGES'])
assert w['source_tarball'] == 'gs://gce-ciq-images-prod-artifacts/rocky-linux-8-v000123.tar.gz'
assert w['publish']['images'][0]['source_verified'] is False
assert 'GOOGLE_APPLICATION_CREDENTIALS' not in json.dumps(s)
PY
}

@test "failed builds report publishing as not attempted not failed" {
    _mock_daisy_always_fail
    run bash "$SCRIPT" --versions 8 --skip-publish --retries 0
    [ "$status" -ne 0 ]
    [[ "$output" == *'Publish: 0 passed, 0 failed, 1 skipped/not-attempted'* ]]
    [[ "$output" == *'- (build failed)'* ]]
}

@test "JSON summary records failed builds and not attempted publishing" {
    _mock_daisy_always_fail
    run bash "$SCRIPT" --versions 8 --skip-publish --retries 0
    [ "$status" -ne 0 ]
    python3 - "$LOG_DIR/summary.json" <<'PY'
import json, sys
s=json.load(open(sys.argv[1]))
w=s['workflows'][0]
assert w['build']['status'] == 'FAIL'
assert w['build']['attempts'] == 1
assert w['publish']['status'] == 'NOT_ATTEMPTED'
assert w['publish']['images'] == []
assert s['cancelled'] is False
PY
}

@test "TERM cancellation kills worker descendants and retains terminal results" {
    cat > "$MOCK_BIN/daisy" <<'MOCK'
#!/bin/bash
bash -c 'trap "" TERM; sleep 60 & echo $! >> "${INVOCATION_LOG}.descendants"; wait' &
echo $! >> "${INVOCATION_LOG}.descendants"
wait
MOCK
    python3 - "$SCRIPT" "$LOG_DIR" "$TEST_TMPDIR" <<'PY'
import json, os, signal, subprocess, sys, time
from pathlib import Path
script, logs, tmp = sys.argv[1:]
pids = []
with open(Path(tmp)/'output','w') as out:
    subprocess_args = ['bash',script,'--versions','8,9','--skip-publish']
    p=subprocess.Popen(subprocess_args, stdout=out, stderr=out, start_new_session=True)
    try:
        deadline=time.monotonic()+8
        while time.monotonic()<deadline:
            f=Path(os.environ['INVOCATION_LOG']+'.descendants')
            if f.exists():
                pids=[int(x) for x in f.read_text().split()]
                if len(pids)==4: break
            time.sleep(.03)
        assert len(pids)==4, (pids, (Path(tmp)/'output').read_text(), str(f))
        p.send_signal(signal.SIGTERM)
        assert p.wait(timeout=8)==143
        for pid in pids:
            stat=Path(f'/proc/{pid}/stat')
            assert not stat.exists() or stat.read_text().split()[2]=='Z', f'descendant {pid} survived'
        s=json.load(open(Path(logs)/'summary.json'))
        assert s['cancelled'] is True
        assert len(s['workflows']) == 2
        assert all(w['build']['status']=='CANCELLED' for w in s['workflows'])
    finally:
        # Clean this isolated session on assertion failure, not other tests.
        for stat in Path('/proc').glob('[0-9]*/stat'):
            try:
                fields=stat.read_text().split()
                if int(fields[5]) == p.pid:
                    os.kill(int(fields[0]), signal.SIGKILL)
            except (OSError, ValueError): pass
        p.wait()
        for pid in pids:
            try: os.kill(pid, signal.SIGKILL)
            except ProcessLookupError: pass
PY
}

@test "serial fetch infrastructure failure never deletes or rebuilds" {
    _mock_daisy_pass
    cat > "$MOCK_BIN/gcloud" <<'MOCK'
#!/bin/bash
echo "gcloud $*" >> "$INVOCATION_LOG"
[[ "$*" != *'storage cat'* ]] || exit 2
exit 0
MOCK
    run bash "$SCRIPT" --versions 8 --skip-publish --retries 2
    [ "$status" -ne 0 ]
    [ "$(grep -c 'rocky_linux_8.wf.json' "$INVOCATION_LOG")" -eq 1 ]
    ! grep -q 'storage rm' "$INVOCATION_LOG" || return 1
    grep -qx 'BUILD_REASON=serial-log-fetch-failed' "$LOG_DIR/results/rocky_linux_8.result"
}

@test "failed tarball deletion is fatal without rebuild" {
    _mock_daisy_pass
    cat > "$MOCK_BIN/gcloud" <<'MOCK'
#!/bin/bash
echo "gcloud $*" >> "$INVOCATION_LOG"
[[ "$*" != *'storage rm'* ]] || exit 2
exit 0
MOCK
    run bash "$SCRIPT" --versions 8 --skip-publish --retries 2
    [ "$status" -ne 0 ]
    [ "$(grep -c 'rocky_linux_8.wf.json' "$INVOCATION_LOG")" -eq 1 ]
    grep -qx 'BUILD_REASON=tarball-delete-failed' "$LOG_DIR/results/rocky_linux_8.result"
}

@test "existing result directory cannot leak stale success into another run" {
    mkdir -p "$LOG_DIR/results"
    printf 'BUILD_STATUS=PASS\nPUBLISH_STATUS=PASS\nBUILD_VERSION=v999\n' > "$LOG_DIR/results/rocky_linux_8.result"
    run bash "$SCRIPT" --versions 8 --skip-publish
    [ "$status" -ne 0 ]
    [[ "$output" == *'already exists'* ]]
    [ ! -e "$INVOCATION_LOG" ]
    grep -qx 'BUILD_VERSION=v999' "$LOG_DIR/results/rocky_linux_8.result"
}

@test "not found image lookup permits publish but unrelated missing errors fail closed" {
    _mock_podman_pass
    # Delegate successful readback only after publication; initial lookup is absent.
    cp "$MOCK_BIN/gcloud" "$MOCK_BIN/gcloud-readback"
    cat > "$MOCK_BIN/gcloud" <<'MOCK'
#!/bin/bash
if [[ "$*" == *'images describe'* ]] && [[ ! -e "$BATS_TMPDIR/published" ]]; then
    echo "ERROR: The resource 'projects/gce-ciq-images/global/images/$4' was not found" >&2
    exit 1
fi
exec "$(dirname "$0")/gcloud-readback" "$@"
MOCK
    cat > "$MOCK_BIN/podman" <<'MOCK'
#!/bin/bash
echo podman >> "$INVOCATION_LOG"
touch "$BATS_TMPDIR/published"
MOCK
    run bash "$SCRIPT" --versions 8 --source-version v123 --if-image-exists skip
    [ "$status" -eq 0 ]
    grep -qx 'PUBLISH_STATUS=PASS' "$LOG_DIR/results/rocky_linux_8.result"
    export LOG_DIR="$TEST_TMPDIR/other-logs"
    cat > "$MOCK_BIN/gcloud" <<'MOCK'
#!/bin/bash
if [[ "$*" == *'images describe'* ]]; then echo 'active account was not found' >&2; exit 1; fi
exit 0
MOCK
    : > "$INVOCATION_LOG"
    run bash "$SCRIPT" --versions 8 --source-version v123 --if-image-exists skip
    [ "$status" -ne 0 ]
    ! grep -q podman "$INVOCATION_LOG" || return 1
}

@test "credential paths and known credential secrets are redacted from publisher artifacts" {
    printf '{"type":"authorized_user","refresh_token":"VERY-SECRET-REFRESH"}' > "$GOOGLE_APPLICATION_CREDENTIALS"
    cat > "$MOCK_BIN/podman" <<'MOCK'
#!/bin/bash
echo "$GOOGLE_APPLICATION_CREDENTIALS"
cat "$GOOGLE_APPLICATION_CREDENTIALS"
exit 1
MOCK
    run bash "$SCRIPT" --versions 8 --source-version v123 --retries 0
    [ "$status" -ne 0 ]
    ! grep -R -q 'VERY-SECRET-REFRESH' "$LOG_DIR" || return 1
    ! grep -R -q "$TEST_TMPDIR/creds" "$LOG_DIR" || return 1
}

@test "vanished credentials do not block summary or final log redaction" {
    printf '{"type":"authorized_user","refresh_token":"EPHEMERAL-SECRET"}' > "$GOOGLE_APPLICATION_CREDENTIALS"
    cat > "$MOCK_BIN/podman" <<'MOCK'
#!/bin/bash
cat "$GOOGLE_APPLICATION_CREDENTIALS"
rm "$GOOGLE_APPLICATION_CREDENTIALS"
exit 0
MOCK
    run bash "$SCRIPT" --versions 8 --source-version v123
    [ "$status" -eq 0 ]
    [ -f "$LOG_DIR/summary.json" ]
    ! grep -R -q 'EPHEMERAL-SECRET' "$LOG_DIR" || return 1
    [[ "$output" != *'Traceback'* ]]
}

@test "successful delete command still requires absence readback before publish" {
    export IMAGE_EXISTS=yes
    _mock_podman_pass
    run bash "$SCRIPT" --versions 8 --source-version v123 --if-image-exists delete
    [ "$status" -ne 0 ]
    ! grep -q '^podman' "$INVOCATION_LOG" || return 1
    grep -qx 'PUBLISH_REASON=image-delete-verification-failed' "$LOG_DIR/results/rocky_linux_8.result"
}

@test "tarball delete needs absence readback before rebuilding" {
    _mock_daisy_pass
    cat > "$MOCK_BIN/gcloud" <<'MOCK'
#!/bin/bash
echo "gcloud $*" >> "$INVOCATION_LOG"
exit 0
MOCK
    run bash "$SCRIPT" --versions 8 --skip-publish --retries 1
    [ "$status" -ne 0 ]
    [ "$(grep -c 'rocky_linux_8.wf.json' "$INVOCATION_LOG")" -eq 1 ]
    grep -qx 'BUILD_REASON=tarball-delete-verification-failed' "$LOG_DIR/results/rocky_linux_8.result"
}

@test "defaults select all three versions and workflows with no mutation" {
    run bash "$SCRIPT" --dry-run
    [ "$status" -eq 0 ]
    for v in 8 9 10; do [[ "$output" == *"[rocky_linux_$v]"* ]]; done
    [ ! -e "$INVOCATION_LOG" ]
    [ ! -d "$LOG_DIR" ]
}

@test "source options are exclusive and empty workflow selections fail before cloud" {
    mkdir "$TEST_TMPDIR/source"
    run bash "$SCRIPT" --versions 8 --source-version v123 --source-results "$TEST_TMPDIR/source"
    [ "$status" -ne 0 ]
    [[ "$output" == *'mutually exclusive'* ]]
    rm "$FIXTURE_ROOT/publish/rocky/8/rocky_linux_8.wf.json"
    run bash "$SCRIPT" --versions 8 --dry-run
    [ "$status" -ne 0 ]
    [[ "$output" == *'no workflows selected'* ]]
    [ ! -e "$INVOCATION_LOG" ]
}

@test "dependencies are operation aware" {
    _mock_podman_pass
    _mock_daisy_pass
    isolated="$TEST_TMPDIR/isolated-bin"
    mkdir "$isolated"
    for cmd in dirname date basename grep cut tail head mkdir mv python3 git cat sleep; do
        ln -s "$(command -v "$cmd")" "$isolated/$cmd"
    done
    ln -s "$MOCK_BIN/gcloud" "$isolated/gcloud"
    ln -s "$MOCK_BIN/podman" "$isolated/podman"
    run env PATH="$isolated" /bin/bash "$SCRIPT" --versions 8 --source-version v123
    [ "$status" -eq 0 ]
    rm "$isolated/podman"
    ln -s "$MOCK_BIN/daisy" "$isolated/daisy"
    export LOG_DIR="$TEST_TMPDIR/build-only"
    run env PATH="$isolated" /bin/bash "$SCRIPT" --versions 8 --skip-publish
    [ "$status" -eq 0 ]
    rm "$isolated/daisy" "$isolated/gcloud"
    run env PATH="$isolated" /bin/bash "$SCRIPT" --versions 8 --dry-run
    [ "$status" -eq 0 ]
}
@test "INT cancellation during publishing retains the completed build" {
    _mock_daisy_pass
    cat > "$MOCK_BIN/podman" <<'MOCK'
#!/bin/bash
bash -c 'trap "" TERM; sleep 60 & echo $! >> "${INVOCATION_LOG}.descendants"; wait' &
echo $! >> "${INVOCATION_LOG}.descendants"
wait
MOCK
    python3 - "$SCRIPT" "$LOG_DIR" "$TEST_TMPDIR" <<'PY'
import json, os, signal, subprocess, sys, time
from pathlib import Path
script, logs, tmp = sys.argv[1:]
pids = []
with open(Path(tmp)/'output','w') as out:
    subprocess_args = ['bash',script,'--versions','8,9']
    p=subprocess.Popen(subprocess_args, stdout=out, stderr=out, start_new_session=True)
    try:
        deadline=time.monotonic()+8
        while time.monotonic()<deadline:
            f=Path(os.environ['INVOCATION_LOG']+'.descendants')
            if f.exists():
                pids=[int(x) for x in f.read_text().split()]
                if len(pids)==4: break
            time.sleep(.03)
        assert len(pids)==4, (pids, (Path(tmp)/'output').read_text(), str(f))
        p.send_signal(signal.SIGINT)
        assert p.wait(timeout=8)==130
        for pid in pids:
            stat=Path(f'/proc/{pid}/stat')
            assert not stat.exists() or stat.read_text().split()[2]=='Z', f'descendant {pid} survived'
        s=json.load(open(Path(logs)/'summary.json'))
        assert s['cancelled'] is True
        assert len(s['workflows']) == 2
        assert all(w['build']['status']=='PASS' and w['publish']['status']=='CANCELLED' for w in s['workflows'])
    finally:
        # Clean this isolated session on assertion failure, not other tests.
        for stat in Path('/proc').glob('[0-9]*/stat'):
            try:
                fields=stat.read_text().split()
                if int(fields[5]) == p.pid:
                    os.kill(int(fields[0]), signal.SIGKILL)
            except (OSError, ValueError): pass
        p.wait()
        for pid in pids:
            try: os.kill(pid, signal.SIGKILL)
            except ProcessLookupError: pass
PY
}

@test "readback checks available source and retains the actual source URL" {
    _mock_podman_pass
    export READBACK_SOURCE='https://storage.googleapis.com/gce-ciq-images-prod-artifacts/rocky-linux-8-v000123.tar.gz'
    run bash "$SCRIPT" --versions 8 --source-version v000123
    [ "$status" -eq 0 ]
    python3 - "$LOG_DIR/summary.json" <<'PY'
import json, os, sys
image=json.load(open(sys.argv[1]))['workflows'][0]['publish']['images'][0]
assert image['source_verified'] is True
assert image['source'] == os.environ['READBACK_SOURCE']
PY
    export LOG_DIR="$TEST_TMPDIR/mismatch"
    export READBACK_SOURCE='gs://wrong-bucket/wrong-version.tar.gz'
    run bash "$SCRIPT" --versions 8 --source-version v000123
    [ "$status" -ne 0 ]
    grep -qx 'PUBLISH_REASON=publish-verification-failed' "$LOG_DIR/results/rocky_linux_8.result"
}

@test "worker crash also terminates its remaining subprocess group" {
    cat > "$MOCK_BIN/daisy" <<'MOCK'
#!/bin/bash
sleep 60 &
echo $! > "${INVOCATION_LOG}.child"
kill -KILL "$PPID"
wait
MOCK
    python3 - "$SCRIPT" "$TEST_TMPDIR" <<'PY'
import os, signal, subprocess, sys
from pathlib import Path
script, tmp=sys.argv[1:]
with open(Path(tmp)/'output','w') as out:
    p=subprocess.Popen(['bash',script,'--versions','8','--skip-publish'],stdout=out,stderr=out,start_new_session=True)
    try:
        assert p.wait(timeout=8) != 0
        pid=int(Path(os.environ['INVOCATION_LOG']+'.child').read_text())
        stat=Path(f'/proc/{pid}/stat')
        assert not stat.exists() or stat.read_text().split()[2]=='Z', f'worker child {pid} survived'
    finally:
        for stat in Path('/proc').glob('[0-9]*/stat'):
            try:
                fields=stat.read_text().split()
                if int(fields[5])==p.pid:
                    os.kill(int(fields[0]),signal.SIGKILL)
            except (OSError,ValueError): pass
        p.wait()
PY
}

@test "worker failure after completed results still makes the run fail" {
    _mock_podman_pass
    real_mv="$(command -v mv)"
    cat > "$MOCK_BIN/mv" <<MOCK
#!/bin/bash
"$real_mv" "\$@" || exit \$?
if [[ ! -e "\$BATS_TMPDIR/mv-failed" ]] && grep -q '^PUBLISH_STATUS=PASS$' "\${@: -1}"; then
    touch "\$BATS_TMPDIR/mv-failed"
    exit 23
fi
MOCK
    chmod +x "$MOCK_BIN/mv"
    run bash "$SCRIPT" --versions 8 --source-version v123
    [ "$status" -ne 0 ]
    grep -qx 'PUBLISH_STATUS=PASS' "$LOG_DIR/results/rocky_linux_8.result"
    grep -qx 'WORKER_EXIT_STATUS=23' "$LOG_DIR/results/rocky_linux_8.result"
    [ -f "$LOG_DIR/summary.json" ]
}

@test "default existing-image policy fails without running publisher" {
    _mock_podman_pass
    export IMAGE_EXISTS=yes
    run bash "$SCRIPT" --versions 8 --source-version v123
    [ "$status" -ne 0 ]
    ! grep -q '^podman' "$INVOCATION_LOG" || return 1
    grep -qx 'PUBLISH_REASON=image-already-exists' "$LOG_DIR/results/rocky_linux_8.result"
}
