#!/usr/bin/env bash
# Hourly snapshot of CloudRAN operator versions per OCP major.minor.
#
# Expected behaviour (1-to-1 mapping):
#   Each OCP z-stream release maps to a fixed set of operator versions.
#   When a NEW z-stream appears, it goes to pending/ until it reaches the fast channel
#   (catalog is ready within hours of fast promotion). Baseline is then locked.
#   On subsequent runs with NO new OCP release the catalog is still checked:
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
PENDING_DIR="$REPO_DIR/pending"

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
command -v skopeo >/dev/null 2>&1 || die "skopeo not found (required for digest-based catalog cache)"

# ---------------------------------------------------------------------------
# Catalog helpers
# ---------------------------------------------------------------------------

is_in_fast_channel() {
  local major_minor="$1" zstream="$2"
  curl -fsSL "https://api.openshift.com/api/upgrades_info/v1/graph?channel=fast-${major_minor}&arch=amd64" 2>/dev/null \
    | jq -r --arg v "$zstream" '[.nodes[] | select(.version==$v)] | length > 0' 2>/dev/null
}

get_latest_zstream() {
  local major_minor="$1"
  # Scrape the mirror index directly — the floating latest-<mm> pointer often
  # lags behind by hours after a new z-stream is published.
  curl -fsSL "https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/" 2>/dev/null \
    | grep -oE "${major_minor//./\\.}\\.[0-9]+" \
    | sort -t. -k3 -n \
    | uniq \
    | tail -1
}

refresh_catalog_cache() {
  local version="$1"
  # Check if the catalog image digest changed since last fetch.
  # This is a cheap skopeo inspect (~1s) vs re-downloading 180MB every hour.
  for catalog_type in redhat-operator certified-operator; do
    local index_image="registry.redhat.io/redhat/${catalog_type}-index:v${version}"
    local cache_json="/tmp/${catalog_type}-${version}.json"
    local digest_file="/tmp/${catalog_type}-${version}.digest"

    local current_digest
    current_digest=$(skopeo inspect --no-tags "docker://${index_image}" 2>/dev/null \
      | jq -r '.Digest // empty' 2>/dev/null) || true

    local cached_digest=""
    [[ -f "$digest_file" ]] && cached_digest=$(cat "$digest_file")

    if [[ -n "$current_digest" && "$current_digest" == "$cached_digest" && -f "$cache_json" ]]; then
      log "Catalog ${catalog_type}:v${version} unchanged (digest match) — reusing cache"
      continue
    fi

    log "Catalog ${catalog_type}:v${version} changed or missing — fetching"
    rm -f "$cache_json"
    if [[ "$catalog_type" == "redhat-operator" ]]; then
      "$OC_CATALOG" -v "$version" cloudran >/dev/null 2>&1 || true
    else
      "$OC_CATALOG" -v "$version" -c certified-operator versions sriov-fec >/dev/null 2>&1 || true
    fi
    [[ -n "$current_digest" ]] && echo "$current_digest" >"$digest_file"
  done
}

extract_versions() {
  local json_file="$1"
  local packages="$2"
  local overrides="${3:-}"
  [[ -f "$json_file" ]] || return 0

  jq -rs --arg pkgs "$packages" --arg overrides "$overrides" '
    def version_key:
      split("-") | (.[0] | split(".") | map(tonumber? // 0)) as $base
      | if length > 1 then $base + [(.[1] | tonumber? // 0)] else $base end;
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
#   EXISTING_ZSTREAMS (ordered array, newest first)
#   EXISTING_DATA[zstream:pkg]=version  (also holds _first_seen_at)
#   EXISTING_DETECTED_AT[zstream]=fast_promoted_at timestamp
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
    elif [[ -n "$current_zstream" && "$line" =~ ^[[:space:]]+_fast_promoted_at:\ (.+)$ ]]; then
      EXISTING_DETECTED_AT["$current_zstream"]="${BASH_REMATCH[1]}"
    elif [[ -n "$current_zstream" && "$line" =~ ^[[:space:]]+_first_seen_at:\ (.+)$ ]]; then
      EXISTING_DATA["${current_zstream}:_first_seen_at"]="${BASH_REMATCH[1]}"
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
      local first_seen="${EXISTING_DATA["${zs}:_first_seen_at"]:-}"
      local detected="${EXISTING_DETECTED_AT["${zs}"]:-}"
      [[ -n "$first_seen" ]] && echo "  _first_seen_at: ${first_seen}"
      [[ -n "$detected" ]]   && echo "  _fast_promoted_at: ${detected}"
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
# Pending state (z-streams seen but not yet in fast channel)
# pending/<mm>.yaml: "4.22.8": { _first_seen_at: <ts> }
# ---------------------------------------------------------------------------

_pending_strip() {
  local pending_file="$1" zstream="$2"
  awk -v hdr="\"${zstream}\":" '
    $0 == hdr { skip=1; next }
    /^"[0-9]+\.[0-9]+\.[0-9]+":$/ { skip=0 }
    !skip { print }
  ' "$pending_file"
}

get_pending_first_seen() {
  local pending_file="$1" zstream="$2"
  [[ -f "$pending_file" ]] || return 0
  awk -v hdr="\"${zstream}\":" '
    $0 == hdr { current=1; next }
    /^"[0-9]+\.[0-9]+\.[0-9]+":$/ { current=0 }
    current && /_first_seen_at:/ { sub(/.*_first_seen_at: */, ""); print; exit }
  ' "$pending_file"
}

list_pending() {
  local pending_file="$1"
  [[ -f "$pending_file" ]] || return 0
  grep -oE '^"[0-9]+\.[0-9]+\.[0-9]+":$' "$pending_file" | sed -E 's/^"//; s/":$//' | sort -u
}

add_pending() {
  local pending_file="$1" zstream="$2" first_seen="$3"
  mkdir -p "$PENDING_DIR"
  # Remove existing entry for this zstream if present, then append
  if [[ -f "$pending_file" ]]; then
    local tmp; tmp=$(mktemp)
    _pending_strip "$pending_file" "$zstream" >"$tmp" && mv "$tmp" "$pending_file"
  fi
  printf '"%s":\n  _first_seen_at: %s\n' "$zstream" "$first_seen" >>"$pending_file"
}

remove_pending() {
  local pending_file="$1" zstream="$2"
  [[ -f "$pending_file" ]] || return 0
  local tmp; tmp=$(mktemp)
  _pending_strip "$pending_file" "$zstream" >"$tmp" && mv "$tmp" "$pending_file"
  [[ -s "$pending_file" ]] || rm -f "$pending_file"
}

sort_zstreams_desc() {
  printf '%s\n' "$@" | sort -t. -k1,1nr -k2,2nr -k3,3nr | awk '!seen[$0]++'
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
  # One stable file per (major_minor, zstream) drift incident, not per hour —
  # re-alerting every hour for the same unresolved drift buried real issues
  # under noise. Deleting the file (once investigated) re-arms detection.
  local alert_file="$ALERTS_DIR/${major_minor}-${zstream}.md"
  if [[ -f "$alert_file" ]]; then
    log "Drift for ${zstream} already alerted (${alert_file}) — skipping duplicate"
    return 0
  fi

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
  local pending_file="$PENDING_DIR/${major_minor}.yaml"

  log "Processing OCP ${major_minor}..."

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

  # Check if this z-stream already has a baseline
  local is_baselined=false
  for existing in "${EXISTING_ZSTREAMS[@]+"${EXISTING_ZSTREAMS[@]}"}"; do
    [[ "$existing" == "$latest_zstream" ]] && { is_baselined=true; break; }
  done

  if ! $is_baselined; then
    # New z-stream not seen before — record it as pending (waiting for fast channel)
    local first_seen
    first_seen=$(get_pending_first_seen "$pending_file" "$latest_zstream")
    if [[ -z "$first_seen" ]]; then
      add_pending "$pending_file" "$latest_zstream" "$NOW"
      log "New z-stream ${latest_zstream} — first seen, waiting for fast-${major_minor} promotion (catalog not ready yet)"
    fi
  fi

  # --- Sweep every pending z-stream for fast-channel promotion, not just the latest ---
  # A newer patch can appear on the mirror before an older one finishes promoting;
  # checking only "latest" would orphan the older one forever.
  local -a newly_baselined=()
  local zs
  while IFS= read -r zs; do
    [[ -z "$zs" ]] && continue
    local pending_first_seen
    pending_first_seen=$(get_pending_first_seen "$pending_file" "$zs")

    local in_fast
    in_fast=$(is_in_fast_channel "$major_minor" "$zs")
    if [[ "$in_fast" != "true" ]]; then
      log "z-stream ${zs} still not in fast-${major_minor} (first seen: ${pending_first_seen}) — waiting"
      continue
    fi

    log "z-stream ${zs} reached fast-${major_minor} — locking baseline (first seen: ${pending_first_seen})"
    refresh_catalog_cache "$major_minor"
    local versions_tsv
    versions_tsv=$(get_operator_versions "$major_minor" "$overrides")
    if [[ -z "$versions_tsv" ]]; then
      log "WARN: no operator versions extracted for ${major_minor}"
      continue
    fi

    EXISTING_DETECTED_AT["${zs}"]="${NOW}"
    EXISTING_DATA["${zs}:_first_seen_at"]="${pending_first_seen}"
    while IFS=$'\t' read -r pkg ver; do
      EXISTING_DATA["${zs}:${pkg}"]="$ver"
    done <<<"$versions_tsv"

    newly_baselined+=("$zs")
  done < <(list_pending "$pending_file")

  if [[ ${#newly_baselined[@]} -gt 0 ]]; then
    local -a all_zstreams
    all_zstreams=($(sort_zstreams_desc "${newly_baselined[@]}" "${EXISTING_ZSTREAMS[@]+"${EXISTING_ZSTREAMS[@]}"}"))
    mkdir -p "$SNAPSHOTS_DIR"
    write_yaml "$yaml_file" "${all_zstreams[@]}"
    write_markdown "$md_file" "$major_minor" "${all_zstreams[@]}"
    for zs in "${newly_baselined[@]}"; do
      remove_pending "$pending_file" "$zs"
      log "Baseline locked for ${zs} (fast-promoted)"
    done
    EXISTING_ZSTREAMS=("${all_zstreams[@]}")
    for zs in "${newly_baselined[@]}"; do
      [[ "$zs" == "$latest_zstream" ]] && is_baselined=true
    done
  fi

  if $is_baselined; then
    # --- Baselined z-stream: check for operator drift ---
    refresh_catalog_cache "$major_minor"
    local versions_tsv2
    versions_tsv2=$(get_operator_versions "$major_minor" "$overrides")
    [[ -z "$versions_tsv2" ]] && { log "WARN: no operator versions extracted for ${major_minor}"; return 0; }

    local -a drifts=()
    while IFS=$'\t' read -r pkg current_ver; do
      local baseline="${EXISTING_DATA["${latest_zstream}:${pkg}"]:-}"
      if [[ -n "$baseline" && "$current_ver" != "$baseline" ]]; then
        drifts+=("${pkg}|${baseline}|${current_ver}")
        log "DRIFT: ${pkg} baseline=${baseline} current=${current_ver} (OCP still ${latest_zstream})"
      fi
    done <<<"$versions_tsv2"

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

  mkdir -p "$SNAPSHOTS_DIR" "$ALERTS_DIR" "$PENDING_DIR"

  for version in $OCP_VERSIONS; do
    process_version "$version" || true
  done

  cd "$REPO_DIR"
  local changed
  changed=$(git status --porcelain snapshots/ alerts/ pending/ 2>/dev/null || true)
  if [[ -n "$changed" ]]; then
    git add snapshots/ alerts/ pending/
    git commit -m "operator snapshot ${TODAY}"
    if git remote get-url origin >/dev/null 2>&1; then
      if git push -u origin HEAD; then
        log "Pushed to remote"
      else
        log "ERROR: git push failed — commit ${TODAY} is local-only until this is fixed"
        exit 1
      fi
    else
      log "No remote configured, skipping push"
    fi
  else
    log "No changes — catalog matches all baselines"
  fi

  log "Done"
}

main "$@"
