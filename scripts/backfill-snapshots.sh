#!/usr/bin/env bash
# Backfill historical operator version snapshots for older OCP z-streams.
#
# For each z-stream not yet in the snapshot YAML, this script:
#   1. Gets the fast-channel promotion date from openshift/cincinnati-graph-data
#   2. Filters catalog bundles to those available at that date:
#      - Date-stamped versions (ptp, local-storage, sriov-network): parse from version string
#      - Semantic versions (cluster-logging, lifecycle-agent, etc.): skopeo inspect
#   3. Writes results into snapshots/<mm>.yaml and snapshots/<mm>.md
#
# Scope defaults (override via env vars):
#   BACKFILL_4_18=20   (latest N z-streams for 4.18)
#   BACKFILL_4_20=10   (latest N z-streams for 4.20)
#   BACKFILL_4_22=all  (all z-streams for 4.22)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SNAPSHOTS_DIR="$REPO_DIR/snapshots"

OCP_VERSIONS="${OCP_VERSIONS:-4.18 4.20 4.22}"
BACKFILL_4_18="${BACKFILL_4_18:-20}"
BACKFILL_4_20="${BACKFILL_4_20:-10}"
BACKFILL_4_22="${BACKFILL_4_22:-999}"

REDHAT_PACKAGES="cluster-logging lifecycle-agent local-storage-operator lvms-operator ptp-operator redhat-oadp-operator sriov-network-operator"
CERTIFIED_PACKAGES="sriov-fec"
ALL_PACKAGES="cluster-logging lifecycle-agent local-storage-operator lvms-operator ptp-operator redhat-oadp-operator sriov-fec sriov-network-operator"

OC_CATALOG="${OC_CATALOG:-oc-catalog.sh}"

CHANNEL_OVERRIDES_4_18="${CHANNEL_OVERRIDES_4_18:-cluster-logging=stable-6.4}"
CHANNEL_OVERRIDES_4_20="${CHANNEL_OVERRIDES_4_20:-cluster-logging=stable-6.4}"
CHANNEL_OVERRIDES_4_22="${CHANNEL_OVERRIDES_4_22:-}"

# Auth discovery for opm
if [[ -z "${DOCKER_CONFIG:-}" ]]; then
  for d in "$HOME/.config/containers" "$HOME/.docker"; do
    if [[ -f "$d/config.json" || -f "$d/auth.json" ]]; then
      export DOCKER_CONFIG="$d"
      break
    fi
  done
fi

DATE_CACHE_DIR="${TMPDIR:-/tmp}/bundle-dates"
mkdir -p "$DATE_CACHE_DIR"

log() { echo "[$(date +%Y-%m-%dT%H:%M:%S)] $*" >&2; }

to_epoch() {
  local ts="$1"
  date -u -d "$ts" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null || echo 0
}

# ---------------------------------------------------------------------------
# Cincinnati helpers
# ---------------------------------------------------------------------------

get_fast_promotion_date() {
  local major_minor="$1" zstream="$2"
  curl -fsSL \
    "https://api.github.com/repos/openshift/cincinnati-graph-data/commits?path=channels/fast-${major_minor}.yaml&per_page=100" \
    2>/dev/null \
    | jq -r --arg zs "$zstream" \
        '[.[] | select(.commit.message | test($zs)) | .commit.committer.date] | .[0] // ""' \
    || true
}

# ---------------------------------------------------------------------------
# Mirror index
# ---------------------------------------------------------------------------

list_zstreams() {
  local major_minor="$1" count="$2"
  curl -fsSL "https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/" 2>/dev/null \
    | grep -oE "${major_minor//./\\.}\\.[0-9]+" \
    | sort -t. -k3 -n \
    | uniq \
    | tail -"$count" || true
}

# ---------------------------------------------------------------------------
# Bundle image date cache (for semantic versions)
# ---------------------------------------------------------------------------

get_bundle_image_date() {
  local image="$1"
  [[ -z "$image" || "$image" == "null" ]] && return 0
  local cache_key; cache_key=$(printf '%s' "$image" | sha256sum 2>/dev/null | cut -c1-24 \
                               || printf '%s' "$image" | shasum -a 256 2>/dev/null | cut -c1-24 \
                               || printf '%s' "$image" | cksum | awk '{print $1}')
  local cache_file="$DATE_CACHE_DIR/${cache_key}"
  if [[ -f "$cache_file" ]]; then
    cat "$cache_file"
    return 0
  fi
  local created=""
  created=$(skopeo inspect --no-tags "docker://${image}" 2>/dev/null \
            | jq -r '.Created // empty' 2>/dev/null) || true
  if [[ -n "$created" ]]; then
    echo "$created" | tee "$cache_file"
  fi
}

# ---------------------------------------------------------------------------
# Version extraction at a point in time
# ---------------------------------------------------------------------------

# Extract the 12-digit build timestamp from a date-stamped version string
version_ts12() { printf '%s' "$1" | grep -oE '[0-9]{12}' | head -1; }

# Convert YYYYMMDDHHII to epoch (Linux + macOS)
ts12_to_epoch() {
  local ts="$1"
  local y="${ts:0:4}" mo="${ts:4:2}" d="${ts:6:2}" h="${ts:8:2}" mi="${ts:10:2}"
  date -u -d "${y}-${mo}-${d} ${h}:${mi}:00" +%s 2>/dev/null \
    || date -u -j -f "%Y%m%d%H%M" "${ts:0:12}" +%s 2>/dev/null \
    || echo 0
}

# Get all (version, image) pairs for a package in its effective channel.
# Outputs tab-separated: version<TAB>image
get_all_bundles_for_package() {
  local json_file="$1" pkg="$2" overrides="$3"
  [[ -f "$json_file" ]] || return 0

  jq -rs --arg pkg "$pkg" --arg overrides "$overrides" '
    def parse_ovr:
      split(" ") | map(select(. != "") | split("=") | {(.[0]): .[1]}) | add // {};
    ($overrides | parse_ovr) as $ovr
    | ([.[] | select(.schema=="olm.package") | select(.name==$pkg)
        | ($ovr[$pkg] // .defaultChannel)] | .[0] // "") as $ch
    | if $ch == "" then empty else
      # Bundle names that are members of this specific channel
      ([.[] | select(.schema=="olm.channel")
        | select(.package==$pkg) | select(.name==$ch)
        | .entries[] | .name] | unique) as $ch_bundles
      # Only return bundles that appear in the channel
      | [.[] | select(.schema=="olm.bundle")
          | select(.package==$pkg)
          | select(.name as $n | $ch_bundles | index($n) != null)
          | {
              ver: ((.properties // [] | map(select(.type=="olm.package") | .value.version) | .[0])
                    // (.name | sub("^[^.]+\\.v"; ""))),
              img: (.image // "")
            }]
        | unique_by(.ver)
        | .[]
        | "\(.ver)\t\(.img)"
      end
  ' "$json_file"
}

# For one package, find the latest version whose build date <= cutoff_epoch.
# Date-stamped versions (e.g. v4.20.0-202607141720): date from version string (reliable).
# Semantic versions (e.g. v6.4.6): date from bundle image via skopeo (may be wrong if
#   Red Hat rebuilt the image). Fall back to version-number ordering if image date
#   is implausible (> cutoff by more than 30 days).
# Outputs: v<version>  or empty string
find_version_at_date() {
  local json_file="$1" pkg="$2" overrides="$3" cutoff_epoch="$4"

  # Collect all qualifying (bundle_epoch, ver) pairs
  local -a dated_vers=()   # "epoch ver" — for date-stamped (reliable)
  local -a semantic_vers=() # "epoch ver" — for semantic (may be unreliable)

  while IFS=$'\t' read -r ver img; do
    [[ -z "$ver" ]] && continue
    local bundle_epoch=0
    local is_datestamped=false

    local ts12; ts12=$(version_ts12 "$ver")
    if [[ -n "$ts12" ]]; then
      bundle_epoch=$(ts12_to_epoch "$ts12")
      is_datestamped=true
    elif [[ -n "$img" ]]; then
      local created; created=$(get_bundle_image_date "$img")
      [[ -n "$created" ]] && bundle_epoch=$(to_epoch "$created") || true
    fi

    if $is_datestamped; then
      [[ "$bundle_epoch" -gt 0 && "$bundle_epoch" -le "$cutoff_epoch" ]] \
        && dated_vers+=("${bundle_epoch} ${ver}")
    else
      # Semantic versions: Red Hat rebuilds bundle images, so skopeo dates are unreliable.
      # Accept within a 90-day window when the date is available and plausible;
      # otherwise include with epoch=1 as a fallback so version-number ordering
      # still selects the correct bundle rather than returning nothing.
      local window=$(( cutoff_epoch + 90*86400 ))
      if [[ "$bundle_epoch" -gt 0 && "$bundle_epoch" -le "$window" ]]; then
        semantic_vers+=("${bundle_epoch} ${ver}")
      else
        semantic_vers+=("1 ${ver}")
      fi
    fi
  done < <(get_all_bundles_for_package "$json_file" "$pkg" "$overrides")

  # For date-stamped: pick the one with the highest epoch <= cutoff
  if [[ ${#dated_vers[@]} -gt 0 ]]; then
    local best_ver=""
    local best_epoch=0
    for entry in "${dated_vers[@]}"; do
      local ep="${entry%% *}" v="${entry#* }"
      [[ "$ep" -gt "$best_epoch" ]] && { best_epoch="$ep"; best_ver="$v"; }
    done
    [[ -n "$best_ver" ]] && printf 'v%s' "${best_ver#v}" && return 0
  fi

  # For semantic: sort by version number (semver) and pick the highest
  # (channel filtering already scoped to the right stream, so highest = most recent)
  if [[ ${#semantic_vers[@]} -gt 0 ]]; then
    local best_ver
    best_ver=$(printf '%s\n' "${semantic_vers[@]}" \
      | awk '{print $2}' \
      | sort -t. -k1,1n -k2,2n -k3,3n \
      | tail -1)
    [[ -n "$best_ver" ]] && printf 'v%s' "${best_ver#v}"
  fi
}

# ---------------------------------------------------------------------------
# YAML helpers (reuse same format as main script)
# ---------------------------------------------------------------------------

declare -A BF_DATA         # [zstream:pkg]=version
declare -A BF_DETECTED     # [zstream]=fast_promoted_at
declare -A BF_FIRST_SEEN   # [zstream]=first_seen_at (OCP release date used as proxy)
declare -a BF_ZSTREAMS

parse_existing_yaml() {
  local yaml_file="$1"
  BF_DATA=(); BF_DETECTED=(); BF_FIRST_SEEN=(); BF_ZSTREAMS=()
  [[ -f "$yaml_file" ]] || return 0
  local cur=""
  while IFS= read -r line; do
    if   [[ "$line" =~ ^\"([0-9]+\.[0-9]+\.[0-9]+)\":$ ]]; then
      cur="${BASH_REMATCH[1]}"; BF_ZSTREAMS+=("$cur")
    elif [[ -n "$cur" && "$line" =~ ^[[:space:]]+_fast_promoted_at:\ (.+)$ ]]; then
      BF_DETECTED["$cur"]="${BASH_REMATCH[1]}"
    elif [[ -n "$cur" && "$line" =~ ^[[:space:]]+_first_seen_at:\ (.+)$ ]]; then
      BF_FIRST_SEEN["$cur"]="${BASH_REMATCH[1]}"
    elif [[ -n "$cur" && "$line" =~ ^[[:space:]]+([a-z][a-z0-9-]*):\ (.+)$ ]]; then
      BF_DATA["${cur}:${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
    fi
  done <"$yaml_file"
}

write_yaml() {
  local yaml_file="$1"; shift
  local -a zstreams=("$@")
  {
    echo "# Last updated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for zs in "${zstreams[@]}"; do
      echo "\"${zs}\":"
      local fs="${BF_FIRST_SEEN[$zs]:-}"; [[ -n "$fs" ]] && echo "  _first_seen_at: ${fs}"
      local fp="${BF_DETECTED[$zs]:-}";   [[ -n "$fp" ]] && echo "  _fast_promoted_at: ${fp}"
      for pkg in $ALL_PACKAGES; do
        local v="${BF_DATA["${zs}:${pkg}"]:-}"; [[ -n "$v" ]] && echo "  ${pkg}: ${v}"
      done
    done
  } >"$yaml_file"
}

write_markdown() {
  local md_file="$1" major_minor="$2"; shift 2
  local -a zstreams=("$@")
  local latest_count=5
  local -a latest=() older=()
  local i=0
  for zs in "${zstreams[@]}"; do
    (( i < latest_count )) && latest+=("$zs") || older+=("$zs")
    (( i += 1 )) || true
  done

  _md_table() {
    local -a cols=("$@")
    printf "| Operator |"
    for zs in "${cols[@]}"; do
      local fp="${BF_DETECTED[$zs]:-}"; [[ -n "$fp" ]] && printf " %s (%s) |" "$zs" "$fp" || printf " %s |" "$zs"
    done; echo
    printf "|----------|"; for _ in "${cols[@]}"; do printf -- "-----------------|"; done; echo
    for pkg in $ALL_PACKAGES; do
      printf "| %s |" "$pkg"
      for zs in "${cols[@]}"; do printf " %s |" "${BF_DATA["${zs}:${pkg}"]:-}"; done
      echo
    done
  }

  {
    echo "# OCP ${major_minor} CloudRAN Operator Versions"
    echo; echo "Last updated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"; echo
    [[ ${#latest[@]} -gt 0 ]] && _md_table "${latest[@]}"
    if [[ ${#older[@]} -gt 0 ]]; then
      echo; echo "## Older releases"; echo
      _md_table "${older[@]}"
    fi
  } >"$md_file"
}

# ---------------------------------------------------------------------------
# Backfill one z-stream
# ---------------------------------------------------------------------------

backfill_zstream() {
  local major_minor="$1" zstream="$2" overrides="$3"

  # Skip if already in snapshot
  for existing in "${BF_ZSTREAMS[@]+"${BF_ZSTREAMS[@]}"}"; do
    [[ "$existing" == "$zstream" ]] && { log "  $zstream — already baselined, skipping"; return 0; }
  done

  log "  $zstream — fetching fast-promotion date..."
  local fast_date
  fast_date=$(get_fast_promotion_date "$major_minor" "$zstream")
  if [[ -z "$fast_date" ]]; then
    log "  $zstream — not yet in fast channel, skipping"
    return 0
  fi
  local cutoff_epoch; cutoff_epoch=$(to_epoch "$fast_date")
  log "  $zstream — fast promoted: $fast_date"

  # OCP release date as _first_seen_at proxy
  local ocp_date
  ocp_date=$(curl -fsSL "https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/${zstream}/release.txt" 2>/dev/null \
    | awk -F': +' '/^Created:/{print $2; exit}') || true

  local redhat_json="/tmp/redhat-operator-${major_minor}.json"
  local certified_json="/tmp/certified-operator-${major_minor}.json"

  local any_found=false
  for pkg in $REDHAT_PACKAGES; do
    local ver; ver=$(find_version_at_date "$redhat_json" "$pkg" "$overrides" "$cutoff_epoch")
    if [[ -n "$ver" ]]; then
      BF_DATA["${zstream}:${pkg}"]="$ver"
      any_found=true
    fi
  done
  for pkg in $CERTIFIED_PACKAGES; do
    local ver; ver=$(find_version_at_date "$certified_json" "$pkg" "" "$cutoff_epoch")
    if [[ -n "$ver" ]]; then
      BF_DATA["${zstream}:${pkg}"]="$ver"
      any_found=true
    fi
  done

  if $any_found; then
    BF_DETECTED["$zstream"]="$fast_date"
    [[ -n "$ocp_date" ]] && BF_FIRST_SEEN["$zstream"]="$ocp_date"
    BF_ZSTREAMS+=("$zstream")
    log "  $zstream — done"
  else
    log "  $zstream — no operator versions found (catalog may not reach that far back)"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  command -v "$OC_CATALOG" >/dev/null 2>&1 || { echo "ERROR: oc-catalog.sh not found" >&2; exit 2; }
  command -v skopeo       >/dev/null 2>&1 || { echo "ERROR: skopeo not found" >&2; exit 2; }
  command -v jq           >/dev/null 2>&1 || { echo "ERROR: jq not found" >&2; exit 2; }

  mkdir -p "$SNAPSHOTS_DIR"

  for major_minor in $OCP_VERSIONS; do
    local override_var="CHANNEL_OVERRIDES_${major_minor//./_}"
    local overrides="${!override_var:-}"

    local count_var="BACKFILL_${major_minor//./_}"
    local count="${!count_var:-10}"

    log "=== OCP ${major_minor} (backfill latest ${count} z-streams) ==="

    # Ensure catalog cache exists
    log "  Warming catalog cache for ${major_minor}..."
    "$OC_CATALOG" -v "$major_minor" cloudran >/dev/null 2>&1 || true
    "$OC_CATALOG" -v "$major_minor" -c certified-operator versions sriov-fec >/dev/null 2>&1 || true

    local yaml_file="$SNAPSHOTS_DIR/${major_minor}.yaml"
    local md_file="$SNAPSHOTS_DIR/${major_minor}.md"
    parse_existing_yaml "$yaml_file"

    # Collect z-streams to backfill (oldest first so we insert in right order)
    local -a target_zstreams=()
    while IFS= read -r zs; do target_zstreams+=("$zs"); done \
      < <(list_zstreams "$major_minor" "$count")

    for zs in "${target_zstreams[@]}"; do
      backfill_zstream "$major_minor" "$zs" "$overrides"
    done

    # Sort all z-streams newest-first and write
    local -a sorted_zstreams=()
    while IFS= read -r zs; do sorted_zstreams+=("$zs"); done \
      < <(printf '%s\n' "${BF_ZSTREAMS[@]+"${BF_ZSTREAMS[@]}"}" \
          | sort -t. -k3 -n -r | uniq)

    if [[ ${#sorted_zstreams[@]} -gt 0 ]]; then
      write_yaml "$yaml_file" "${sorted_zstreams[@]}"
      write_markdown "$md_file" "$major_minor" "${sorted_zstreams[@]}"
      log "=== OCP ${major_minor} — snapshot written (${#sorted_zstreams[@]} z-streams)"
    fi
  done

  # Commit everything
  cd "$REPO_DIR"
  local changed
  changed=$(git status --porcelain snapshots/ 2>/dev/null || true)
  if [[ -n "$changed" ]]; then
    git add snapshots/
    git commit -m "backfill historical operator snapshots

4.18: latest ${BACKFILL_4_18} z-streams
4.20: latest ${BACKFILL_4_20} z-streams
4.22: all z-streams"
    git push && log "Pushed to remote"
  else
    log "No new data — all target z-streams already baselined"
  fi
}

main "$@"
