# fordham-ellucian-s3-sync

> **New here?** Follow [GETTING_STARTED.md](GETTING_STARTED.md) for step-by-step setup and testing.

Shared scripts for moving files between **Fordham** and **Ellucian**.
GitHub is the source of truth; every push to `main` copies the latest
`scripts/` folder to an S3 bucket that both sides can read.

```
developer ──git push──▶ GitHub (main)
                           │
                           ▼  GitHub Action: sync-to-s3.yml
                     S3 bucket
                     ├── scripts/latest/          ← always mirrors main
                     └── scripts/releases/<sha>.zip ← one archive per commit
                           │
                           ▼
                  Ellucian / Fordham jobs pull from scripts/latest/
```

## Layout

| Path | What it is |
|---|---|
| `scripts/` | The code that gets shipped to S3 |
| `.github/workflows/sync-to-s3.yml` | The Action that runs on push to `main` |
| `aws/github-oidc-trust-policy.json` | Trust policy so GitHub can assume an AWS role (no stored keys) |
| `aws/s3-sync-permissions-policy.json` | Minimal S3 permissions for that role |
| `docs/index.html` | Optional: a web page that browses the bucket, served by GitHub Pages |
| `aws/make_bucket_public.sh` | Optional: makes `scripts/` public + adds CORS so that page works (`UNDO=yes` reverts) |

## One-time setup

### Which policy goes where

| File | Attach it to | Has `Principal`? | Answers |
|---|---|---|---|
| `aws/github-oidc-trust-policy.json` | IAM role → **Trust relationships** | Yes (GitHub's OIDC provider) | *Who* may assume the role |
| `aws/s3-sync-permissions-policy.json` | IAM role → **Permissions** (inline policy) | No | *What* the role may do in S3 |
| `aws/s3-bucket-policy-ellucian-readonly.json` | S3 bucket → **Permissions → Bucket policy** | Yes (Ellucian's account) | Optional: lets Ellucian read `scripts/latest/` |
| `aws/s3-bucket-policy-public-readonly.json` | S3 bucket → **Permissions → Bucket policy** | Yes (`*`, everyone) | Optional: lets anyone list and read `scripts/` |
| `aws/s3-cors-github-pages.json` | S3 bucket → **Permissions → CORS** | n/a | Optional: lets the GitHub Pages browser page call the bucket |

Neither of the first two goes on the bucket.

### Scripted (recommended)

Needs the AWS CLI v2, signed in as someone who can manage IAM and S3, and
the `gh` CLI signed in with the repo already created on GitHub (the script
asks GitHub for the repo's exact OIDC subject; see below).

```bash
aws sso login --profile fordham && export AWS_PROFILE=fordham   # or however you sign in

GITHUB_ORG=<your-github-org> \
BUCKET=fordham-ellucian-scripts \
./aws/setup_aws.sh
```

It creates the bucket (private, versioned, encrypted), the GitHub OIDC
provider, and the IAM role with both policies, then prints the role ARN.
If the `gh` CLI is signed in and the repo exists, it also sets the
`AWS_ROLE_ARN` secret and `S3_BUCKET` variable. Safe to re-run.

Optional settings: `REGION`, `ROLE_NAME`, `GITHUB_REPO`,
`ELLUCIAN_ACCOUNT_ID` (adds the Ellucian read-only bucket policy),
`SET_GITHUB_SETTINGS=no`, `GITHUB_SUB_PREFIX` (skip the GitHub lookup).

`./aws/teardown_aws.sh` removes the role. It leaves the bucket and OIDC
provider alone and prints the commands to remove them.

### By hand (console)

1. **S3 bucket**: create it, block public access, turn on versioning.
2. **OIDC provider**: IAM → Identity providers → Add → OpenID Connect,
   URL `https://token.actions.githubusercontent.com`, audience `sts.amazonaws.com`.
3. **IAM role**: IAM → Roles → Create role → Web identity → the provider above.
   Replace its trust policy with `aws/github-oidc-trust-policy.json`, filling in
   `<AWS_ACCOUNT_ID>` and `<GITHUB_SUB_PREFIX>`. Get the prefix from GitHub rather
   than typing it: repos created after July 2026 send `repo:org@123/repo@456`
   (owner ID and repo ID), older ones send `repo:org/repo`, and a mismatch fails
   with `Not authorized to perform sts:AssumeRoleWithWebIdentity`.
   ```bash
   gh api repos/<org>/<repo>/actions/oidc/customization/sub --jq .sub_claim_prefix
   ```
   Then add an inline policy from `aws/s3-sync-permissions-policy.json`.
4. **GitHub**: Settings → Secrets and variables → Actions:
   secret `AWS_ROLE_ARN`, variable `S3_BUCKET`.
5. Set `AWS_REGION` in the workflow if you're not in `us-east-1`.

## Try it

```bash
git init -b main          # already done if you see a .git folder
git add .
git commit -m "Initial scaffold"
git remote add origin git@github.com:<GITHUB_ORG>/fordham-ellucian-s3-sync.git
git push -u origin main
```

Then check the **Actions** tab, and:

```bash
aws s3 ls s3://<S3_BUCKET>/scripts/latest/
```

## Run a script locally

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
DRY_RUN=true python scripts/transfer_files.py
```

## Optional: a public web view of the bucket (GitHub Pages)

`docs/index.html` is a single self-contained page that lists the bucket live
in the browser (folders, files, sizes, dates, direct links). The default
setup keeps the bucket private; turning this on makes everything under
`scripts/` readable by anyone on the internet. Three steps:

1. **GitHub Pages**: repo → Settings → Pages → Source "Deploy from a branch",
   branch `main`, folder `/docs`. Pages on a *private* repo needs GitHub Pro
   (personal) or Team/Enterprise (org); on the Free plan the repo must be public.
   The published page is public either way.
   The page appears at `https://<org>.github.io/fordham-ellucian-s3-sync/`.
2. **Bucket**: allow public reads and the page's origin (asks nothing, safe to re-run):
   ```bash
   GITHUB_ORG=<your-github-org> BUCKET=<your-bucket> ./aws/make_bucket_public.sh
   ```
   It turns off the policy-blocking Block Public Access switches, applies
   `aws/s3-bucket-policy-public-readonly.json` and `aws/s3-cors-github-pages.json`,
   and refuses to overwrite an existing bucket policy unless `FORCE_BUCKET_POLICY=yes`.
   If the bucket policy already grants Ellucian access, merge the statements instead.
3. **Page settings**: in `docs/index.html` set `BUCKET_URL` to the regional
   endpoint the script prints (`https://<bucket>.s3.<region>.amazonaws.com`).

Undo with `UNDO=yes BUCKET=<your-bucket> ./aws/make_bucket_public.sh`, which
removes the policy and CORS rule and turns Block Public Access fully back on.

## Giving Ellucian access

Options, simplest first:
- **Public bucket + browser page** (above) if the scripts hold nothing sensitive.
- **Bucket policy** granting Ellucian's AWS account read on `scripts/latest/*`.
- **Separate IAM user/role** for Ellucian with read-only access to that prefix.
- **Presigned URLs** if they don't have AWS at all.
