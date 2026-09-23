#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# One-time AWS setup for fordham-ellucian-s3-sync.
#
# Creates (or updates, if they already exist):
#   1. S3 bucket  - private, versioned, encrypted
#   2. GitHub OIDC identity provider - lets GitHub Actions log in without keys
#   3. IAM role   - trust policy (only this repo's main branch) + S3 permissions
#   4. (optional) bucket policy giving Ellucian's AWS account read-only access
#   5. (optional) GitHub repo secret AWS_ROLE_ARN + variable S3_BUCKET via `gh`
#
# Safe to re-run. Requires: AWS CLI v2, logged in as someone who can manage
# IAM and S3 (e.g. `aws sso login --profile fordham` then AWS_PROFILE=fordham),
# plus the `gh` CLI signed in (`gh auth login`) with the repo already created
# on GitHub, so the script can ask GitHub for the repo's exact OIDC subject.
#
# Usage:
#   GITHUB_ORG=fordham-dsg BUCKET=fordham-ellucian-scripts ./aws/setup_aws.sh
# -----------------------------------------------------------------------------
set -euo pipefail

# ---- Settings (override with environment variables) -------------------------
BUCKET="${BUCKET:-fordham-ellucian-scripts}"
REGION="${REGION:-us-east-1}"
GITHUB_ORG="${GITHUB_ORG:-<GITHUB_ORG>}"
GITHUB_REPO="${GITHUB_REPO:-fordham-ellucian-s3-sync}"
ROLE_NAME="${ROLE_NAME:-github-actions-fordham-ellucian-s3-sync}"
ELLUCIAN_ACCOUNT_ID="${ELLUCIAN_ACCOUNT_ID:-}"      # blank = skip step 4
GITHUB_SUB_PREFIX="${GITHUB_SUB_PREFIX:-}"          # blank = look it up from GitHub (recommended)
SET_GITHUB_SETTINGS="${SET_GITHUB_SETTINGS:-yes}"   # "no" = skip step 5
# -----------------------------------------------------------------------------

HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
say() { printf '\n==> %s\n' "$*"; }

if [[ "$GITHUB_ORG" == "<GITHUB_ORG>" ]]; then
  echo "Set GITHUB_ORG first, e.g.  GITHUB_ORG=my-org ./aws/setup_aws.sh" >&2
  exit 1
fi
command -v aws >/dev/null || { echo "AWS CLI not found. Install: https://aws.amazon.com/cli/" >&2; exit 1; }

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

# ---- GitHub OIDC subject ----------------------------------------------------
# AWS only lets GitHub assume the role when the token's "sub" claim matches the
# trust policy exactly. Repos created after 15 Jul 2026 (and renamed or
# transferred ones) send an "immutable" subject that includes numeric IDs:
#     repo:ORG@OWNER_ID/REPO@REPO_ID:ref:refs/heads/main
# Older repos still send   repo:ORG/REPO:ref:refs/heads/main   unless opted in.
# Guessing the wrong form gives "Not authorized to perform
# sts:AssumeRoleWithWebIdentity" in the Action log, so ask GitHub for the real
# prefix rather than guessing. Override with GITHUB_SUB_PREFIX=... if needed.
if [[ -z "$GITHUB_SUB_PREFIX" ]] && command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  # On failure gh prints the error body to stdout, so blank the value unless gh succeeded.
  GITHUB_SUB_PREFIX="$(gh api "repos/$GITHUB_ORG/$GITHUB_REPO/actions/oidc/customization/sub" \
    --jq '.sub_claim_prefix // empty' 2>/dev/null)" || GITHUB_SUB_PREFIX=""
fi
if [[ -z "$GITHUB_SUB_PREFIX" || "$GITHUB_SUB_PREFIX" != repo:* ]]; then
  cat >&2 <<MSG
Could not get a valid GitHub OIDC subject for $GITHUB_ORG/$GITHUB_REPO (got: '${GITHUB_SUB_PREFIX:-nothing}').
Make sure the repo exists on GitHub and \`gh auth status\` works, then re-run.
Or find it yourself and pass it in:
  gh api repos/$GITHUB_ORG/$GITHUB_REPO/actions/oidc/customization/sub --jq .sub_claim_prefix
  GITHUB_SUB_PREFIX='repo:$GITHUB_ORG@<owner id>/$GITHUB_REPO@<repo id>' ./aws/setup_aws.sh
MSG
  exit 1
fi

say "AWS account $ACCOUNT_ID, region $REGION, bucket $BUCKET, repo $GITHUB_ORG/$GITHUB_REPO"
echo "GitHub OIDC subject the role will trust: ${GITHUB_SUB_PREFIX}:ref:refs/heads/main"

# Fill placeholders in the JSON templates
render() {
  sed -e "s|<AWS_ACCOUNT_ID>|$ACCOUNT_ID|g" \
      -e "s|<GITHUB_ORG>|$GITHUB_ORG|g" \
      -e "s|<GITHUB_REPO>|$GITHUB_REPO|g" \
      -e "s|<GITHUB_SUB_PREFIX>|$GITHUB_SUB_PREFIX|g" \
      -e "s|<S3_BUCKET>|$BUCKET|g" \
      -e "s|<ELLUCIAN_ACCOUNT_ID>|$ELLUCIAN_ACCOUNT_ID|g" \
      "$HERE/$1" > "$TMP/$1"
  echo "$TMP/$1"
}

# 1. Bucket ------------------------------------------------------------------
say "1/5 S3 bucket"
if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "Bucket already exists, reusing it."
else
  if [[ "$REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
  fi
  echo "Created bucket."
fi
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
echo "Public access blocked, versioning on, encryption on."

# 2. GitHub OIDC provider ------------------------------------------------------
say "2/5 GitHub OIDC provider"
OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" >/dev/null 2>&1; then
  echo "Already exists (shared by every GitHub repo in this account), reusing it."
  aws iam add-client-id-to-open-id-connect-provider \
    --open-id-connect-provider-arn "$OIDC_ARN" --client-id sts.amazonaws.com 2>/dev/null || true
else
  # AWS validates GitHub's certificate itself; the thumbprint is required by the
  # API on some CLI versions but is not used for GitHub.
  aws iam create-open-id-connect-provider \
    --url https://token.actions.githubusercontent.com \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 >/dev/null
  echo "Created."
fi

# 3. IAM role ------------------------------------------------------------------
say "3/5 IAM role $ROLE_NAME"
TRUST="$(render github-oidc-trust-policy.json)"
PERMS="$(render s3-sync-permissions-policy.json)"
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document "file://$TRUST"
  echo "Role exists, trust policy updated."
else
  aws iam create-role --role-name "$ROLE_NAME" \
    --assume-role-policy-document "file://$TRUST" \
    --description "GitHub Actions: $GITHUB_ORG/$GITHUB_REPO syncs scripts/ to s3://$BUCKET" >/dev/null
  echo "Role created."
fi
echo "Trusts GitHub subject: ${GITHUB_SUB_PREFIX}:ref:refs/heads/main"
aws iam put-role-policy --role-name "$ROLE_NAME" \
  --policy-name s3-sync-scripts --policy-document "file://$PERMS"
ROLE_ARN="$(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text)"
echo "Permissions policy attached. Role ARN: $ROLE_ARN"

# 4. Ellucian read-only bucket policy (optional) -------------------------------
say "4/5 Ellucian bucket policy"
if [[ -z "$ELLUCIAN_ACCOUNT_ID" ]]; then
  echo "Skipped (set ELLUCIAN_ACCOUNT_ID to enable)."
elif aws s3api get-bucket-policy --bucket "$BUCKET" >/dev/null 2>&1 && [[ "${FORCE_BUCKET_POLICY:-no}" != "yes" ]]; then
  echo "Bucket already has a policy; not overwriting it."
  echo "Review it, then re-run with FORCE_BUCKET_POLICY=yes to replace it."
else
  BP="$(render s3-bucket-policy-ellucian-readonly.json)"
  aws s3api put-bucket-policy --bucket "$BUCKET" --policy "file://$BP"
  echo "Ellucian account $ELLUCIAN_ACCOUNT_ID can read s3://$BUCKET/scripts/latest/"
fi

# 5. GitHub repo settings (optional) -------------------------------------------
say "5/5 GitHub repo secret + variable"
if [[ "$SET_GITHUB_SETTINGS" != "yes" ]]; then
  echo "Skipped."
elif command -v gh >/dev/null && gh auth status >/dev/null 2>&1 \
     && gh repo view "$GITHUB_ORG/$GITHUB_REPO" >/dev/null 2>&1; then
  gh secret set AWS_ROLE_ARN --repo "$GITHUB_ORG/$GITHUB_REPO" --body "$ROLE_ARN"
  gh variable set S3_BUCKET --repo "$GITHUB_ORG/$GITHUB_REPO" --body "$BUCKET"
  echo "Set AWS_ROLE_ARN secret and S3_BUCKET variable."
else
  echo "gh CLI not installed/logged in, or repo not created yet. Set these by hand"
  echo "in GitHub > Settings > Secrets and variables > Actions:"
  echo "  Secret   AWS_ROLE_ARN = $ROLE_ARN"
  echo "  Variable S3_BUCKET    = $BUCKET"
fi

say "Done."
if [[ "$REGION" != "us-east-1" ]]; then
  echo "Remember to set AWS_REGION: $REGION in .github/workflows/sync-to-s3.yml"
fi
