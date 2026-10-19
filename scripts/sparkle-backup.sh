#!/usr/bin/env bash
# Pull a full sparkle backup to ~/Downloads/sparkle-<datetime>.tar.zst
# Usage: scripts/sparkle-backup.sh [ssh-host]   (default: sparkle from ~/.ssh/config)
set -euo pipefail

HOST=${1:-sparkle}
OUT=~/Downloads/sparkle-$(date +%Y-%m-%d_%H-%M-%S).tar.zst
mc() { ssh "$HOST" 'for c in $(docker ps --filter label=mc-router.host --format "{{.Names}}"); do docker exec $c rcon-cli '"$*"'; done'; }
trap 'rm -f "$OUT.part"' ERR

echo "→ Navidrome DB snapshot"
ssh "$HOST" 'docker exec navidrome /app/navidrome backup create'

echo "→ Remnawave DB dump"
ssh "$HOST" 'docker exec remnawave-db pg_dump -U postgres -d postgres -Fc > /srv/data/remnawave/backup/remnawave.dump'

echo "→ Minecraft: flush + pause saving"
mc save-all flush
mc save-off
trap 'mc save-on; rm -f "$OUT.part"; exit 1' ERR INT TERM

echo "→ Downloading /srv/data + /srv/secrets"
# tar exit 1 = "file changed while reading" (live DB) → ok, the snapshots above are consistent
ssh "$HOST" 'sudo tar -C / --warning=no-file-changed \
  --exclude=srv/data/navidrome/data/cache \
  --exclude=srv/data/remnawave/db \
  -cf - srv/data srv/secrets || [ $? -eq 1 ]' \
  | zstd -T0 -q -o "$OUT.part"

mc save-on

zstd -tq "$OUT.part"
mv "$OUT.part" "$OUT"
echo "✓ $OUT ($(du -h "$OUT" | cut -f1))"
