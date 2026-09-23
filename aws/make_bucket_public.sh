#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# OPTIONAL. Makes s3://BUCKET/scripts/ readable by anyone on the internet and
# lets the GitHub Pages bucket-browser page (docs/index.html) list it.
#
# setup_aws.sh deliberately does NOT do this: the default setup is private.
# Run this only if you want a public, shareable web view of the scripts.
#
# What it does (safe to re-run):
#   1. Turns off the two Block Public Access switches that block bucket
#      policies (the two ACL switches stay on; ACLs are not used)
#   2. Puts a bucket policy: anyone may list and read scripts/, HTTPS only
#   3. Puts a CORS rule so the page served from GitHub Pages may call the bucket
#
# Usage:
#   GITHUB_ORG=hantswilliams BUCKET=hants-fordham-ellucian-test ./aws/make_bucket_public.sh
#   UNDO=yes BUCKET=hants-fordham-ellucian-test ./aws/make_bucket_public.sh    # back to private
# -----------------------------------------------------------------------------
set -euo pipefail

# ---- Settings (override with environment variables) -------------------------
BUCKET="${BUCKET:-fordham-ellucian-scripts}"
GITHUB_ORG="${GITHUB_ORG:-<GITHUB_ORG>}"
PAGES_ORIGIN="${PAGES_ORIGIN:-}"                    # blank = https://<github_org>.github.io
FORCE_BUCKET_POLICY="${FORCE_BUCKET_POLICY:-no}"    # "yes" = replace an existing bucket policy
UNDO="${UNDO:-no}"                                  # "yes" = make the bucket private again
# -----------------------------------------------------------------------------

HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
say() { printf '\n==> %s\n' "$*"; }
command -v aws >/dev/null || { echo "AWS CLI not found. Install: https://aws.amazon.com/cli/" >&2; exit 1; }
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

# ---- Undo: back to the private defaults that setup_aws.sh creates ------------
if [[ "$UNDO" == "yes" ]]; then
  say "Making s3://$BUCKET private again (account $ACCOUNT_ID)"
  aws s3api delete-bucket-policy --bucket "$BUCKET" 2>/dev/null || true
  aws s3api delete-bucket-cors --bucket "$BUCKET" 2>/dev/null || true
  aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  echo "Bucket policy and CORS rule removed; Block Public Access fully on."
  exit 0
fi

if [[ "$GITHUB_ORG" == "<GITHUB_ORG>" && -z "$PAGES_ORIGIN" ]]; then
  echo "Set GITHUB_ORG (or PAGES_ORIGIN) first, e.g.  GITHUB_ORG=my-org ./aws/make_bucket_public.sh" >&2
  exit 1
fi
# GitHub Pages serves a user's or org's sites from https://<name>.github.io (lowercase).
if [[ -z "$PAGES_ORIGIN" ]]; then
  PAGES_ORIGIN="https://$(printf '%s' "$GITHUB_ORG" | tr '[:upper:]' '[:lower:]').github.io"
fi

say "AWS account $ACCOUNT_ID, bucket $BUCKET, allowed page origin $PAGES_ORIGIN"

# Fill placeholders in the JSON templates
render() {
  sed -e "s|<S3_BUCKET>|$BUCKET|g" \
      -e "s|<GITHUB_PAGES_ORIGIN>|$PAGES_ORIGIN|g" \
      "$HERE/$1" > "$TMP/$1"
  echo "$TMP/$1"
}

# 0. Account-level Block Public Access overrides anything set on the bucket ----
say "0/3 Account-level Block Public Access"
ACCT_BPA="$(aws s3control get-public-access-block --account-id "$ACCOUNT_ID" \
  --query 'PublicAccessBlockConfiguration.[BlockPublicPolicy,RestrictPublicBuckets]' \
  --output text 2>/dev/null || echo "False False")"
if [[ "$ACCT_BPA" == *True* ]]; then
  cat >&2 <<MSG
Your AWS *account* blocks public bucket policies (BlockPublicPolicy/RestrictPublicBuckets: $ACCT_BPA).
Bucket-level settings can't override that. Turn it off in the console under
S3 -> "Block Public Access settings for this account", or run:
  aws s3control put-public-access-block --account-id $ACCOUNT_ID --public-access-block-configuration \\
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=false,RestrictPublicBuckets=false
Then re-run this script.
MSG
  exit 1
fi
echo "OK, the account allows public bucket policies."

# 1. Bucket-level Block Public Access ------------------------------------------
say "1/3 Bucket-level Block Public Access"
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=false,RestrictPublicBuckets=false
echo "Public bucket policies allowed (public ACLs still blocked)."

# 2. Bucket policy ---------------------------------------------------------------
say "2/3 Public read-only bucket policy for scripts/"
if aws s3api get-bucket-policy --bucket "$BUCKET" >/dev/null 2>&1 && [[ "$FORCE_BUCKET_POLICY" != "yes" ]]; then
  echo "Bucket already has a policy; not overwriting it."
  echo "Review it, then re-run with FORCE_BUCKET_POLICY=yes to replace it."
else
  aws s3api put-bucket-policy --bucket "$BUCKET" --policy "file://$(render s3-bucket-policy-public-readonly.json)"
  echo "Anyone can now list and read s3://$BUCKET/scripts/ over HTTPS."
fi

# 3. CORS --------------------------------------------------------------------------
say "3/3 CORS rule for the browser page"
aws s3api put-bucket-cors --bucket "$BUCKET" --cors-configuration "file://$(render s3-cors-github-pages.json)"
echo "A page served from $PAGES_ORIGIN may list the bucket from the browser."

REGION="$(aws s3api get-bucket-location --bucket "$BUCKET" --query LocationConstraint --output text)"
[[ "$REGION" == "None" || -z "$REGION" ]] && REGION="us-east-1"
say "Done."
cat <<MSG
Public file URLs look like:   https://$BUCKET.s3.$REGION.amazonaws.com/scripts/latest/<file>
BUCKET_URL for docs/index.html: https://$BUCKET.s3.$REGION.amazonaws.com
Browser page (after GitHub Pages is on, main branch, /docs folder):
  $PAGES_ORIGIN/<repo-name>/
To undo:  UNDO=yes BUCKET=$BUCKET ./aws/make_bucket_public.sh
MSG
