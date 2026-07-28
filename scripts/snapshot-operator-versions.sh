#!/usr/bin/env bash
# Daily snapshot of CloudRAN operator versions per OCP major.minor.
#
# Expected behaviour (1-to-1 mapping):
#   Each OCP z-stream release maps to a fixed set of operator versions.
#   When a NEW z-stream appears the current catalog state is captured as baseline.
#   On subsequent days with NO new OCP release the catalog is still checked:
#     - if operator versions match the baseline → no-op
#     - if any version changed without a new OCP release → ALERT file created in alerts/
#
# Outputs per major.minor:
#   snapshots/<mm>.yaml  – baseline versions per z-stream (machine-readable)
#   snapshots/<mm>.md    – markdown table, latest 5 z-streams + older archive
#   alerts/<mm>-<date>.md – created when drift is detected (no new OCP, changed version)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SNAPSHOTS_DIR="$REPO_DIR/snapshots"
ALERTS_DIR="$REPO_DIR/alerts"

OCP_VERSIONS="${OCP_VERSIONS:-4.18 4.20 4.22}"
LATEST_COUNT=5

REDHAT_PACKAGES="cluster-logging lifecycle-agent local-storage-operator lvms-operator ptp-operator redhat-oadp-operator sriov-network-operator"
CERTIFIED_PACKAGES="sriov-fec"
ALL_PACKAGES="cluster-logging lifecycle-agent local-storage-operator lvms-operator ptp-operator redhat-oadp-operator sriov-fec sriov-network-operator"

OC_CATALOG="${OC_CATALOG:-oc-catalog.sh}"

# Per-version channel overrides (space-separated pkg=channel pairs).
# Use variable name CHANNEL_OVERRIDES_<major>_<minor> to override per version.
CHANNEL_OVERRIDES_4_18="${CHANNEL_OVERRIDES_4_18:-cluster-logging=stable-6.4}"
CHANNEL_OVERRIDES_4_20="${CHANNEL_OVERRIDES_4_20:-cluster-logging=stable-6.4}"
CHANNEL_OVERRIDES_4_22="${CHANNEL_OVERRIDES_4_22:-}"
TODAY=$(date -u +%Y-%m-%d)
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
NOW_HOUR=$(date -u +%Y-%m-%dT%H)

# Auth discovery for DOCKER_CONFIG (needed by opm)
if [[ -z "${DOCKER_CONFIG:-}" ]]; then
  for d in "$HOME/.config/containers" "$HOME/.docker"; do
    if [[ -f "$d/config.json" || -f "$d/auth.json" ]]; then
      export DOCKER_CONFIG="$d"
      break
    fi
  done
fi

die() { echo "ERROR: $*" >&2; exit 2; }
log() { echo "[$(date +%Y-%m-%dT%H:%M:%S)] $*" >&2; }

command -v "$OC_CATALOG" >/dev/null 2>&1 || die "oc-catalog.sh not found in PATH"
command -v jq >/dev/null 2>&1 || die "jq not found"
command -v curl >/dev/null 2>&1 || die "curl not found"

# ---------------------------------------------------------------------------
# Catalog helpers
# ---------------------------------------------------------------------------

get_latest_zstream() {
  local major_minor="$1"
  curl -fsSL "https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/latest-${major_minor}/release.txt" 2>/dev/null \
    | awk -F': +' '/^Name:/{print $2; exit}'
}

refresh_catalog_cache() {
  local version="$1"
  log "Refreshing redhat-operator catalog for $version"
  "$OC_CATALOG" -v "$version" cloudran >/dev/null 2>&1 || true
  log "Refreshing certified-operator catalog for $version"
  "$OC_CATALOG" -v "$version" -c certified-operator versions sriov-fec >/dev/null 2>&1 || true
}

extract_versions() {
  local json_file="$1"
  local packages="$2"
  local overrides="${3:-}"
  [[ -f "$json_file" ]] || return 0

  jq -rs --arg pkgs "$packages" --arg overrides "$overrides" '
    def version_key:
      split("-") | .[0] | split(".") | map(tonumber? // 0);
    ($overrides | split(" ") | map(select(. != "") | split("=") | {(.[0]): .[1]}) | add // {}) as $ovr
    | ($pkgs | split(" ")) as $wanted
    | ([.[] | select(.schema=="olm.package")
        | select(.name as $n | $wanted | index($n))
        | {(.name): ($ovr[.name] // .defaultChannel)}] | add // {}) as $defaults
    | ([.[] | select(.schema=="olm.bundle")
        | select(.package as $p | $wanted | index($p))
        | {(.name): {
            pkg: .package,
            ver: ((.properties // [] | map(select(.type=="olm.package") | .value.version) | .[0])
                  // (.name | sub("^.*\\.v"; "") | sub("-[0-9]+$"; "")))
          }}] | add // {}) as $bundles
    | [.[] | select(.schema=="olm.channel")
        | select($defaults[.package] == .name)
        | .package as $p | .entries[]
        | {pkg: $p, bundle: (.name // .), ver: (($bundles[.name // .].ver) // "")}]
    | group_by(.pkg)
    | map(sort_by(.ver | version_key) | reverse | .[0])
    | .[]
    | "\(.pkg)\tv\(.ver)"
  ' "$json_file"
}

get_operator_versions() {
  local version="$1"
  local overrides="$2"
  {
    extract_versions "/tmp/redhat-operator-${version}.json" "$REDHAT_PACKAGES" "$overrides"
    extract_versions "/tmp/certified-operator-${version}.json" "$CERTIFIED_PACKAGES" "$overrides"
  } | sort -t$'\t' -k1,1
}

# ---------------------------------------------------------------------------
# YAML read/write
# ---------------------------------------------------------------------------

# Sets globals:
#   EXISTING_ZSTREAMS (ordered array)
#   EXISTING_DATA[zstream:pkg]=version
#   EXISTING_DETECTED_AT[zstream]=timestamp
declare -A EXISTING_DATA
declare -A EXISTING_DETECTED_AT
declare -a EXISTING_ZSTREAMS

parse_existing_yaml() {
  local yaml_file="$1"
  EXISTING_DATA=()
  EXISTING_DETECTED_AT=()
  EXISTING_ZSTREAMS=()
  [[ -f "$yaml_file" ]] || return 0

  local current_zstream=""
  while IFS= read -r line; do
    if [[ "$line" =~ ^\"([0-9]+\.[0-9]+\.[0-9]+)\":$ ]]; then
      current_zstream="${BASH_REMATCH[1]}"
      EXISTING_ZSTREAMS+=("$current_zstream")
    elif [[ -n "$current_zstream" && "$line" =~ ^[[:space:]]+_detected_at:\ (.+)$ ]]; then
      EXISTING_DETECTED_AT["$current_zstream"]="${BASH_REMATCH[1]}"
    elif [[ -n "$current_zstream" && "$line" =~ ^[[:space:]]+([a-z][a-z0-9-]*):\ (.+)$ ]]; then
      EXISTING_DATA["${current_zstream}:${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
    fi
  done <"$yaml_file"
}

write_yaml() {
  local yaml_file="$1"; shift
  local -a zstreams=("$@")
  {
    echo "# Last updated: ${NOW}"
    for zs in "${zstreams[@]}"; do
      echo "\"${zs}\":"
      local detected="${EXISTING_DETECTED_AT["${zs}"]:-}"
      [[ -n "$detected" ]] && echo "  _detected_at: ${detected}"
      for pkg in $ALL_PACKAGES; do
        local val="${EXISTING_DATA["${zs}:${pkg}"]:-}"
        [[ -n "$val" ]] && echo "  ${pkg}: ${val}"
      done
    done
  } >"$yaml_file"
}

write_markdown() {
  local md_file="$1"
  local major_minor="$2"; shift 2
  local -a zstreams=("$@")

  local -a latest=() older=()
  local i=0
  for zs in "${zstreams[@]}"; do
    (( i < LATEST_COUNT )) && latest+=("$zs") || older+=("$zs")
    (( i += 1 )) || true
  done

  {
    echo "# OCP ${major_minor} CloudRAN Operator Versions"
    echo
    echo "Last updated: ${NOW}"
    echo

    _md_table() {
      local -a cols=("$@")
      printf "| Operator |"
      for zs in "${cols[@]}"; do
        local dt="${EXISTING_DETECTED_AT["${zs}"]:-}"
        [[ -n "$dt" ]] && printf " %s (%s) |" "$zs" "$dt" || printf " %s |" "$zs"
      done; echo
      printf "|----------|"; for _ in "${cols[@]}"; do printf -- "-----------------|"; done; echo
      for pkg in $ALL_PACKAGES; do
        printf "| %s |" "$pkg"
        for zs in "${cols[@]}"; do printf " %s |" "${EXISTING_DATA["${zs}:${pkg}"]:-}"; done
        echo
      done
    }

    [[ ${#latest[@]} -gt 0 ]] && _md_table "${latest[@]}"

    if [[ ${#older[@]} -gt 0 ]]; then
      echo; echo "## Older releases"; echo
      _md_table "${older[@]}"
    fi
  } >"$md_file"
}

# ---------------------------------------------------------------------------
# Alert file
# ---------------------------------------------------------------------------

write_alert() {
  local major_minor="$1"
  local zstream="$2"
  local zstream_detected="${EXISTING_DETECTED_AT["${zstream}"]:-unknown}"
  # drifts: array of "pkg|baseline|current" strings
  local -a drifts=("${@:3}")

  mkdir -p "$ALERTS_DIR"
  # Hourly filename so each detection gets its own file
  local alert_file="$ALERTS_DIR/${major_minor}-${NOW_HOUR}.md"

  {
    echo "# ALERT: Operator version drift detected for OCP ${major_minor}"
    echo
    echo "**Detected at:** ${NOW}"
    echo "**Current OCP z-stream:** ${zstream}"
    echo "**z-stream first appeared:** ${zstream_detected}"
    echo
    echo "Operator versions in the catalog changed without a corresponding OCP z-stream release."
    echo "This breaks the expected 1-to-1 mapping between OCP release and operator versions."
    echo
    echo "## Changed operators"
    echo
    echo "| Operator | Baseline (at ${zstream} release) | Current catalog | Drift after |"
    echo "|----------|----------------------------------|-----------------|-------------|"
    for drift in "${drifts[@]}"; do
      IFS='|' read -r pkg baseline current <<<"$drift"
      # Calculate hours since z-stream was detected
      local drift_info=""
      if [[ "$zstream_detected" != "unknown" ]]; then
        local zs_epoch base_epoch drift_hours
        zs_epoch=$(date -u -d "${zstream_detected}" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "${zstream_detected}" +%s 2>/dev/null || echo 0)
        base_epoch=$(date -u +%s 2>/dev/null || date -u -j +%s 2>/dev/null || echo 0)
        if [[ "$zs_epoch" -gt 0 && "$base_epoch" -gt 0 ]]; then
          drift_hours=$(( (base_epoch - zs_epoch) / 3600 ))
          drift_info="${drift_hours}h after OCP release"
        fi
      fi
      echo "| ${pkg} | ${baseline} | **${current}** | ${drift_info} |"
    done
    echo
    echo "## Action required"
    echo
    echo "- Verify whether the new operator version is intentional"
    echo "- If a hotfix was pushed to the catalog outside an OCP release cycle, update the baseline"
    echo "- Close this alert by deleting this file once investigated"
  } >"$alert_file"

  log "ALERT created: $alert_file"
}

# ---------------------------------------------------------------------------
# Per-version processing
# ---------------------------------------------------------------------------

process_version() {
  local major_minor="$1"
  local yaml_file="$SNAPSHOTS_DIR/${major_minor}.yaml"
  local md_file="$SNAPSHOTS_DIR/${major_minor}.md"

  log "Processing OCP ${major_minor}..."

  # Resolve per-version channel overrides
  local override_var="CHANNEL_OVERRIDES_${major_minor//./_}"
  local overrides="${!override_var:-}"
  [[ -n "$overrides" ]] && log "Channel overrides: $overrides"

  local latest_zstream
  latest_zstream=$(get_latest_zstream "$major_minor")
  if [[ -z "$latest_zstream" ]]; then
    log "WARN: could not detect latest z-stream for ${major_minor}, skipping"
    return 0
  fi
  log "Latest z-stream: ${latest_zstream}"

  parse_existing_yaml "$yaml_file"

  # Always refresh catalog and capture today's versions
  refresh_catalog_cache "$major_minor"
  local versions_tsv
  versions_tsv=$(get_operator_versions "$major_minor" "$overrides")
  if [[ -z "$versions_tsv" ]]; then
    log "WARN: no operator versions extracted for ${major_minor}"
    return 0
  fi

  # Determine if this is a new z-stream
  local is_new_zstream=true
  for existing in "${EXISTING_ZSTREAMS[@]+"${EXISTING_ZSTREAMS[@]}"}"; do
    [[ "$existing" == "$latest_zstream" ]] && { is_new_zstream=false; break; }
  done

  if $is_new_zstream; then
    # --- New OCP z-stream: record baseline with detection timestamp ---
    log "New z-stream detected: ${latest_zstream} — recording baseline at ${NOW}"
    EXISTING_DETECTED_AT["${latest_zstream}"]="${NOW}"
    while IFS=$'\t' read -r pkg ver; do
      EXISTING_DATA["${latest_zstream}:${pkg}"]="$ver"
    done <<<"$versions_tsv"

    local -a all_zstreams=("$latest_zstream" "${EXISTING_ZSTREAMS[@]+"${EXISTING_ZSTREAMS[@]}"}")
    mkdir -p "$SNAPSHOTS_DIR"
    write_yaml "$yaml_file" "${all_zstreams[@]}"
    write_markdown "$md_file" "$major_minor" "${all_zstreams[@]}"
    log "Snapshots updated for ${latest_zstream}"

  else
    # --- Same z-stream: check for operator drift ---
    local -a drifts=()
    while IFS=$'\t' read -r pkg current_ver; do
      local baseline="${EXISTING_DATA["${latest_zstream}:${pkg}"]:-}"
      if [[ -n "$baseline" && "$current_ver" != "$baseline" ]]; then
        drifts+=("${pkg}|${baseline}|${current_ver}")
        log "DRIFT: ${pkg} baseline=${baseline} current=${current_ver} (OCP still ${latest_zstream})"
      fi
    done <<<"$versions_tsv"

    if [[ ${#drifts[@]} -gt 0 ]]; then
      write_alert "$major_minor" "$latest_zstream" "${drifts[@]}"
    else
      log "No drift for ${latest_zstream} — catalog matches baseline"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  log "Starting operator version snapshot (${TODAY})"
  log "OCP versions: $OCP_VERSIONS"

  mkdir -p "$SNAPSHOTS_DIR" "$ALERTS_DIR"

  for version in $OCP_VERSIONS; do
    process_version "$version" || true
  done

  cd "$REPO_DIR"
  local changed
  changed=$(git status --porcelain snapshots/ alerts/ 2>/dev/null || true)
  if [[ -n "$changed" ]]; then
    git add snapshots/ alerts/
    git commit -m "operator snapshot ${TODAY}"
    if git remote get-url origin >/dev/null 2>&1; then
      git push
      log "Pushed to remote"
    else
      log "No remote configured, skipping push"
    fi
  else
    log "No changes — catalog matches all baselines"
  fi

  log "Done"
}

main "$@"
