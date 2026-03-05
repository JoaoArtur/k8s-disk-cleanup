# k8s-disk-cleanup

Automated disk cleanup for Kubernetes nodes running **MicroK8s** (also compatible with kubeadm, k3s, and other containerd-based setups).

Removes unused container images, containerd build cache, and old pod logs — safely, with dry-run by default and circuit breakers to prevent accidental mass deletion.

## Quick Install

```bash
curl -sSL https://raw.githubusercontent.com/JoaoArtur/k8s-disk-cleanup/main/install.sh | sudo bash
```

This will:
- Install `cron` if not present
- Download `k8s-disk-cleanup.sh` to `/opt/k8s-cleanup/`
- Register a daily cron job at **03:00**
- Configure logrotate for cleanup logs

### Custom thresholds

```bash
curl -sSL https://raw.githubusercontent.com/JoaoArtur/k8s-disk-cleanup/main/install.sh \
  | sudo DISK_THRESHOLD=80 MAX_IMAGES_TO_PRUNE=600 bash
```

## What it cleans

| Target | Description | Safety |
|--------|-------------|--------|
| **Container images** | Images not referenced by any running or stopped container | Checks per-image usage before removal |
| **Containerd cache** | Unreferenced content blobs, expired leases, orphan snapshots | Uses native `ctr content prune references` |
| **Pod logs** | Rotated/compressed logs older than retention period | Only touches `.gz` and `.log.*` files |
| **Large active logs** | Active `.log` files over 100MB | Truncates (does not delete) — disable if logs aren't being collected |
| **Journal** | systemd journal for kubelet/kubelite | Vacuums entries older than retention period |

## Configuration

All settings are configurable via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `DISK_THRESHOLD` | `75` | Disk usage % that triggers cleanup |
| `DISK_PARTITION` | `/` | Partition to monitor |
| `LOG_RETENTION_DAYS` | `7` | Minimum age (days) of logs to remove |
| `IMAGE_AGE` | `24h` | Minimum age of unused images |
| `MAX_IMAGES_TO_PRUNE` | `50` | Circuit breaker — aborts image prune if exceeded |

## Usage

```bash
# Dry-run (default) — logs what would be cleaned, changes nothing
sudo /opt/k8s-cleanup/k8s-disk-cleanup.sh

# Execute for real
sudo /opt/k8s-cleanup/k8s-disk-cleanup.sh --execute

# Override settings inline
sudo DISK_THRESHOLD=60 MAX_IMAGES_TO_PRUNE=600 /opt/k8s-cleanup/k8s-disk-cleanup.sh --execute
```

## Logs

All executions are logged to `/var/log/k8s-disk-cleanup.log` with automatic rotation (4 weeks, compressed).

```bash
# Latest execution
tail -100 /var/log/k8s-disk-cleanup.log

# Follow live
tail -f /var/log/k8s-disk-cleanup.log

# Show only final reports
grep "RELATÓRIO FINAL" -A 8 /var/log/k8s-disk-cleanup.log
```

## Safety

- **Dry-run by default** — no `--execute`, no changes
- **Threshold gate** — does nothing if disk usage is below the configured threshold
- **Circuit breaker** — aborts image cleanup if the number of candidates exceeds `MAX_IMAGES_TO_PRUNE`, preventing runaway deletions
- **Per-image safety check** — verifies no container (running or stopped) references the image before removing
- **MicroK8s aware** — auto-detects snap paths, containerd socket, and kubelite journal unit

## Runtime compatibility

| Runtime | Support | Notes |
|---------|---------|-------|
| MicroK8s (containerd via snap) | ✅ Full | Auto-detected, uses snap paths |
| kubeadm + containerd | ✅ Full | Standard paths |
| k3s | ✅ Full | Standard containerd paths |
| Docker (dockershim) | ❌ | Not supported |
| CRI-O | ❌ | Not supported |

## Uninstall

```bash
# Remove cron entry
crontab -l | grep -v 'k8s-disk-cleanup' | crontab -

# Remove files
sudo rm -rf /opt/k8s-cleanup /etc/logrotate.d/k8s-disk-cleanup /var/log/k8s-disk-cleanup.log
```

## License

MIT
