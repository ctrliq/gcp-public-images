#!/bin/bash
# Build, verify, and publish Rocky Linux images.
#
# Each workflow runs its full pipeline independently in parallel:
#   build (daisy) → check kickstart log → [delete tarball + retry if failed]
#                → extract version → publish (gce_image_publish)
#
# Daisy is invoked from each publish/rocky/<version>/ directory (matching the
# manual workflow) so relative paths in wf.json files resolve correctly.
#
# Usage:
#   ./automation/build_all.sh [--dry-run] [--versions 8,9,10] [--retries N] [--source-version VERSION] [--source-results DIR] [--skip-publish] [--environment test|prod]
#
# GOOGLE_APPLICATION_CREDENTIALS must be set in the environment before calling
# this script (used by daisy). Publishing uses the local gcloud config dir.

set -euo pipefail

START_SECONDS=$SECONDS

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
WORKFLOW_ROOT="$REPO_ROOT/daisy"
LOG_DIR="${LOG_DIR:-$REPO_ROOT/automation/tmp/daisy-builds-$(date +%Y%m%d-%H%M%S)}"
VERSIONS=(8 9 10)
WORKFLOWS=() # if non-empty, only these workflow names are run
DRY_RUN=false
MAX_RETRIES=1
IF_IMAGE_EXISTS=fail # fail | skip | delete
SOURCE_VERSION=""    # if set, skip build and publish this version directly
SOURCE_RESULTS_DIR="" # if set, read per-workflow BUILD_VERSION from .result files
SKIP_PUBLISH=false   # if true, build only — do not publish
ENVIRONMENT=test     # test | prod

# GCP project per target environment.
declare -A ENV_PROJECT=(
	[test]="gce-ciq-images"
	[prod]="rocky-linux-cloud"
)

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
	--dry-run)
		DRY_RUN=true
		shift
		;;
	--versions)
		IFS=',' read -ra VERSIONS <<<"$2"
		shift 2
		;;
	--retries)
		MAX_RETRIES="$2"
		shift 2
		;;
	--workflows)
		IFS=',' read -ra WORKFLOWS <<<"$2"
		shift 2
		;;
	--if-image-exists)
		if [[ "$2" != "fail" && "$2" != "skip" && "$2" != "delete" ]]; then
			echo "ERROR: --if-image-exists must be one of: fail, skip, delete" >&2
			exit 1
		fi
		IF_IMAGE_EXISTS="$2"
		shift 2
		;;
	--source-version)
		SOURCE_VERSION="$2"
		shift 2
		;;
	--source-results)
		SOURCE_RESULTS_DIR="$2"
		shift 2
		;;
	--skip-publish)
		SKIP_PUBLISH=true
		shift
		;;
	--environment)
		if [[ "$2" != "test" && "$2" != "prod" ]]; then
			echo "ERROR: --environment must be one of: test, prod" >&2
			exit 1
		fi
		ENVIRONMENT="$2"
		shift 2
		;;
	*)
		echo "Usage: $0 [--dry-run] [--versions 8,9,10] [--workflows name1,name2] [--retries N] [--if-image-exists fail|skip|delete] [--source-version VERSION] [--source-results DIR] [--skip-publish] [--environment test|prod]"
		exit 1
		;;
	esac
done

# ---------------------------------------------------------------------------
# Validate --source-version / --source-results.
# ---------------------------------------------------------------------------
if [[ -n "$SOURCE_VERSION" && -n "$SOURCE_RESULTS_DIR" ]]; then
	echo "ERROR: --source-version and --source-results are mutually exclusive" >&2
	exit 1
fi
if [[ -n "$SOURCE_RESULTS_DIR" && ! -d "$SOURCE_RESULTS_DIR" ]]; then
	echo "ERROR: --source-results directory does not exist: $SOURCE_RESULTS_DIR" >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# Production safety guards.
# ---------------------------------------------------------------------------
if [[ "$ENVIRONMENT" == "prod" ]]; then
	if [[ -z "$SOURCE_VERSION" && -z "$SOURCE_RESULTS_DIR" ]]; then
		echo "ERROR: --source-version or --source-results is required when --environment=prod" >&2
		exit 1
	fi
	if [[ "$IF_IMAGE_EXISTS" == "delete" ]]; then
		echo "ERROR: --if-image-exists=delete is not allowed when --environment=prod" >&2
		exit 1
	fi
fi

PUBLISH_EXTRA_ARGS=()
if [[ "$ENVIRONMENT" == "test" ]]; then
	PUBLISH_EXTRA_ARGS=(-rollout_rate 0)
fi

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

# _get_field FILE KEY — extracts a single value from a result file.
_get_field() {
	grep -m1 "^${2}=" "$1" 2>/dev/null | cut -d= -f2- || true
}

# Validate that every selected workflow has a result file with a BUILD_VERSION.
if [[ -n "$SOURCE_RESULTS_DIR" ]]; then
	_missing=()
	for name in "${all_names[@]}"; do
		rf="$SOURCE_RESULTS_DIR/${name}.result"
		if [[ ! -f "$rf" ]] || [[ -z $(_get_field "$rf" BUILD_VERSION) ]]; then
			_missing+=("$name")
		fi
	done
	if [[ ${#_missing[@]} -gt 0 ]]; then
		echo "ERROR: --source-results is missing BUILD_VERSION for:" >&2
		printf '  %s\n' "${_missing[@]}" >&2
		exit 1
	fi
fi

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
		if [[ -n "$SOURCE_RESULTS_DIR" ]]; then
			local_result_version=$(_get_field "$SOURCE_RESULTS_DIR/${name}.result" BUILD_VERSION)
			printf "    [build]   SKIPPED (--source-results version=%s)\n" "${local_result_version:-MISSING}"
		elif [[ -n "$SOURCE_VERSION" ]]; then
			printf "    [build]   SKIPPED (--source-version=%s)\n" "$SOURCE_VERSION"
		else
			printf "    [build]   daisy -zone %s -var:workflow_root=%s %s\n" \
				"$local_zone" "$WORKFLOW_ROOT" "$local_wf_file"
		fi
		if $SKIP_PUBLISH; then
			printf "    [publish] SKIPPED (--skip-publish)\n\n"
		else
			printf '    [publish] podman run --pull=newer %s \\\n' "${PUBLISH_CREDS[*]}"
			printf '                -v %s:/workflows:z \\\n' "$local_wf_dir"
			printf '                gcr.io/compute-image-tools/gce_image_publish:latest \\\n'
			printf '                -source_gcs_path gs://gce-ciq-images-prod-artifacts \\\n'
			if [[ -n "$SOURCE_RESULTS_DIR" ]]; then
				local_version_display=$(_get_field "$SOURCE_RESULTS_DIR/${name}.result" BUILD_VERSION)
				local_version_display="${local_version_display:-MISSING}"
			else
				local_version_display="${SOURCE_VERSION:-<version>}"
			fi
			printf '                -source_version %s -no_root -skip_confirmation \\\n' "$local_version_display"
			if [[ "$ENVIRONMENT" == "test" ]]; then
				printf '                -date_version -var:environment=test -rollout_rate 0 \\\n'
			else
				printf '                -date_version -var:environment=%s \\\n' "$ENVIRONMENT"
			fi
			printf '                /workflows/%s\n\n' "$local_publish_json"
		fi
	done
	exit 0
fi

# ---------------------------------------------------------------------------
# Production confirmation prompt.
# ---------------------------------------------------------------------------
if [[ "$ENVIRONMENT" == "prod" ]]; then
	echo ""
	echo "=== PRODUCTION PUBLISH ==="
	echo "  Environment:    prod (target project: ${ENV_PROJECT[prod]})"
	if [[ -n "$SOURCE_RESULTS_DIR" ]]; then
		echo "  Source:         --source-results $SOURCE_RESULTS_DIR"
	else
		echo "  Source version: $SOURCE_VERSION"
	fi
	echo "  Workflows:      ${#all_names[@]}"
	for name in "${all_names[@]}"; do
		if [[ -n "$SOURCE_RESULTS_DIR" ]]; then
			local_ver=$(_get_field "$SOURCE_RESULTS_DIR/${name}.result" BUILD_VERSION)
			printf '    - %-55s  %s\n' "$name" "${local_ver:-MISSING}"
		else
			printf '    - %s\n' "$name"
		fi
	done
	echo ""
	read -r -p "Proceed with production publish? [y/N] " confirm
	if [[ "$confirm" != [yY] ]]; then
		echo "Aborted."
		exit 1
	fi
fi

mkdir -p "$LOG_DIR"
RESULT_DIR="$LOG_DIR/results"
mkdir -p "$RESULT_DIR"

# ---------------------------------------------------------------------------
# _write_result NAME KEY=VALUE [KEY=VALUE ...]
#   Writes structured result fields to $RESULT_DIR/<name>.result.
# ---------------------------------------------------------------------------
_write_result() {
	local name="$1"
	shift
	printf '%s\n' "$@" >"$RESULT_DIR/${name}.result"
}

# ---------------------------------------------------------------------------
# run_pipeline NAME
#   Runs the full build → verify → publish pipeline for one workflow.
#   Writes structured KEY=VALUE fields to $RESULT_DIR/<name>.result:
#     BUILD_STATUS, BUILD_ATTEMPTS, BUILD_REASON, BUILD_VERSION,
#     PUBLISH_STATUS, PUBLISH_ATTEMPTS, PUBLISH_REASON
#   All console output is prefixed with [name] for legibility in parallel runs.
# ---------------------------------------------------------------------------
run_pipeline() {
	local name="$1"
	local wf_dir="${wf_dirs[$name]}"
	local wf_file
	wf_file="$(basename "${wf_paths[$name]}")"
	local zone="${wf_zones[$name]}"
	local publish_json="${wf_file%.wf.json}.publish.json"
	local attempt=1
	local version=""
	local image_name=""

	# ---- Skip build if --source-version or --source-results was provided ----
	if [[ -n "$SOURCE_RESULTS_DIR" ]]; then
		local result_file="$SOURCE_RESULTS_DIR/${name}.result"
		if [[ ! -f "$result_file" ]]; then
			echo "[$name] ERROR: no result file at $result_file"
			_write_result "$name" \
				"BUILD_STATUS=FAIL" \
				"BUILD_ATTEMPTS=0" \
				"BUILD_REASON=result-file-not-found"
			return
		fi
		version=$(_get_field "$result_file" BUILD_VERSION)
		if [[ -z "$version" ]]; then
			echo "[$name] ERROR: no BUILD_VERSION in $result_file"
			_write_result "$name" \
				"BUILD_STATUS=FAIL" \
				"BUILD_ATTEMPTS=0" \
				"BUILD_REASON=version-not-in-result-file"
			return
		fi
		echo "[$name] Skipping build (--source-results version=$version)."
	elif [[ -n "$SOURCE_VERSION" ]]; then
		version="$SOURCE_VERSION"
		echo "[$name] Skipping build (--source-version=$version)."
	else

		# ---- Build + kickstart verification retry loop ----
		while true; do
			local daisy_log="$LOG_DIR/${name}.attempt${attempt}.daisy.log"
			echo "[$name] Build attempt $attempt starting..."

			# Run daisy from the workflow's publish directory.
			if ! (cd "$wf_dir" && daisy \
				-zone "$zone" \
				-var:workflow_root="$WORKFLOW_ROOT" \
				"$wf_file") >"$daisy_log" 2>&1; then
				local daisy_exit=$?
				echo "[$name] Attempt $attempt: daisy exited $daisy_exit. Log: $daisy_log"
				if [[ $attempt -gt $MAX_RETRIES ]]; then
					_write_result "$name" \
						"BUILD_STATUS=FAIL" \
						"BUILD_ATTEMPTS=$attempt" \
						"BUILD_REASON=daisy-exited-${daisy_exit}"
					return
				fi
				((attempt++)) || true
				continue
			fi

			# Derive GCS paths from daisy stdout.
			# Daisy prints: "Streaming instance ... serial port 1 output to https://..."
			local serial_url
			serial_url=$(grep -oP 'https://storage\.cloud\.google\.com/\S+serial-port1\.log' "$daisy_log" |
				grep '/inst-build-' | tail -1 || true)

			if [[ -z "$serial_url" ]]; then
				echo "[$name] Attempt $attempt: serial log URL not found in daisy output. Log: $daisy_log"
				if [[ $attempt -gt $MAX_RETRIES ]]; then
					_write_result "$name" \
						"BUILD_STATUS=FAIL" \
						"BUILD_ATTEMPTS=$attempt" \
						"BUILD_REASON=serial-log-url-not-found"
					return
				fi
				((attempt++)) || true
				continue
			fi

			local gcs_serial="gs://${serial_url#https://storage.cloud.google.com/}"
			local gcs_log_dir
			gcs_log_dir="$(dirname "$gcs_serial")"
			local gcs_daisy_log="${gcs_log_dir}/daisy.log"

			# Check kickstart serial log for success.
			if gcloud storage cat "$gcs_serial" 2>/dev/null | grep -q "Installation complete"; then
				echo "[$name] Attempt $attempt: installation complete."
				echo "[$name] Serial log: $serial_url"

				# Extract image name and version from daisy.log.
				# Expected line: CreateImages: Creating image "rocky-linux-9-v1774034849"
				image_name=$(gcloud storage cat "$gcs_daisy_log" 2>/dev/null |
					grep -oP 'Creating image "\K[^"]+' | tail -1 || true)

				if [[ -z "$image_name" ]]; then
					echo "[$name] ERROR: could not extract image name from $gcs_daisy_log"
					_write_result "$name" \
						"BUILD_STATUS=FAIL" \
						"BUILD_ATTEMPTS=$attempt" \
						"BUILD_REASON=image-name-not-found-in-daisy-log"
					return
				fi

				version=$(echo "$image_name" | grep -oP 'v\d+$' || true)

				if [[ -z "$version" ]]; then
					echo "[$name] ERROR: could not extract version from image name '$image_name'"
					_write_result "$name" \
						"BUILD_STATUS=FAIL" \
						"BUILD_ATTEMPTS=$attempt" \
						"BUILD_REASON=version-not-found-in-image-name"
					return
				fi

				echo "[$name] Image: $image_name  Version: $version"
				break # Proceed to publish.
			fi

			# Installation did not complete — delete the failed tarball and retry.
			echo "[$name] Attempt $attempt: 'Installation complete' not found in serial log ($gcs_serial)."

			image_name=$(gcloud storage cat "$gcs_daisy_log" 2>/dev/null |
				grep -oP 'Creating image "\K[^"]+' | tail -1 || true)

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
				_write_result "$name" \
					"BUILD_STATUS=FAIL" \
					"BUILD_ATTEMPTS=$attempt" \
					"BUILD_REASON=no-installation-complete"
				return
			fi

			((attempt++)) || true
		done

	fi # end --source-version / --source-results skip

	# ---- Skip publish if --skip-publish was provided ----
	if $SKIP_PUBLISH; then
		local build_status_label
		if [[ -n "$SOURCE_VERSION" || -n "$SOURCE_RESULTS_DIR" ]]; then
			build_status_label="SKIPPED"
		else
			build_status_label="PASS"
		fi
		echo "[$name] Skipping publish (--skip-publish)."
		_write_result "$name" \
			"BUILD_STATUS=$build_status_label" \
			"BUILD_ATTEMPTS=$attempt" \
			"BUILD_VERSION=$version" \
			"PUBLISH_STATUS=SKIPPED" \
			"PUBLISH_REASON=--skip-publish"
		return
	fi

	# ---- Pre-publish: handle existing image if requested ----
	if [[ "$IF_IMAGE_EXISTS" != "fail" ]]; then
		local image_prefix today published_image
		image_prefix=$(grep -oP '"Prefix":\s*"\K[^"]+' "$wf_dir/$publish_json" | head -1 || true)

		if [[ -n "$image_prefix" ]]; then
			today=$(date +%Y%m%d)
			published_image="${image_prefix}-v${today}"

			if gcloud compute images describe "$published_image" \
				--project=gce-ciq-images --quiet 2>/dev/null; then
				echo "[$name] Image $published_image already exists in gce-ciq-images."

				if [[ "$IF_IMAGE_EXISTS" == "skip" ]]; then
					echo "[$name] Skipping publish (--if-image-exists=skip)."
					_write_result "$name" \
						"BUILD_STATUS=$build_status_label" \
						"BUILD_ATTEMPTS=$attempt" \
						"BUILD_VERSION=$version" \
						"PUBLISH_STATUS=SKIPPED"
					return
				elif [[ "$IF_IMAGE_EXISTS" == "delete" ]]; then
					echo "[$name] Deleting existing image (--if-image-exists=delete)..."
					if gcloud compute images delete "$published_image" \
						--project=gce-ciq-images --quiet 2>/dev/null; then
						echo "[$name] Deleted $published_image. Proceeding with publish."
					else
						echo "[$name] WARN: failed to delete $published_image; publish may fail."
					fi
				fi
			fi
		else
			echo "[$name] WARN: could not extract Prefix from $publish_json; skipping existence check."
		fi
	fi

	# ---- Publish retry loop ----
	# Build succeeded (or skipped) — only the publish is retried if it fails.
	local build_status_label
	if [[ -n "$SOURCE_VERSION" || -n "$SOURCE_RESULTS_DIR" ]]; then
		build_status_label="SKIPPED"
	else
		build_status_label="PASS"
	fi

	local pub_attempt=1
	while true; do
		local pub_log="$LOG_DIR/${name}.publish.attempt${pub_attempt}.log"
		echo "[$name] Publish attempt $pub_attempt (version=$version)..."

		if podman run --pull=newer \
			"${PUBLISH_CREDS[@]}" \
			-v "${wf_dir}:/workflows:z" \
			gcr.io/compute-image-tools/gce_image_publish:latest \
			-source_gcs_path gs://gce-ciq-images-prod-artifacts \
			-source_version "$version" \
			-no_root -skip_confirmation -date_version \
			-var:environment="$ENVIRONMENT" \
			"${PUBLISH_EXTRA_ARGS[@]}" \
			/workflows/"$publish_json" >"$pub_log" 2>&1; then
			echo "[$name] Published successfully."
			_write_result "$name" \
				"BUILD_STATUS=$build_status_label" \
				"BUILD_ATTEMPTS=$attempt" \
				"BUILD_VERSION=$version" \
				"PUBLISH_STATUS=PASS" \
				"PUBLISH_ATTEMPTS=$pub_attempt"
			return
		fi

		echo "[$name] Publish attempt $pub_attempt failed. Log: $pub_log"

		if [[ $pub_attempt -gt $MAX_RETRIES ]]; then
			echo "[$name] Max publish retries ($MAX_RETRIES) reached."
			_write_result "$name" \
				"BUILD_STATUS=$build_status_label" \
				"BUILD_ATTEMPTS=$attempt" \
				"BUILD_VERSION=$version" \
				"PUBLISH_STATUS=FAIL" \
				"PUBLISH_ATTEMPTS=$pub_attempt" \
				"PUBLISH_REASON=publish-failed"
			return
		fi

		((pub_attempt++)) || true
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
total=${#all_names[@]}
build_pass=0
build_fail=0
pub_pass=0
pub_fail=0
pub_skipped=0
overall_fail=0

echo ""
echo "=== Final Results ==="
printf '  %-55s  %-32s  %s\n' "WORKFLOW" "BUILD" "PUBLISH"
printf '  %-55s  %-32s  %s\n' "--------" "-----" "-------"

for name in $(printf '%s\n' "${all_names[@]}" | sort); do
	result_file="$RESULT_DIR/${name}.result"

	if [[ ! -f "$result_file" ]]; then
		printf '  %-55s  %-32s  %s\n' "$name" "FAIL [no result written]" "-"
		((build_fail++)) || true
		((pub_skipped++)) || true
		((overall_fail++)) || true
		continue
	fi

	build_status=$(_get_field "$result_file" BUILD_STATUS)
	build_attempts=$(_get_field "$result_file" BUILD_ATTEMPTS)
	build_reason=$(_get_field "$result_file" BUILD_REASON)
	build_version=$(_get_field "$result_file" BUILD_VERSION)
	pub_status=$(_get_field "$result_file" PUBLISH_STATUS)
	pub_attempts=$(_get_field "$result_file" PUBLISH_ATTEMPTS)
	pub_reason=$(_get_field "$result_file" PUBLISH_REASON)

	if [[ "$build_status" == "PASS" ]]; then
		build_col="PASS (${build_attempts} att)"
		((build_pass++)) || true
	elif [[ "$build_status" == "SKIPPED" ]]; then
		build_col="SKIPPED (--source-version)"
		((build_pass++)) || true
	else
		build_col="FAIL (${build_attempts} att) [${build_reason}]"
		((build_fail++)) || true
	fi

	if [[ -z "$pub_status" ]]; then
		pub_col="- (build failed)"
		((pub_skipped++)) || true
	elif [[ "$pub_status" == "PASS" ]]; then
		pub_col="PASS (${pub_attempts} att) [${build_version}]"
		((pub_pass++)) || true
	elif [[ "$pub_status" == "SKIPPED" ]]; then
		if [[ "$pub_reason" == "--skip-publish" ]]; then
			pub_col="SKIPPED (--skip-publish) [${build_version}]"
		else
			pub_col="SKIPPED (image already exists) [${build_version}]"
		fi
		((pub_skipped++)) || true
	else
		pub_col="FAIL (${pub_attempts} att) [${pub_reason}]"
		((pub_fail++)) || true
	fi

	printf '  %-55s  %-32s  %s\n' "$name" "$build_col" "$pub_col"

	if [[ "$build_status" != "PASS" && "$build_status" != "SKIPPED" || ("$pub_status" != "PASS" && "$pub_status" != "SKIPPED") ]]; then
		((overall_fail++)) || true
	fi
done

echo ""
echo "=== Summary ==="
printf '  Build:   %d passed, %d failed (%d total)\n' "$build_pass" "$build_fail" "$total"
printf '  Publish: %d passed, %d failed, %d skipped/not-attempted\n' "$pub_pass" "$pub_fail" "$pub_skipped"
echo ""
echo "Logs: $LOG_DIR"
elapsed=$((SECONDS - START_SECONDS))
printf '  Total time: %dm %02ds\n' $((elapsed / 60)) $((elapsed % 60))

[[ $overall_fail -eq 0 ]]
