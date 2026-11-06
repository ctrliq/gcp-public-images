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
# See automation/README.md for ADC/WIF mounts, host gcloud configuration,
# result schema, verification guarantees, and cancellation/cleanup limits.

set -euo pipefail

START_SECONDS=$SECONDS
DATA_HELPER="$(cd "$(dirname "$0")" && pwd)/build_all_data.py"

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
WORKFLOW_ROOT="$REPO_ROOT/daisy"
LOG_DIR="${LOG_DIR:-$REPO_ROOT/automation/tmp/daisy-builds-$(date +%Y%m%d-%H%M%S)}"
VERSIONS=(8 9 10)
WORKFLOWS=() # if non-empty, only these workflow names are run
DRY_RUN=false
MAX_RETRIES=1
IF_IMAGE_EXISTS=fail  # fail | skip | delete
SOURCE_VERSION=""     # if set, skip build and publish this version directly
SOURCE_RESULTS_DIR="" # if set, read per-workflow BUILD_VERSION from .result files
SKIP_PUBLISH=false    # if true, build only — do not publish
ENVIRONMENT="test"    # test | prod
YES=false
PUBLISH_VERSION="v$(date -u +%Y%m%d)"

error() {
	echo "ERROR: $*" >&2
	exit 1
}
usage() {
	echo "Usage: $0 [--dry-run] [--versions 8,9,10] [--workflows name1,name2] [--retries N] [--if-image-exists fail|skip|delete] [--source-version vDIGITS | --source-results DIR] [--skip-publish] [--environment test|prod] [--yes]"
}


# Zone to use per Rocky major version.
declare -A VERSION_ZONE=(
	[8]="us-central1-b"
	[9]="europe-west4-a"
	[10]="asia-southeast1-b"
)

# Populated only after dry-run and production approval; never logged.
PUBLISH_CREDS=()

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
	--versions | --retries | --workflows | --if-image-exists | --source-version | --source-results | --environment)
		[[ $# -ge 2 && -n "$2" && "$2" != --* ]] || error "$1 requires a value"
		;;
	esac
	case "$1" in
	--help | -h)
		usage
		exit 0
		;;
	--yes)
		YES=true
		shift
		;;
	--dry-run)
		DRY_RUN=true
		shift
		;;
	--versions)
		[[ "$2" =~ ^(8|9|10)(,(8|9|10))*$ ]] || error "--versions must select 8,9,10"
		IFS=',' read -ra VERSIONS <<<"$2"
		declare -A seen_versions=()
		for v in "${VERSIONS[@]}"; do
			[[ ! -v seen_versions[$v] ]] || error "duplicate version: $v"
			seen_versions[$v]=1
		done
		shift 2
		;;
	--retries)
		[[ "$2" =~ ^[0-9]{1,6}$ ]] || error "--retries must be a nonnegative integer (0..999999)"
		MAX_RETRIES=$((10#$2))
		shift 2
		;;
	--workflows)
		[[ "$2" =~ ^[a-zA-Z0-9_-]+(,[a-zA-Z0-9_-]+)*$ ]] || error "invalid --workflows selection"
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
		[[ "$2" =~ ^v[0-9]+$ ]] || error "--source-version must match v[0-9]+"
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
		echo "ERROR: unknown option $1" >&2
		usage
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

if $SKIP_PUBLISH && [[ -n "$SOURCE_VERSION" || -n "$SOURCE_RESULTS_DIR" ]]; then
	error "source selection with --skip-publish is a no-op"
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
	for wf in "$wf_dir"/*.wf.json; do
		[[ -f "$wf" ]] || continue
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

[[ ${#all_names[@]} -gt 0 ]] || error "no workflows selected"
for requested in "${WORKFLOWS[@]}"; do
	[[ -v wf_paths[$requested] ]] || error "workflow not found in selected versions: $requested"
done

# Resolve selected publisher metadata locally before approval or cloud access.
command -v python3 >/dev/null || error "python3 is required for publisher metadata validation"
declare -A wf_projects=()
for name in "${all_names[@]}"; do
	wf_projects[$name]=$(python3 "$DATA_HELPER" target-project "${wf_paths[$name]%.wf.json}.publish.json" "$ENVIRONMENT") || exit 1
done

# _get_field FILE KEY — extracts a single value from a result file.
_get_field() {
	grep -m1 "^${2}=" "$1" 2>/dev/null | cut -d= -f2- || true
}

# Validate and snapshot source data before any cloud access (never source/eval).
declare -A source_versions=()
if [[ -n "$SOURCE_RESULTS_DIR" ]]; then
	command -v python3 >/dev/null || error "python3 is required for --source-results"
	for name in "${all_names[@]}"; do
		source_versions[$name]=$(python3 "$DATA_HELPER" source "$SOURCE_RESULTS_DIR/$name.result") || exit 1
	done
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
		printf "    [target]  %s\n" "${wf_projects[$name]}"
		if [[ -n "$SOURCE_RESULTS_DIR" ]]; then
			local_result_version=${source_versions[$name]}
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
			printf '    [publish] podman run --pull=newer %s \\\n' "[read-only ADC and dependency mounts; redacted]"
			printf '                -v %s:/workflows:z \\\n' "$local_wf_dir"
			printf '                gcr.io/compute-image-tools/gce_image_publish:latest \\\n'
			printf '                -source_gcs_path gs://gce-ciq-images-prod-artifacts \\\n'
			if [[ -n "$SOURCE_RESULTS_DIR" ]]; then
				local_version_display=${source_versions[$name]}
				local_version_display="${local_version_display:-MISSING}"
			else
				local_version_display="${SOURCE_VERSION:-<version>}"
			fi
			printf '                -source_version %s -no_root -skip_confirmation \\\n' "$local_version_display"
			if [[ "$ENVIRONMENT" == "test" ]]; then
				printf '                -publish_version %s -var:environment=test -rollout_rate 0 \\\n' "$PUBLISH_VERSION"
			else
				printf '                -publish_version %s -var:environment=%s \\\n' "$PUBLISH_VERSION" "$ENVIRONMENT"
			fi
			printf '                /workflows/%s\n\n' "$local_publish_json"
		fi
	done
	exit 0
fi

[[ ! -e "$LOG_DIR/results" ]] || error "result directory already exists; choose a fresh LOG_DIR"

# ---------------------------------------------------------------------------
# Production confirmation prompt.
# ---------------------------------------------------------------------------
if [[ "$ENVIRONMENT" == "prod" ]] && ! $YES; then
	[[ -t 0 ]] || error "noninteractive production requires --yes"
	echo ""
	echo "=== PRODUCTION PUBLISH ==="
	echo "  Environment:    prod (target projects resolved per workflow)"
	if [[ -n "$SOURCE_RESULTS_DIR" ]]; then
		echo "  Source:         --source-results $SOURCE_RESULTS_DIR"
	else
		echo "  Source version: $SOURCE_VERSION"
	fi
	echo "  Workflows:      ${#all_names[@]}"
	for name in "${all_names[@]}"; do
		if [[ -n "$SOURCE_RESULTS_DIR" ]]; then
			local_ver=${source_versions[$name]}
			printf '    - %s  target=%s  source=%s  publish=%s\n' "$name" "${wf_projects[$name]}" "$local_ver" "$PUBLISH_VERSION"
		else
			printf '    - %s  target=%s  source=%s  publish=%s\n' "$name" "${wf_projects[$name]}" "$SOURCE_VERSION" "$PUBLISH_VERSION"
		fi
	done
	echo ""
	read -r -p "Proceed with production publish? [y/N] " confirm
	if [[ "$confirm" != [yY] ]]; then
		echo "Aborted."
		exit 1
	fi
fi

# Operation-aware dependencies. Dry-run/help need no cloud tools or credentials.
required=(gcloud python3)
[[ -n "$SOURCE_VERSION" || -n "$SOURCE_RESULTS_DIR" ]] || required+=(daisy)
$SKIP_PUBLISH || required+=(podman)
for tool in "${required[@]}"; do
	command -v "$tool" >/dev/null || error "required command not found: $tool"
done
credential_paths=$(python3 "$DATA_HELPER" credentials) || exit 1
mapfile -t credential_files <<<"$credential_paths"
if ! $SKIP_PUBLISH; then
	for credential_file in "${credential_files[@]}"; do
		PUBLISH_CREDS+=(-v "$credential_file:$credential_file:ro,z")
	done
	PUBLISH_CREDS+=(-e "GOOGLE_APPLICATION_CREDENTIALS=${credential_files[0]}")
fi
export GOOGLE_APPLICATION_CREDENTIALS="${credential_files[0]}"
unset credential_paths credential_files credential_file
# Keep a private in-memory snapshot, not a credential-bearing artifact file.
REDACTION_RULES=$(python3 "$DATA_HELPER" redaction-rules) || exit 1

# ---------------------------------------------------------------------------
# Preflight: verify gcloud can reach GCS before spending an hour on builds.
# An expired credential would otherwise surface mid-pipeline as bogus
# per-workflow build failures (see serial-log-fetch-failed below).
# ---------------------------------------------------------------------------
if ! preflight_err=$(gcloud storage ls gs://gce-ciq-images-prod-artifacts 2>&1 >/dev/null); then
	echo "ERROR: preflight failed — gcloud cannot access gs://gce-ciq-images-prod-artifacts:" >&2
	echo "$preflight_err" | head -3 >&2
	echo "Fix gcloud credentials (e.g. 'gcloud auth login') and re-run." >&2
	exit 1
fi

mkdir -p "$LOG_DIR"
RESULT_DIR="$LOG_DIR/results"
mkdir "$RESULT_DIR" || error "result directory already exists; choose a fresh LOG_DIR"

# ---------------------------------------------------------------------------
# _write_result NAME KEY=VALUE [KEY=VALUE ...]
#   Writes structured result fields to $RESULT_DIR/<name>.result.
# ---------------------------------------------------------------------------
_write_result() {
	local name="$1" key value pair tmp
	shift
	local -A fields=(
		[BUILD_STATUS]=RUNNING [BUILD_ATTEMPTS]=0 [BUILD_REASON]="" [BUILD_VERSION]=""
		[PUBLISH_STATUS]=NOT_ATTEMPTED [PUBLISH_ATTEMPTS]=0 [PUBLISH_REASON]=""
		[PUBLISHED_IMAGES]="[]" [SOURCE_TARBALL]="" [WORKER_EXIT_STATUS]=0
		[TARGET_PROJECT]="${wf_projects[$name]}"
	)
	if [[ -f "$RESULT_DIR/$name.result" ]]; then
		while IFS='=' read -r key value; do fields[$key]="$value"; done <"$RESULT_DIR/$name.result"
	fi
	for pair in "$@"; do fields[${pair%%=*}]="${pair#*=}"; done
	tmp="$RESULT_DIR/.$name.$BASHPID.tmp"
	for key in BUILD_STATUS BUILD_ATTEMPTS BUILD_REASON BUILD_VERSION PUBLISH_STATUS PUBLISH_ATTEMPTS PUBLISH_REASON PUBLISHED_IMAGES SOURCE_TARBALL WORKER_EXIT_STATUS TARGET_PROJECT; do
		printf '%s=%s\n' "$key" "${fields[$key]}"
	done >"$tmp"
	mv -f "$tmp" "$RESULT_DIR/$name.result"
}

_finish_result() {
	local name="$1" reason="$2" state="${3:-FAIL}" build pub
	build=$(_get_field "$RESULT_DIR/$name.result" BUILD_STATUS)
	pub=$(_get_field "$RESULT_DIR/$name.result" PUBLISH_STATUS)
	if [[ "$build" == RUNNING || -z "$build" ]]; then
		_write_result "$name" "BUILD_STATUS=$state" "BUILD_REASON=$reason"
	elif [[ "$pub" == RUNNING ]]; then
		_write_result "$name" "PUBLISH_STATUS=$state" "PUBLISH_REASON=$reason"
	fi
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
	local target_project="${wf_projects[$name]}"
	local wf_dir="${wf_dirs[$name]}"
	local wf_file
	wf_file="$(basename "${wf_paths[$name]}")"
	local zone="${wf_zones[$name]}"
	local publish_json="${wf_file%.wf.json}.publish.json"
	local attempt=0
	local version=""
	local image_name=""

	# ---- Skip build if --source-version or --source-results was provided ----
	if [[ -n "$SOURCE_RESULTS_DIR" ]]; then
		version="${source_versions[$name]}"
		echo "[$name] Skipping build (--source-results version=$version)."
	elif [[ -n "$SOURCE_VERSION" ]]; then
		version="$SOURCE_VERSION"
		echo "[$name] Skipping build (--source-version=$version)."
	else

		attempt=1
		# ---- Build + kickstart verification retry loop ----
		while true; do
			_write_result "$name" "BUILD_ATTEMPTS=$attempt"
			local daisy_log="$LOG_DIR/${name}.attempt${attempt}.daisy.log"
			echo "[$name] Build attempt $attempt starting..."

			# Run daisy from the workflow's publish directory.
			if (cd "$wf_dir" && exec daisy \
				-zone "$zone" \
				-var:workflow_root="$WORKFLOW_ROOT" \
				"$wf_file") >"$daisy_log" 2>&1; then
				:
			else
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

			# Fetch the kickstart serial log. A fetch failure (expired
			# credentials, missing object, network) is an infrastructure
			# error, not a build failure: fail immediately with the gcloud
			# error instead of retrying the build or deleting the tarball.
			local serial_log="$LOG_DIR/${name}.attempt${attempt}.serial-port1.log"
			if ! gcloud storage cat "$gcs_serial" >"$serial_log" 2>"${serial_log}.err"; then
				echo "[$name] ERROR: could not fetch serial log $gcs_serial"
				echo "[$name] gcloud: $(head -1 "${serial_log}.err")"
				echo "[$name] Full gcloud error: ${serial_log}.err"
				_write_result "$name" \
					"BUILD_STATUS=FAIL" \
					"BUILD_ATTEMPTS=$attempt" \
					"BUILD_REASON=serial-log-fetch-failed"
				return
			fi

			# Check kickstart serial log for success.
			if grep -q "Installation complete" "$serial_log"; then
				echo "[$name] Attempt $attempt: installation complete."
				echo "[$name] Serial log: $serial_url"

				# Extract image name and version from the local daisy log.
				# Expected line: CreateImages: Creating image "rocky-linux-9-v1774034849"
				image_name=$(grep -oP 'Creating image "\K[^"]+' "$daisy_log" | tail -1 || true)

				if [[ -z "$image_name" ]]; then
					echo "[$name] ERROR: could not extract image name from $daisy_log"
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

			image_name=$(grep -oP 'Creating image "\K[^"]+' "$daisy_log" | tail -1 || true)

			if [[ -n "$image_name" ]]; then
				local tarball="gs://gce-ciq-images-prod-artifacts/${image_name}.tar.gz"
				echo "[$name] Deleting failed tarball: $tarball"
				if gcloud storage rm "$tarball" --project=gce-ciq-images >"$LOG_DIR/$name.tarball-delete.log" 2>&1; then
					local deletion_check="$LOG_DIR/$name.tarball-delete-check.log"
					if gcloud storage ls "$tarball" >"$deletion_check" 2>&1 ||
						! grep -Fq 'matched no objects' "$deletion_check"; then
						_write_result "$name" "BUILD_STATUS=FAIL" "BUILD_ATTEMPTS=$attempt" "BUILD_REASON=tarball-delete-verification-failed"
						return
					fi
					echo "[$name] Tarball deletion verified."
				else
					_write_result "$name" "BUILD_STATUS=FAIL" "BUILD_ATTEMPTS=$attempt" "BUILD_REASON=tarball-delete-failed"
					return
				fi
			else
				echo "[$name] WARN: could not determine tarball path from $daisy_log — nothing deleted."
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

	local completed_build=PASS
	[[ -z "$SOURCE_VERSION" && -z "$SOURCE_RESULTS_DIR" ]] || completed_build=SKIPPED
	local source_tarball source_prefix
	source_prefix=$(grep -oP '"Prefix":\s*"\K[^"]+' "$wf_dir/$publish_json" | head -1 || true)
	source_tarball="gs://gce-ciq-images-prod-artifacts/${image_name:-${source_prefix}-${version}}.tar.gz"
	_write_result "$name" "BUILD_STATUS=$completed_build" "BUILD_ATTEMPTS=$attempt" "BUILD_VERSION=$version" "SOURCE_TARBALL=$source_tarball"

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

	_write_result "$name" "PUBLISH_STATUS=RUNNING"

	# ---- Pre-publish: target environment, fail closed on lookup/delete errors ----
	local build_status_label=PASS
	[[ -z "$SOURCE_VERSION" && -z "$SOURCE_RESULTS_DIR" ]] || build_status_label=SKIPPED
	local image_prefix published_image lookup_err
	image_prefix=$(grep -oP '"Prefix":\s*"\K[^"]+' "$wf_dir/$publish_json" | head -1 || true)
	if [[ -z "$image_prefix" ]]; then
		_write_result "$name" "BUILD_STATUS=$build_status_label" "BUILD_ATTEMPTS=$attempt" "BUILD_VERSION=$version" "PUBLISH_STATUS=FAIL" "PUBLISH_REASON=missing-image-prefix"
		return
	fi
	published_image="${image_prefix}-${PUBLISH_VERSION}"
	lookup_err="$LOG_DIR/$name.image-lookup.err"
	if gcloud compute images describe "$published_image" --project="${target_project}" --quiet >/dev/null 2>"$lookup_err"; then
		if [[ "$IF_IMAGE_EXISTS" == "fail" ]]; then
			_write_result "$name" "PUBLISH_STATUS=FAIL" "PUBLISH_REASON=image-already-exists"
			return
		fi
		if [[ "$IF_IMAGE_EXISTS" == "skip" ]]; then
			_write_result "$name" "BUILD_STATUS=$build_status_label" "BUILD_ATTEMPTS=$attempt" "BUILD_VERSION=$version" "PUBLISH_STATUS=SKIPPED" "PUBLISH_REASON=existing-image-unverified"
			return
		fi
		if ! gcloud compute images delete "$published_image" --project="${target_project}" --quiet >"$LOG_DIR/$name.image-delete.log" 2>&1; then
			_write_result "$name" "BUILD_STATUS=$build_status_label" "BUILD_ATTEMPTS=$attempt" "BUILD_VERSION=$version" "PUBLISH_STATUS=FAIL" "PUBLISH_REASON=image-delete-failed"
			return
		fi
		if gcloud compute images describe "$published_image" --project="${target_project}" --quiet >/dev/null 2>"$lookup_err" ||
			! grep -Fq "The resource 'projects/${target_project}/global/images/$published_image' was not found" "$lookup_err"; then
			_write_result "$name" "PUBLISH_STATUS=FAIL" "PUBLISH_REASON=image-delete-verification-failed"
			return
		fi
	elif ! grep -Fq "The resource 'projects/${target_project}/global/images/$published_image' was not found" "$lookup_err"; then
		_write_result "$name" "BUILD_STATUS=$build_status_label" "BUILD_ATTEMPTS=$attempt" "BUILD_VERSION=$version" "PUBLISH_STATUS=FAIL" "PUBLISH_REASON=image-lookup-failed"
		return
	fi

	local pub_attempt=1
	while true; do
		_write_result "$name" "PUBLISH_ATTEMPTS=$pub_attempt"
		local pub_log="$LOG_DIR/${name}.publish.attempt${pub_attempt}.log"
		echo "[$name] Publish attempt $pub_attempt (version=$version)..."

		if podman run --pull=newer \
			"${PUBLISH_CREDS[@]}" \
			-v "${wf_dir}:/workflows:z" \
			gcr.io/compute-image-tools/gce_image_publish:latest \
			-source_gcs_path gs://gce-ciq-images-prod-artifacts \
			-source_version "$version" \
			-no_root -skip_confirmation -publish_version "$PUBLISH_VERSION" \
			-var:environment="$ENVIRONMENT" \
			"${PUBLISH_EXTRA_ARGS[@]}" \
			/workflows/"$publish_json" >"$pub_log" 2>&1; then
			local readback="$LOG_DIR/$name.publish.readback.json" verified
			published_image="${image_prefix}-${PUBLISH_VERSION}"
			if gcloud compute images describe "$published_image" --project="${target_project}" --format=json >"$readback" 2>"$LOG_DIR/$name.publish.readback.err" &&
				verified=$(python3 "$DATA_HELPER" verify "$readback" "${target_project}" "$published_image" "$source_tarball"); then
				_write_result "$name" "BUILD_STATUS=$build_status_label" "BUILD_ATTEMPTS=$attempt" "BUILD_VERSION=$version" "PUBLISH_STATUS=PASS" "PUBLISH_ATTEMPTS=$pub_attempt" "PUBLISHED_IMAGES=$verified"
				return
			fi
			# Do not republish a possibly-created image on a readback failure.
			_write_result "$name" "PUBLISH_STATUS=FAIL" "PUBLISH_ATTEMPTS=$pub_attempt" "PUBLISH_REASON=publish-verification-failed"
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
pid_names=()
CANCELLED=false
CANCEL_SIGNAL=""
_cancel() {
	CANCELLED=true
	CANCEL_SIGNAL="$1"
	trap '' INT TERM
	local pid
	# Job control gives each worker its own group. Children and grandchildren
	# inherit that group; TERM then KILL also handles children ignoring TERM.
	for pid in "${pids[@]}"; do kill -TERM -- "-$pid" 2>/dev/null || true; done
	sleep 0.2
	for pid in "${pids[@]}"; do kill -KILL -- "-$pid" 2>/dev/null || true; done
}
trap '_cancel INT' INT
trap '_cancel TERM' TERM
set -m
# Initialize every selection so even an unlaunched/cancelled worker has a result.
for name in "${all_names[@]}"; do _write_result "$name"; done
echo "=== Launching ${#all_names[@]} workflow pipelines (logs=$LOG_DIR) ==="
for name in "${all_names[@]}"; do
	$CANCELLED && break
	# Disable monitor mode inside workers, keeping subprocess trees together.
	(
		set +m
		trap - INT TERM
		run_pipeline "$name"
	) &
	pids+=("$!")
	pid_names+=("$name")
	# A signal between fork and tracking is handled before any further launch.
	if $CANCELLED; then
		kill -KILL -- "-${pids[-1]}" 2>/dev/null || true
		break
	fi
	echo "  + $name (PID $!)"
done

for index in "${!pids[@]}"; do
	pid="${pids[$index]}"
	wait_status=0
	wait "$pid" || wait_status=$?
	# wait can return early when interrupted; reap the tracked worker as well.
	if $CANCELLED; then wait "$pid" 2>/dev/null || wait_status=$?; fi
	if ! $CANCELLED; then
		if [[ $wait_status -ne 0 ]]; then
			kill -TERM -- "-$pid" 2>/dev/null || true
			sleep 0.2
			kill -KILL -- "-$pid" 2>/dev/null || true
		fi
		_finish_result "${pid_names[$index]}" "worker-exited-$wait_status"
	fi
	_write_result "${pid_names[$index]}" "WORKER_EXIT_STATUS=$wait_status"
done
if $CANCELLED; then
	for name in "${all_names[@]}"; do
		_finish_result "$name" "cancelled-$CANCEL_SIGNAL" CANCELLED
	done
fi
set +m
redaction_failed=false
python3 "$DATA_HELPER" redact "$LOG_DIR" <<<"$REDACTION_RULES" || redaction_failed=true
unset REDACTION_RULES

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
	worker_exit=$(_get_field "$result_file" WORKER_EXIT_STATUS)

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

	if [[ -z "$pub_status" || "$pub_status" == NOT_ATTEMPTED ]]; then
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

	if [[ "$worker_exit" != 0 ]]; then
		echo "  [$name] worker exited $worker_exit (completed stage results retained)" >&2
		((overall_fail++)) || true
	fi
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

source_mode=build
[[ -z "$SOURCE_VERSION" ]] || source_mode=version
[[ -z "$SOURCE_RESULTS_DIR" ]] || source_mode=results
repo_commit=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)
versions_csv=$(
	IFS=,
	echo "${VERSIONS[*]}"
)
python3 "$DATA_HELPER" summary "$LOG_DIR" "$ENVIRONMENT" \
	"$MAX_RETRIES" "$SKIP_PUBLISH" "$IF_IMAGE_EXISTS" "$PUBLISH_VERSION" "$repo_commit" \
	"$source_mode" "$SOURCE_VERSION" "$versions_csv" "$YES" "${CANCELLED:-false}" "${all_names[@]}"
if $CANCELLED; then
	[[ "$CANCEL_SIGNAL" == INT ]] && exit 130
	exit 143
fi
$redaction_failed && error "artifact redaction failed; do not archive logs"
[[ $overall_fail -eq 0 ]]