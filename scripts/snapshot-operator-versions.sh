#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SNAPSHOTS_DIR="$REPO_DIR/snapshots"

OCP_VERSIONS="${OCP_VERSIONS:-4.18 4.20 4.22}"
LATEST_COUNT=5

REDHAT_PACKAGES="cluster-logging lifecycle-agent local-storage-operator lvms-operator ptp-operator redhat-oadp-operator sriov-network-operator"
CERTIFIED_PACKAGES="sriov-fec"
ALL_PACKAGES="cluster-logging lifecycle-agent local-storage-operator lvms-operator ptp-operator redhat-oadp-operator sriov-fec sriov-network-operator"

OC_CATALOG="${OC_CATALOG:-oc-catalog.sh}"

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

get_latest_zstream() {
  local major_minor="$1"
  curl -fsSL "https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/latest-${major_minor}/release.txt" 2>/dev/null \
    | awk -F': +' '/^Name:/{print $2; exit}'
}

refresh_catalog_cache() {
  local version="$1"
  log "Refreshing redhat-operator catalog cache for $version"
  "$OC_CATALOG" -v "$version" cloudran >/dev/null 2>&1 || true
  log "Refreshing certified-operator catalog cache for $version"
  "$OC_CATALOG" -v "$version" -c certified-operator versions sriov-fec >/dev/null 2>&1 || true
}

extract_versions() {
  local json_file="$1"
  local packages="$2"
  [[ -f "$json_file" ]] || return 0

  jq -rs --arg pkgs "$packages" '
    def version_key:
      split("-") | .[0] | split(".") | map(tonumber? // 0);
    ($pkgs | split(" ")) as $wanted
    | ([.[] | select(.schema=="olm.package")
        | select(.name as $n | $wanted | index($n))
        | {(.name): .defaultChannel}] | add // {}) as $defaults
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
  local redhat_json="/tmp/redhat-operator-${version}.json"
  local certified_json="/tmp/certified-operator-${version}.json"

  {
    extract_versions "$redhat_json" "$REDHAT_PACKAGES"
    extract_versions "$certified_json" "$CERTIFIED_PACKAGES"
  } | sort -t$'\t' -k1,1
}

# Read existing YAML data into associative arrays
# Sets global: EXISTING_ZSTREAMS (ordered list), EXISTING_DATA[zstream:pkg]=version
declare -A EXISTING_DATA
declare -a EXISTING_ZSTREAMS

parse_existing_yaml() {
  local yaml_file="$1"
  EXISTING_DATA=()
  EXISTING_ZSTREAMS=()

  [[ -f "$yaml_file" ]] || return 0

  local current_zstream=""
  while IFS= read -r line; do
    if [[ "$line" =~ ^\"([0-9]+\.[0-9]+\.[0-9]+)\":$ ]]; then
      current_zstream="${BASH_REMATCH[1]}"
      EXISTING_ZSTREAMS+=("$current_zstream")
    elif [[ -n "$current_zstream" && "$line" =~ ^[[:space:]]+([a-z][a-z0-9-]*):\ (.+)$ ]]; then
      EXISTING_DATA["${current_zstream}:${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
    fi
  done <"$yaml_file"
}

write_yaml() {
  local yaml_file="$1"
  shift
  local -a zstreams=("$@")

  {
    echo "# Last updated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for zs in "${zstreams[@]}"; do
      echo "\"${zs}\":"
      for pkg in $ALL_PACKAGES; do
        local val="${EXISTING_DATA["${zs}:${pkg}"]:-}"
        if [[ -n "$val" ]]; then
          echo "  ${pkg}: ${val}"
        fi
      done
    done
  } >"$yaml_file"
}

write_markdown() {
  local md_file="$1"
  local major_minor="$2"
  shift 2
  local -a zstreams=("$@")

  local -a latest=()
  local -a older=()
  local i=0
  for zs in "${zstreams[@]}"; do
    if (( i < LATEST_COUNT )); then
      latest+=("$zs")
    else
      older+=("$zs")
    fi
    (( i += 1 )) || true
  done

  {
    echo "# OCP ${major_minor} CloudRAN Operator Versions"
    echo
    echo "Last updated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo

    if [[ ${#latest[@]} -gt 0 ]]; then
      # Header row
      printf "| Operator |"
      for zs in "${latest[@]}"; do printf " %s |" "$zs"; done
      echo
      # Separator
      printf "|----------|"
      for _ in "${latest[@]}"; do printf -- "---------|"; done
      echo
      # Data rows
      for pkg in $ALL_PACKAGES; do
        printf "| %s |" "$pkg"
        for zs in "${latest[@]}"; do
          local val="${EXISTING_DATA["${zs}:${pkg}"]:-}"
          printf " %s |" "$val"
        done
        echo
      done
    fi

    if [[ ${#older[@]} -gt 0 ]]; then
      echo
      echo "## Older releases"
      echo
      printf "| Operator |"
      for zs in "${older[@]}"; do printf " %s |" "$zs"; done
      echo
      printf "|----------|"
      for _ in "${older[@]}"; do printf "---------|"; done
      echo
      for pkg in $ALL_PACKAGES; do
        printf "| %s |" "$pkg"
        for zs in "${older[@]}"; do
          local val="${EXISTING_DATA["${zs}:${pkg}"]:-}"
          printf " %s |" "$val"
        done
        echo
      done
    fi
  } >"$md_file"
}

process_version() {
  local major_minor="$1"
  local yaml_file="$SNAPSHOTS_DIR/${major_minor}.yaml"
  local md_file="$SNAPSHOTS_DIR/${major_minor}.md"

  log "Processing OCP ${major_minor}..."

  local latest_zstream
  latest_zstream=$(get_latest_zstream "$major_minor")
  if [[ -z "$latest_zstream" ]]; then
    log "WARN: could not detect latest z-stream for ${major_minor}, skipping"
    return 0
  fi
  log "Latest z-stream for ${major_minor}: ${latest_zstream}"

  parse_existing_yaml "$yaml_file"

  # Check if we already have this z-stream
  for existing in "${EXISTING_ZSTREAMS[@]+"${EXISTING_ZSTREAMS[@]}"}"; do
    if [[ "$existing" == "$latest_zstream" ]]; then
      log "Already have ${latest_zstream}, skipping"
      return 0
    fi
  done

  refresh_catalog_cache "$major_minor"

  local versions_tsv
  versions_tsv=$(get_operator_versions "$major_minor")

  if [[ -z "$versions_tsv" ]]; then
    log "WARN: no operator versions extracted for ${major_minor}, skipping"
    return 0
  fi

  # Store new versions in EXISTING_DATA
  while IFS=$'\t' read -r pkg ver; do
    EXISTING_DATA["${latest_zstream}:${pkg}"]="$ver"
  done <<<"$versions_tsv"

  # Prepend new z-stream to the list
  local -a all_zstreams=("$latest_zstream" "${EXISTING_ZSTREAMS[@]+"${EXISTING_ZSTREAMS[@]}"}")

  mkdir -p "$SNAPSHOTS_DIR"
  write_yaml "$yaml_file" "${all_zstreams[@]}"
  write_markdown "$md_file" "$major_minor" "${all_zstreams[@]}"

  log "Updated ${yaml_file} and ${md_file} with ${latest_zstream}"
}

main() {
  log "Starting operator version snapshot"
  log "OCP versions: $OCP_VERSIONS"
  log "Repo: $REPO_DIR"

  local changed=0

  for version in $OCP_VERSIONS; do
    process_version "$version" && changed=1 || true
  done

  cd "$REPO_DIR"
  if [[ -n "$(git status --porcelain snapshots/ 2>/dev/null)" ]]; then
    local today
    today=$(date +%Y-%m-%d)
    git add snapshots/
    git commit -m "update operator versions ${today}"
    if git remote get-url origin >/dev/null 2>&1; then
      git push
      log "Pushed to remote"
    else
      log "No remote configured, skipping push"
    fi
  else
    log "No changes detected"
  fi

  log "Done"
}

main "$@"
