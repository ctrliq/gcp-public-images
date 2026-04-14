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
    mkdir -p "$FIXTURE_ROOT/daisy"

    # Minimal wf.json fixtures — content doesn't matter, daisy is mocked.
    touch "$FIXTURE_ROOT/publish/rocky/8/rocky_linux_8.wf.json"
    touch "$FIXTURE_ROOT/publish/rocky/9/rocky_linux_9.wf.json"

    export PATH="$MOCK_BIN:$PATH"
    export REPO_ROOT="$FIXTURE_ROOT"
    export LOG_DIR="$TEST_TMPDIR/logs"
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
if [[ "$*" == *"serial-port1.log"* ]]; then
    echo "Installation complete"
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
}

@test "--source-version skips build and invokes publish with the correct version" {
    _mock_daisy_pass
    _mock_podman_pass

    run bash "$SCRIPT" --versions 8 --source-version v1234567890

    [ "$status" -eq 0 ]
    # daisy must never be called
    if [[ -f "$INVOCATION_LOG" ]]; then
        ! grep -q "daisy" "$INVOCATION_LOG"
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
    ! [[ "$output" == *"daisy -zone"* ]]
}
