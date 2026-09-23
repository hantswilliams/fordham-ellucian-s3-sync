#!/usr/bin/env bash
# Removes the IAM role created by setup_aws.sh.
# Deliberately leaves the bucket (it holds your files) and the GitHub OIDC
# provider (other repos in the account may use it). Commands to remove those
# are printed at the end.
set -euo pipefail

BUCKET="${BUCKET:-fordham-ellucian-scripts}"
ROLE_NAME="${ROLE_NAME:-github-actions-fordham-ellucian-s3-sync}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

read -r -p "Delete IAM role $ROLE_NAME in account $ACCOUNT_ID? [y/N] " ok
[[ "$ok" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }

aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name s3-sync-scripts 2>/dev/null || true
aws iam delete-role --role-name "$ROLE_NAME" && echo "Role deleted."

cat <<MSG

Not deleted (run by hand only if you're sure):
  # bucket and every object/version in it
  aws s3 rb s3://$BUCKET --force      # fails if versioned objects remain; empty them in the console first
  # GitHub OIDC provider (affects every repo using GitHub->AWS login in this account)
  aws iam delete-open-id-connect-provider --open-id-connect-provider-arn arn:aws:iam::$ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com
MSG
