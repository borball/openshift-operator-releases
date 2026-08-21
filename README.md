# OpenShift Operator Releases

Hourly snapshots of CloudRAN operator versions from the Red Hat and certified-operator catalogs, keyed per OCP z-stream release. A new baseline is locked when a z-stream reaches the fast channel (at which point the catalog is stable). Drift is detected when catalog versions change without a new OCP release.

## Structure

```
snapshots/
  <mm>.yaml    — machine-readable baselines per z-stream (all history kept)
  <mm>.md      — markdown table, latest 5 z-streams + older archive
alerts/
  <mm>-<zstream>.md  — created once per drift incident; delete to re-arm detection
pending/
  <mm>.yaml    — z-streams seen in the mirror but not yet in fast channel
scripts/
  snapshot-operator-versions.sh  — hourly cron driver
  backfill-snapshots.sh          — reconstruct historical baselines
```

## Tracked operators

| Operator | Catalog |
|----------|---------|
| cluster-logging | redhat-operator |
| lifecycle-agent | redhat-operator |
| local-storage-operator | redhat-operator |
| lvms-operator | redhat-operator |
| ptp-operator | redhat-operator |
| redhat-oadp-operator | redhat-operator |
| sriov-fec | certified-operator |
| sriov-network-operator | redhat-operator |

## Lifecycle: how a new z-stream is captured

```
OCP binary published (mirror.openshift.com)
  → detected by cron: added to pending/<mm>.yaml
  ↓ (6–11 hours)
OCP in candidate channel
  ↓ (~5 days)
OCP promoted to fast channel + catalog updated
  → cron detects fast promotion: locks baseline in snapshots/<mm>.yaml
  ↓ (~7 more days)
OCP promoted to stable channel
```

The baseline is gated on **fast channel** because catalog updates (OLM bundles) land at roughly the same time as fast promotion. Locking on candidate would capture a catalog that has not yet been updated.

## YAML format

```yaml
"4.22.8":
  _first_seen_at: 2026-07-31T14:41:52Z   # when OCP binary first appeared on mirror
  _fast_promoted_at: 2026-08-04T14:01:49Z # when fast-channel gate triggered baseline lock
  cluster-logging: v6.6.0
  lifecycle-agent: v4.22.1
  local-storage-operator: v4.22.0-202607272042
  lvms-operator: v4.22.0
  ptp-operator: v4.22.0-202607272042
  redhat-oadp-operator: v1.6.1
  sriov-network-operator: v4.22.0-202607272042
```

Query a specific version:
```bash
yq '.["4.22.8"]["ptp-operator"]' snapshots/4.22.yaml
```

## Drift detection

After a baseline is locked, the cron continues to run hourly. If any operator version in the catalog changes without a new OCP z-stream release, an alert file is created under `alerts/`. The alert includes the baseline, the current catalog version, and how long after the OCP release the drift was detected. Only one alert file is created per (OCP minor, z-stream) drift incident — the cron won't re-alert hourly while the file exists, so deleting it is both how you close the alert and how you re-arm detection for that z-stream.

Close an alert by investigating and deleting the file once confirmed.

## Dependencies

- `oc-catalog.sh` — wraps `opm render` with a digest-based JSON cache
- `skopeo` — cheap catalog image digest check for hourly cache invalidation
- `jq` — JSON processing
- `curl` — OCP mirror index scraping and Cincinnati API queries
- `git` — snapshot commits

## Cron setup

```bash
# On root@192.168.14.30
crontab -e
```

```
PATH=/usr/local/bin:/usr/bin:/bin
HOME=/root
7 * * * * /root/openshift-operator-releases/scripts/snapshot-operator-versions.sh >> /tmp/operator-snapshot.log 2>&1
```

## Manual run

```bash
./scripts/snapshot-operator-versions.sh
```

Override which OCP versions are processed:
```bash
OCP_VERSIONS="4.22" ./scripts/snapshot-operator-versions.sh
```

Override channel per package (default: `cluster-logging=stable-6.4` for 4.18 and 4.20):
```bash
CHANNEL_OVERRIDES_4_20="cluster-logging=stable-6.4" ./scripts/snapshot-operator-versions.sh
```

## Backfill historical data

To reconstruct baselines for z-streams that predate the cron's first run:

```bash
# Defaults: 4.18 → latest 20, 4.20 → latest 10, 4.22 → all
./scripts/backfill-snapshots.sh

# Override scope
BACKFILL_4_18=5 OCP_VERSIONS="4.18" ./scripts/backfill-snapshots.sh
```

The backfill script gets the fast-promotion date per z-stream from the `openshift/cincinnati-graph-data` GitHub repo, then queries the catalog for bundle versions that existed at that date:
- **Date-stamped versions** (e.g. `v4.20.0-202607141720`): date is parsed directly from the version string — reliable.
- **Semantic versions** (e.g. `v6.4.6`): chosen by version-number ordering within the scoped channel — reliable enough since versions only increment.
