#!/bin/bash
# Build, verify, and publish Rocky Linux images to the test environment.
#
# Each workflow runs its full pipeline independently in parallel:
#   build (daisy) → check kickstart log → [delete tarball + retry if failed]
#                → extract version → publish (gce_image_publish)
#
# Daisy is invoked from each publish/rocky/<version>/ directory (matching the
# manual workflow) so relative paths in wf.json files resolve correctly.
#
# Usage:
#   ./automation/build_all.sh [--dry-run] [--versions 8,9,10] [--retries N]
#
# GOOGLE_APPLICATION_CREDENTIALS must be set in the environment before calling
# this script (used by daisy). Publishing uses the local gcloud config dir.

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
WORKFLOW_ROOT="$REPO_ROOT/daisy"
LOG_DIR="${LOG_DIR:-$REPO_ROOT/automation/tmp/daisy-builds-$(date +%Y%m%d-%H%M%S)}"
VERSIONS=(8 9 10)
WORKFLOWS=()   # if non-empty, only these workflow names are run
DRY_RUN=false
MAX_RETRIES=1

# Zone to use per Rocky major version.
declare -A VERSION_ZONE=(
    [8]="us-central1-b"
    [9]="europe-west4-a"
    [10]="asia-southeast1-b"
)

# Credential mount args for gce_image_publish (Option B — gcloud config dir).
# To switch to Option A (service account key file), replace with:
#   PUBLISH_CREDS=(-v "$GOOGLE_APPLICATION_CREDENTIALS:/creds/key.json:ro,z"
#                  -e "GOOGLE_APPLICATION_CREDENTIALS=/creds/key.json")
PUBLISH_CREDS=(
    -v "${HOME}/.config/gcloud/:/creds:z"
    -e "GOOGLE_APPLICATION_CREDENTIALS=/creds/application_default_credentials.json"
)

for version in "${!VERSION_ZONE[@]}"; do
    zone="${VERSION_ZONE[$version]}"
    if [[ "$zone" == ZONE_FOR_* ]]; then
        echo "ERROR: Zone for Rocky $version is not configured (got '$zone')." >&2
        echo "       Edit VERSION_ZONE in this script before running." >&2
        exit 1
    fi
done

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)  DRY_RUN=true; shift ;;
        --versions) IFS=',' read -ra VERSIONS <<< "$2"; shift 2 ;;
        --retries)   MAX_RETRIES="$2"; shift 2 ;;
        --workflows) IFS=',' read -ra WORKFLOWS <<< "$2"; shift 2 ;;
        *) echo "Usage: $0 [--dry-run] [--versions 8,9,10] [--workflows name1,name2] [--retries N]"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Build workflow index: name -> (path, dir, zone).
# ---------------------------------------------------------------------------
declare -A wf_paths wf_dirs wf_zones
all_names=()

for version in "${VERSIONS[@]}"; do
    wf_dir="$REPO_ROOT/publish/rocky/$version"
    if [[ ! -d "$wf_dir" ]]; then
        echo "WARN: $wf_dir not found, skipping"
        continue
    fi
    zone="${VERSION_ZONE[$version]}"
    for wf in "$wf_dir"/*wf.json; do
        name="$(basename "$wf" .wf.json)"
        if [[ ${#WORKFLOWS[@]} -gt 0 ]]; then
            local_match=false
            for w in "${WORKFLOWS[@]}"; do
                [[ "$name" == "$w" ]] && local_match=true && break
            done
            $local_match || continue
        fi
        wf_paths[$name]="$wf"
        wf_dirs[$name]="$wf_dir"
        wf_zones[$name]="$zone"
        all_names+=("$name")
    done
done

# ---------------------------------------------------------------------------
# Dry run: print the full pipeline per workflow and exit.
# ---------------------------------------------------------------------------
if $DRY_RUN; then
    echo "=== Dry run — full pipeline per workflow ==="
    for name in "${all_names[@]}"; do
        local_wf_dir="${wf_dirs[$name]}"
        local_zone="${wf_zones[$name]}"
        local_wf_file="$(basename "${wf_paths[$name]}")"
        local_publish_json="${local_wf_file%.wf.json}.publish.json"
        printf "  [%s]\n" "$name"
        printf "    [dir]     %s\n" "$local_wf_dir"
        printf "    [build]   daisy -zone %s -var:workflow_root=%s %s\n" \
            "$local_zone" "$WORKFLOW_ROOT" "$local_wf_file"
        printf '    [publish] podman run %s \\\n' "${PUBLISH_CREDS[*]}"
        printf '                -v %s:/workflows:z \\\n' "$local_wf_dir"
        printf '                gcr.io/compute-image-tools/gce_image_publish:latest \\\n'
        printf '                -source_gcs_path gs://gce-ciq-images-prod-artifacts \\\n'
        printf '                -source_version <version> -no_root -skip_confirmation \\\n'
        printf '                -date_version -var:environment=test -rollout_rate 0 \\\n'
        printf '                /workflows/%s\n\n' "$local_publish_json"
    done
    exit 0
fi

mkdir -p "$LOG_DIR"
RESULT_DIR="$LOG_DIR/results"
mkdir -p "$RESULT_DIR"

# ---------------------------------------------------------------------------
# run_pipeline NAME
#   Runs the full build → verify → publish pipeline for one workflow.
#   Writes "PASS:<version>" or "FAIL:<reason>" to $RESULT_DIR/<name>.result.
#   All console output is prefixed with [name] for legibility in parallel runs.
# ---------------------------------------------------------------------------
run_pipeline() {
    local name="$1"
    local wf_dir="${wf_dirs[$name]}"
    local wf_file="$(basename "${wf_paths[$name]}")"
    local zone="${wf_zones[$name]}"
    local publish_json="${wf_file%.wf.json}.publish.json"
    local attempt=1
    local version=""
    local image_name=""

    # ---- Build + kickstart verification retry loop ----
    while true; do
        local daisy_log="$LOG_DIR/${name}.attempt${attempt}.daisy.log"
        echo "[$name] Build attempt $attempt starting..."

        # Run daisy from the workflow's publish directory.
        if ! (cd "$wf_dir" && daisy \
                -zone "$zone" \
                -var:workflow_root="$WORKFLOW_ROOT" \
                "$wf_file") > "$daisy_log" 2>&1; then
            local daisy_exit=$?
            echo "[$name] Attempt $attempt: daisy exited $daisy_exit. Log: $daisy_log"
            if [[ $attempt -gt $MAX_RETRIES ]]; then
                echo "FAIL:daisy-exited-${daisy_exit}" > "$RESULT_DIR/${name}.result"
                return
            fi
            (( attempt++ )) || true
            continue
        fi

        # Derive GCS paths from daisy stdout.
        # Daisy prints: "Streaming instance ... serial port 1 output to https://..."
        local serial_url
        serial_url=$(grep -oP 'https://storage\.cloud\.google\.com/\S+serial-port1\.log' "$daisy_log" \
            | grep '/inst-build-' | tail -1 || true)

        if [[ -z "$serial_url" ]]; then
            echo "[$name] Attempt $attempt: serial log URL not found in daisy output. Log: $daisy_log"
            if [[ $attempt -gt $MAX_RETRIES ]]; then
                echo "FAIL:serial-log-url-not-found" > "$RESULT_DIR/${name}.result"
                return
            fi
            (( attempt++ )) || true
            continue
        fi

        local gcs_serial="gs://$(echo "$serial_url" | sed 's|https://storage\.cloud\.google\.com/||')"
        local gcs_log_dir
        gcs_log_dir="$(dirname "$gcs_serial")"
        local gcs_daisy_log="${gcs_log_dir}/daisy.log"

        # Check kickstart serial log for success.
        if gcloud storage cat "$gcs_serial" 2>/dev/null | grep -q "Installation complete"; then
            echo "[$name] Attempt $attempt: installation complete."

            # Extract image name and version from daisy.log.
            # Expected line: CreateImages: Creating image "rocky-linux-9-v1774034849"
            image_name=$(gcloud storage cat "$gcs_daisy_log" 2>/dev/null \
                | grep -oP 'Creating image "\K[^"]+' | tail -1 || true)

            if [[ -z "$image_name" ]]; then
                echo "[$name] ERROR: could not extract image name from $gcs_daisy_log"
                echo "FAIL:image-name-not-found-in-daisy-log" > "$RESULT_DIR/${name}.result"
                return
            fi

            version=$(echo "$image_name" | grep -oP 'v\d+$' || true)

            if [[ -z "$version" ]]; then
                echo "[$name] ERROR: could not extract version from image name '$image_name'"
                echo "FAIL:version-not-found" > "$RESULT_DIR/${name}.result"
                return
            fi

            echo "[$name] Image: $image_name  Version: $version"
            break  # Proceed to publish.
        fi

        # Installation did not complete — delete the failed tarball and retry.
        echo "[$name] Attempt $attempt: 'Installation complete' not found in serial log ($gcs_serial)."

        image_name=$(gcloud storage cat "$gcs_daisy_log" 2>/dev/null \
            | grep -oP 'Creating image "\K[^"]+' | tail -1 || true)

        if [[ -n "$image_name" ]]; then
            local tarball="gs://gce-ciq-images-prod-artifacts/${image_name}.tar.gz"
            echo "[$name] Deleting failed tarball: $tarball"
            if gcloud storage rm "$tarball" --project=gce-ciq-images 2>/dev/null; then
                echo "[$name] Tarball deleted."
            else
                echo "[$name] WARN: tarball deletion failed or object did not exist; continuing."
            fi
        else
            echo "[$name] WARN: could not determine tarball path from $gcs_daisy_log — nothing deleted."
        fi

        if [[ $attempt -gt $MAX_RETRIES ]]; then
            echo "[$name] Max retries ($MAX_RETRIES) reached. Build failed."
            echo "FAIL:no-installation-complete" > "$RESULT_DIR/${name}.result"
            return
        fi

        (( attempt++ )) || true
    done

    # ---- Publish retry loop ----
    # Build succeeded — only the publish is retried if it fails.
    local pub_attempt=1
    while true; do
        local pub_log="$LOG_DIR/${name}.publish.attempt${pub_attempt}.log"
        echo "[$name] Publish attempt $pub_attempt (version=$version)..."

        if podman run \
                "${PUBLISH_CREDS[@]}" \
                -v "${wf_dir}:/workflows:z" \
                gcr.io/compute-image-tools/gce_image_publish:latest \
                -source_gcs_path gs://gce-ciq-images-prod-artifacts \
                -source_version "$version" \
                -no_root -skip_confirmation -date_version \
                -var:environment=test \
                -rollout_rate 0 \
                /workflows/"$publish_json" > "$pub_log" 2>&1; then
            echo "[$name] Published successfully."
            echo "PASS:$version" > "$RESULT_DIR/${name}.result"
            return
        fi

        echo "[$name] Publish attempt $pub_attempt failed. Log: $pub_log"

        if [[ $pub_attempt -gt $MAX_RETRIES ]]; then
            echo "[$name] Max publish retries ($MAX_RETRIES) reached."
            echo "FAIL:publish-failed-after-${pub_attempt}-attempt(s)" > "$RESULT_DIR/${name}.result"
            return
        fi

        (( pub_attempt++ )) || true
    done
}

# ---------------------------------------------------------------------------
# Launch all pipelines in parallel.
# ---------------------------------------------------------------------------
pids=()
echo "=== Launching ${#all_names[@]} workflow pipelines (logs=$LOG_DIR) ==="
for name in "${all_names[@]}"; do
    run_pipeline "$name" &
    pids+=($!)
    echo "  + $name (PID $!)"
done

echo ""
echo "=== Waiting for ${#pids[@]} pipelines ==="
for pid in "${pids[@]}"; do
    wait "$pid" || true
done

# ---------------------------------------------------------------------------
# Final summary.
# ---------------------------------------------------------------------------
pass=0
fail=0
total=${#all_names[@]}

echo ""
echo "=== Final Results ==="
for name in $(printf '%s\n' "${all_names[@]}" | sort); do
    result_file="$RESULT_DIR/${name}.result"
    if [[ ! -f "$result_file" ]]; then
        status="FAIL:no-result-written"
    else
        status="$(cat "$result_file")"
    fi

    if [[ "$status" == PASS:* ]]; then
        printf "  PASS  %-60s  [%s]\n" "$name" "${status#PASS:}"
        (( pass++ )) || true
    else
        printf "  FAIL  %-60s  [%s]\n" "$name" "${status#FAIL:}"
        (( fail++ )) || true
    fi
done

echo ""
echo "=== $pass passed, $fail failed ($total total) ==="
echo "Logs: $LOG_DIR"

[[ $fail -eq 0 ]]
