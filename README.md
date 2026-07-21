# OpenShift Operator Releases

Daily snapshots of CloudRAN operator versions from the Red Hat operator catalog for tracked OCP major.minor streams.

## Structure

- `snapshots/<major.minor>.md` — Markdown table with latest 5 z-stream releases and an archive section for older ones
- `snapshots/<major.minor>.yaml` — Machine-readable YAML with all z-stream releases, for programmatic consumption

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

## Usage

Run manually:
```bash
./scripts/snapshot-operator-versions.sh
```

The script is intended to run as a daily cron job. It detects new OCP z-stream releases and captures the current operator versions from the catalog at that time.

## YAML format

```yaml
"4.20.29":
  cluster-logging: v6.4.5
  ptp-operator: v4.20.0-202606090540
  ...
```

Scripts can query specific versions:
```bash
yq '.["4.20.26"]["ptp-operator"]' snapshots/4.20.yaml
```
