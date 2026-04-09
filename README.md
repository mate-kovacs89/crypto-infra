# crypto-infra

Infrastructure-as-code, Docker compose files, deploy scripts and CI workflow
templates for the **crypto-ai** trading system.

This is the **only** repo that touches AWS resources directly. The other four
repos (`crypto-shared`, `crypto-bot-node`, `crypto-ai-python`, `crypto-web-vue`)
contain application code and reference this repo through CI workflows and
deploy scripts.

## Layout

```
crypto-infra/
├── audit/                       # output of audit-aws.sh — current AWS state snapshot
│   └── eu-north-1.json
├── docker/                      # docker compose files for dev / live / training hosts
│   ├── compose.dev.yml          # local mysql + (later) bot + inference + web
│   ├── compose.live-host.yml    # (Phase 16+) live EC2 docker stack
│   └── compose.training-host.yml # (Phase 17+) training EC2 docker stack
├── terraform/                   # (Phase 14+) brownfield onboarding + new resources
│   ├── envs/prod/               # main env (only env we run)
│   ├── modules/                 # ec2 / rds / s3 / ssm / iam / sg modules
│   ├── shared/                  # shared data sources, locals
│   └── bootstrap/               # one-shot S3 backend bucket creation
├── scripts/                     # bash helpers
│   ├── audit-aws.sh             # read-only AWS describe → audit/<region>.json
│   ├── dev-status.sh            # parallel git status across the 5 sibling repos
│   └── (later: deploy-*.sh, tf-import-existing.sh, load-env-from-ssm.sh)
├── .github/workflows/           # (Phase 15+) reusable CI workflows
└── README.md
```

## Phase 0 status

Only **`docker/compose.dev.yml`**, **`scripts/audit-aws.sh`**, **`scripts/dev-status.sh`**
and the folder skeleton are populated. The Terraform side (envs/, modules/,
bootstrap/) is intentionally empty until **Phase 14** (brownfield onboarding).

The CI workflow templates under `.github/workflows/` are added in **Phase 15**
once the consumer repos (`crypto-bot-node`, `crypto-ai-python`, `crypto-web-vue`)
have something to build.

## Usage

### Local dev mysql

```sh
cd crypto-infra
docker compose -f docker/compose.dev.yml up -d mysql

# Verify:
docker compose -f docker/compose.dev.yml ps
docker compose -f docker/compose.dev.yml logs --tail 30 mysql

# Connect:
mysql -h 127.0.0.1 -P 3306 -u cryptobot -p cryptobot_ai
# password: dev_change_me  (DEV ONLY — see compose.dev.yml comment)
```

The bot-node, ai-inference and web-vue services in `compose.dev.yml` are
commented out as TODOs. Uncomment as the corresponding repos are bootstrapped.

### Read-only AWS audit

```sh
cd crypto-infra
./scripts/audit-aws.sh
# Writes: audit/eu-north-1.json
# Prints: short summary table
```

The audit script makes only read-only API calls (`describe-*`, `list-*`, `get-*`)
and is safe to re-run anytime. Used to capture brownfield state before Phase 14
Terraform onboarding.

### Polyrepo git status

```sh
cd crypto-infra
./scripts/dev-status.sh
```

Prints a table showing the branch / clean-or-dirty / ahead-or-behind / remote
URL for each of the 5 sibling repos. Useful as a daily standup check.

## AWS protocol

This repo follows the strict **AWS protocol** from the project CLAUDE.md:

- **Allowed without permission:** any read-only AWS command (`describe-*`,
  `list-*`, `get-*`), `--dry-run` operations, `terraform plan`, `docker build`
  without ECR push, SSH read-only sessions.
- **Forbidden without explicit permission:** any AWS modifying command
  (`create-*`, `delete-*`, `modify-*`, `put-*`, `update-*`), `terraform apply`,
  `terraform import`, `docker push`, SSM `put-parameter`, SSH-side modification.

The `audit-aws.sh` script falls in the "allowed" category — only read-only.

## Region

Single region: **`eu-north-1`** (Stockholm). No cross-region resources.

## Phase 14+ Terraform onboarding

The 2 EC2 instances and 1 RDS instance currently exist as **hand-provisioned
brownfield state**. Phase 14 imports them into Terraform via `terraform import`
without recreating any resources. The audit/eu-north-1.json snapshot serves
as the canonical reference of "what already exists."

The S3 backend bucket for Terraform state is created **once** via
`terraform/bootstrap/` (chicken-and-egg: the backend has to exist before
`terraform init` can use it).
