#!/bin/bash
# Keep-last-N image rotation for the live EC2.
#
# Runs from cron on the live EC2 itself (see live-image-rotation.cron).
# Intentionally NOT called from the deploy path so deploy latency stays
# flat regardless of how many old tags pile up.
#
# Retention: the 3 most-recently-created tags per ECR repository.
# Running containers pin their image layers — docker rmi on a pinned
# image fails loudly and the script moves on. Rollback to a pruned
# tag triggers one docker pull from ECR (1-2 min).
#
# Why 3: covers the running tag + the previous known-green tag + one
# additional fallback. Three repos * 3 tags = ~10 GB of the 29 GB
# root volume, leaving plenty of headroom for in-flight pulls.
#
# History: after v2.0.6 filled the disk we added a 72h filter to the
# deploy path; it stopped working once the release cadence dropped
# below 72h per release (9 inference images in ~48h on 2026-04-24).
# This script replaces that filter with a count-based retention that
# is independent of release frequency.

set -u

KEEP=3
LOG_PREFIX="[image-rotation]"

REPOS=(
  "530615869788.dkr.ecr.eu-north-1.amazonaws.com/crypto-ai-python"
  "530615869788.dkr.ecr.eu-north-1.amazonaws.com/crypto-bot-node"
  "530615869788.dkr.ecr.eu-north-1.amazonaws.com/crypto-web-vue"
)

log() {
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $LOG_PREFIX $*"
}

for repo in "${REPOS[@]}"; do
  log "scanning $repo"
  # Sort by CreatedAt desc, skip top $KEEP, delete the rest. Running
  # containers keep their image via the daemon refcount — `docker rmi`
  # on a pinned image fails with "image is being used" and we move on.
  #
  # docker image ls groups by repo:tag; the CreatedAt field is the
  # local pull/tag timestamp, which mirrors ECR push order for the
  # deploy path. Two-column tab output → sort by 2nd column desc.
  mapfile -t TO_REMOVE < <(
    docker image ls "$repo" --format '{{.Repository}}:{{.Tag}}|{{.CreatedAt}}' \
      | awk -F'|' '$2 != "" { print }' \
      | sort -t'|' -k2 -r \
      | awk -F'|' -v n="$KEEP" 'NR>n {print $1}'
  )
  if [ "${#TO_REMOVE[@]}" -eq 0 ]; then
    log "  nothing to remove from $repo"
    continue
  fi
  for image in "${TO_REMOVE[@]}"; do
    if docker rmi "$image" >/dev/null 2>&1; then
      log "  removed $image"
    else
      log "  skipped $image (in use or already gone)"
    fi
  done
done

# Sweep dangling blobs / orphaned layers that survive the tag-level rmi.
log "pruning dangling layers"
docker image prune -f >/dev/null 2>&1 || true
log "done"
