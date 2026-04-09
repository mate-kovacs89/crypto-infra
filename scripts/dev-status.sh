#!/usr/bin/env bash
#
# dev-status.sh — show git status of all 5 crypto-ai sibling repos in one
# shot. Useful as a daily standup of "where am I in the polyrepo?".
#
# Usage:
#   cd crypto-infra
#   ./scripts/dev-status.sh
#
# Looks for sibling repos under the parent directory of crypto-infra:
#   crypto-bot-node, crypto-ai-python, crypto-web-vue, crypto-shared, crypto-infra

set -uo pipefail

REPOS=(
  crypto-shared
  crypto-bot-node
  crypto-ai-python
  crypto-web-vue
  crypto-infra
)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

printf "Polyrepo state under: %s\n\n" "$PARENT_DIR"
printf "%-18s %-12s %-14s %-10s %s\n" "REPO" "BRANCH" "STATUS" "AHEAD/BEHIND" "REMOTE"
printf "%-18s %-12s %-14s %-10s %s\n" "------------------" "------------" "--------------" "----------" "------"

for repo in "${REPOS[@]}"; do
  repo_path="$PARENT_DIR/$repo"

  if [ ! -d "$repo_path" ]; then
    printf "%-18s %-12s %-14s %-10s %s\n" "$repo" "—" "MISSING" "—" "—"
    continue
  fi

  if [ ! -d "$repo_path/.git" ]; then
    printf "%-18s %-12s %-14s %-10s %s\n" "$repo" "—" "no-git-init" "—" "—"
    continue
  fi

  branch=$(git -C "$repo_path" symbolic-ref --short HEAD 2>/dev/null || echo "(detached)")

  porcelain=$(git -C "$repo_path" status --porcelain 2>/dev/null)
  if [ -z "$porcelain" ]; then
    status="clean"
  else
    dirty_count=$(printf "%s\n" "$porcelain" | wc -l | tr -d ' ')
    status="dirty($dirty_count)"
  fi

  ahead_behind="—"
  if git -C "$repo_path" rev-parse --verify --quiet "origin/$branch" >/dev/null 2>&1; then
    counts=$(git -C "$repo_path" rev-list --left-right --count "$branch...origin/$branch" 2>/dev/null || echo "0	0")
    ahead=$(printf "%s" "$counts" | cut -f1)
    behind=$(printf "%s" "$counts" | cut -f2)
    ahead_behind="+${ahead}/-${behind}"
  fi

  remote=$(git -C "$repo_path" remote get-url origin 2>/dev/null || echo "(no remote)")

  printf "%-18s %-12s %-14s %-10s %s\n" "$repo" "$branch" "$status" "$ahead_behind" "$remote"
done
