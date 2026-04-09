#!/usr/bin/env bash
#
# audit-aws.sh — read-only audit of the eu-north-1 brownfield AWS state.
#
# Captures EC2 / RDS / IAM / VPC / S3 / ECR resources into a JSON file so
# the Phase 14 Terraform onboarding has a canonical reference of "what
# already exists, hand-provisioned."
#
# Two files are produced:
#
#   audit/eu-north-1.full.json   — full unsanitized snapshot, LOCAL ONLY
#                                  (gitignored — see .gitignore)
#
#   audit/eu-north-1.json        — SANITIZED version safe to commit:
#                                  • EC2 PublicIpAddress     -> "***"
#                                  • EC2 PublicDnsName       -> "***"
#                                  • RDS Endpoint.Address    -> "***"
#                                  • RDS MasterUsername      -> "***"
#                                  • SG IpRanges[].CidrIp    -> "***" if it
#                                    is a non-internal /32 (i.e. a real
#                                    home/office IP allowlist entry)
#
# Internal CIDRs (10.x, 172.16-31.x, 192.168.x) and 0.0.0.0/0 are kept as-is
# because they carry no exposure risk and are useful for Terraform planning.
#
# Only read-only APIs are called (describe / list / get). Safe to run any
# time. Requires aws CLI v2 and jq.
#
# Usage:
#   cd crypto-infra
#   ./scripts/audit-aws.sh

set -euo pipefail

REGION=eu-north-1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="$REPO_ROOT/audit"
FULL_FILE="$OUT_DIR/$REGION.full.json"
SAFE_FILE="$OUT_DIR/$REGION.json"

mkdir -p "$OUT_DIR"

command -v aws >/dev/null 2>&1 || { echo "ERROR: aws CLI not found"; exit 1; }
command -v jq  >/dev/null 2>&1 || { echo "ERROR: jq not found";       exit 1; }

echo "==> AWS audit for region: $REGION"
echo "==> Verifying identity..."
aws sts get-caller-identity

echo "==> Querying read-only APIs (this may take ~10s)..."

# ---------------------------------------------------------------------------
# Step 1: write the full unsanitized snapshot to $FULL_FILE (gitignored)
# ---------------------------------------------------------------------------
jq -n \
  --arg     audited_at      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg     region          "$REGION" \
  --argjson identity        "$(aws sts get-caller-identity)" \
  --argjson ec2_instances   "$(aws ec2 describe-instances        --region "$REGION")" \
  --argjson security_groups "$(aws ec2 describe-security-groups  --region "$REGION")" \
  --argjson vpcs            "$(aws ec2 describe-vpcs             --region "$REGION")" \
  --argjson subnets         "$(aws ec2 describe-subnets          --region "$REGION")" \
  --argjson key_pairs       "$(aws ec2 describe-key-pairs        --region "$REGION")" \
  --argjson igw             "$(aws ec2 describe-internet-gateways --region "$REGION")" \
  --argjson nat_gw          "$(aws ec2 describe-nat-gateways     --region "$REGION")" \
  --argjson route_tables    "$(aws ec2 describe-route-tables     --region "$REGION")" \
  --argjson eips            "$(aws ec2 describe-addresses        --region "$REGION")" \
  --argjson volumes         "$(aws ec2 describe-volumes          --region "$REGION")" \
  --argjson rds_instances   "$(aws rds describe-db-instances     --region "$REGION")" \
  --argjson rds_subnet_grps "$(aws rds describe-db-subnet-groups --region "$REGION")" \
  --argjson rds_param_grps  "$(aws rds describe-db-parameter-groups --region "$REGION")" \
  --argjson iam_roles       "$(aws iam list-roles)" \
  --argjson iam_users       "$(aws iam list-users)" \
  --argjson ecr_repos       "$(aws ecr describe-repositories     --region "$REGION" 2>/dev/null || echo '{"repositories":[]}')" \
  --argjson s3_buckets      "$(aws s3api list-buckets)" \
  '{
    audited_at: $audited_at,
    region: $region,
    identity: $identity,
    ec2: {
      instances:         ($ec2_instances.Reservations    // []),
      security_groups:   ($security_groups.SecurityGroups // []),
      vpcs:              ($vpcs.Vpcs                     // []),
      subnets:           ($subnets.Subnets               // []),
      key_pairs:         ($key_pairs.KeyPairs            // []),
      internet_gateways: ($igw.InternetGateways          // []),
      nat_gateways:      ($nat_gw.NatGateways            // []),
      route_tables:      ($route_tables.RouteTables      // []),
      elastic_ips:       ($eips.Addresses                // []),
      volumes:           ($volumes.Volumes               // [])
    },
    rds: {
      db_instances:      ($rds_instances.DBInstances     // []),
      subnet_groups:     ($rds_subnet_grps.DBSubnetGroups // []),
      parameter_groups:  ($rds_param_grps.DBParameterGroups // [])
    },
    iam: {
      roles: ($iam_roles.Roles // []),
      users: ($iam_users.Users // [])
    },
    ecr: {
      repositories: ($ecr_repos.repositories // [])
    },
    s3: {
      buckets: ($s3_buckets.Buckets // [])
    }
  }' > "$FULL_FILE"

echo "==> Wrote $FULL_FILE ($(wc -c < "$FULL_FILE" | tr -d ' ') bytes) [LOCAL ONLY, gitignored]"

# ---------------------------------------------------------------------------
# Step 2: produce the sanitized snapshot at $SAFE_FILE (committed)
# ---------------------------------------------------------------------------
jq '
  def is_internal_cidr:
    test("^10\\.")
    or test("^172\\.(1[6-9]|2[0-9]|3[0-1])\\.")
    or test("^192\\.168\\.")
    or . == "0.0.0.0/0";

  # 1. EC2: mask routable public fields on every instance
  .ec2.instances |= map(
    .Instances |= map(
      (if .PublicIpAddress != null then .PublicIpAddress = "***" else . end)
      | (if (.PublicDnsName // "") != "" then .PublicDnsName = "***" else . end)
    )
  )
  # 2. RDS: mask the routable endpoint and the master username
  | .rds.db_instances |= map(
      (if .Endpoint != null and .Endpoint.Address != null then .Endpoint.Address = "***" else . end)
      | (if .MasterUsername != null then .MasterUsername = "***" else . end)
    )
  # 3. SG rules: mask any non-internal CidrIp anywhere in the document
  | walk(
      if type == "object" and has("CidrIp") then
        .CidrIp |= (if is_internal_cidr then . else "***" end)
      else . end
    )
' "$FULL_FILE" > "$SAFE_FILE"

echo "==> Wrote $SAFE_FILE ($(wc -c < "$SAFE_FILE" | tr -d ' ') bytes) [SANITIZED, committed]"
echo ""
echo "==> Summary:"
jq '{
  region:               .region,
  audited_at:           .audited_at,
  identity_arn:         .identity.Arn,
  ec2_instances:        (.ec2.instances        | map(.Instances) | flatten | length),
  ec2_security_groups:  (.ec2.security_groups  | length),
  ec2_vpcs:             (.ec2.vpcs             | length),
  ec2_subnets:          (.ec2.subnets          | length),
  ec2_key_pairs:        (.ec2.key_pairs        | length),
  ec2_internet_gateways:(.ec2.internet_gateways | length),
  ec2_nat_gateways:     (.ec2.nat_gateways     | length),
  ec2_route_tables:     (.ec2.route_tables     | length),
  ec2_elastic_ips:      (.ec2.elastic_ips      | length),
  ec2_volumes:          (.ec2.volumes          | length),
  rds_db_instances:     (.rds.db_instances     | length),
  rds_subnet_groups:    (.rds.subnet_groups    | length),
  iam_roles:            (.iam.roles            | length),
  iam_users:            (.iam.users            | length),
  ecr_repositories:     (.ecr.repositories     | length),
  s3_buckets:           (.s3.buckets           | length)
}' "$SAFE_FILE"
