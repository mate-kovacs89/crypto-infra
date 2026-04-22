# ECR lifecycle policies

Applied via `aws ecr put-lifecycle-policy` on 2026-04-22 to keep each
ECR repo bounded.

## Targets

| Repo | Rules | Expected steady-state size |
|---|---|---|
| `crypto-ai-python` | keep last 10 `v*-inference` + 10 `v*-training`, expire untagged >14 days | ~6 GB |
| `crypto-bot-node`  | keep last 10 `v*` + expire untagged >14 days | ~1 GB |
| `crypto-web-vue`   | keep last 10 `v*` + expire untagged >14 days | ~100 MB |

## Apply / re-apply

```
aws ecr put-lifecycle-policy \
  --repository-name <repo> \
  --region eu-north-1 \
  --lifecycle-policy-text file://<repo>.json
```

## Inspect what ECR will delete (dry-run preview)

```
aws ecr start-lifecycle-policy-preview \
  --repository-name <repo> --region eu-north-1
aws ecr get-lifecycle-policy-preview \
  --repository-name <repo> --region eu-north-1
```

## Rollback (remove policy, no automatic expiration)

```
aws ecr delete-lifecycle-policy \
  --repository-name <repo> --region eu-north-1
```

## Why these numbers

- **Keep 10 versioned**: covers a week+ of weekly model retrains plus
  emergency rollbacks — any tag from the last ~10 releases is available
  locally or in ECR for `docker pull`.
- **Untagged 14 days**: build cache + manifest-only layers that aren't
  tied to a semver tag are safe to delete after two weeks (no consumer
  references them by that point).
- **No `v0.x` / `v1.x` exemption**: historic images past the 10-cap
  are expired. Older rollback targets are still reproducible from the
  git tag via `build-push.yml` if ever needed.
