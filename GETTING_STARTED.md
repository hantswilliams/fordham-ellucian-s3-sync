# Getting Started (the "for dummies" version)

This walks you from zero to "I pushed code to GitHub and it showed up in S3,"
using **your own personal GitHub and AWS accounts** for testing. Allow about
30–45 minutes the first time.

---

## What you're building, in plain English

1. You keep the transfer scripts in a GitHub repo (the `scripts/` folder).
2. Every time you push a change to the `main` branch, GitHub runs a small
   automated job (a **GitHub Action**).
3. That job signs in to AWS and copies the `scripts/` folder into an **S3
   bucket**, which is basically a folder in the cloud.
4. Ellucian (or anything else) reads the latest scripts from that bucket.

GitHub signs in to AWS through a **trust relationship**. Nobody stores AWS
passwords or keys in GitHub, and AWS only lets in *your repo's* `main` branch.

```
 you ──git push──▶ GitHub ──Action──▶ AWS S3 bucket ──▶ Ellucian reads it
                                      ├─ scripts/latest/        (always current)
                                      └─ scripts/releases/*.zip (one per commit)
```

---

## Step 0 — What you need before you start

- A Mac with Terminal (Applications → Utilities → Terminal)
- A personal **GitHub** account: https://github.com
- A personal **AWS** account: https://aws.amazon.com (needs a credit card;
  this project costs pennies at most)

Every command below is typed into Terminal. Lines starting with `#` are
comments; you don't type those.

---

## Step 1 — Install the tools

If you don't have **Homebrew** (the Mac app installer for developer tools),
install it first by following the one-line instructions at https://brew.sh.

Then:

```bash
brew install awscli gh git
```

Check they worked (each should print a version number):

```bash
aws --version
gh --version
git --version
```

---

## Step 2 — Give your computer access to your AWS account

Don't use your AWS "root" login (the email you signed up with) for day-to-day
work. Create a separate admin user instead:

1. Sign in to the AWS console: https://console.aws.amazon.com
2. Search for **IAM** in the top search bar and open it.
3. Left menu: **Users** → **Create user**.
   - User name: `hants-admin` (anything works)
   - Click **Next**.
4. Choose **Attach policies directly**, tick **AdministratorAccess**, then
   **Next** → **Create user**.
5. Click the new user → **Security credentials** tab → **Create access key**.
   - Pick **Command Line Interface (CLI)**, tick the confirmation box, **Next**,
     **Create access key**.
   - **Copy both the Access key ID and the Secret access key now.** AWS never
     shows the secret again. Don't paste them into any file in this project.

Back in Terminal:

```bash
aws configure
```

It asks four questions:

| Prompt | What to type |
|---|---|
| AWS Access Key ID | the Access key ID you just copied |
| AWS Secret Access Key | the Secret access key |
| Default region name | `us-east-1` |
| Default output format | `json` |

Check it worked:

```bash
aws sts get-caller-identity
```

You should see your 12-digit account number and `user/hants-admin`. If you
see an error, re-run `aws configure` and paste the keys again carefully.

---

## Step 3 — Sign in to GitHub from Terminal

```bash
gh auth login
```

Pick: **GitHub.com** → **HTTPS** → **Yes** (authenticate Git) →
**Login with a web browser**. It shows a code; press Enter, paste the code in
the browser page that opens, and approve.

Check it worked:

```bash
gh auth status
```

Note your **GitHub username** from that output; you'll need it in Step 5.

---

## Step 4 — Put the project on GitHub (but don't push yet)

Go to the project folder:

```bash
cd ~/Development/Python/fordham-ellucian-s3-sync
```

Save everything as the first commit:

```bash
git add .
git commit -m "Initial scaffold"
```

Create the GitHub repo and link it, **without pushing yet**. The first push
triggers the Action, and it would fail because AWS isn't set up:

```bash
gh repo create fordham-ellucian-s3-sync --private --source=. --remote=origin
```

---

## Step 5 — Set up AWS (one command)

Pick a bucket name. It must be **unique across all of AWS**, lowercase,
with no spaces, so include your name, e.g. `hants-fordham-ellucian-test`.

Replace `<your-github-username>` below with your username from Step 3:

```bash
GITHUB_ORG=<your-github-username> \
BUCKET=hants-fordham-ellucian-test \
./aws/setup_aws.sh
```

You'll see five steps go by. A good first run looks roughly like this:

```
==> 1/5 S3 bucket
Created bucket.
Public access blocked, versioning on, encryption on.

==> 2/5 GitHub OIDC provider
Created.

==> 3/5 IAM role github-actions-fordham-ellucian-s3-sync
Role created.
Permissions policy attached. Role ARN: arn:aws:iam::123456789012:role/github-actions-...

==> 4/5 Ellucian bucket policy
Skipped (set ELLUCIAN_ACCOUNT_ID to enable).

==> 5/5 GitHub repo secret + variable
Set AWS_ROLE_ARN secret and S3_BUCKET variable.

==> Done.
```

It's safe to run again if something goes wrong partway.

**Double-check in GitHub:** open your repo in the browser →
**Settings** → **Secrets and variables** → **Actions**.
- **Secrets** tab should list `AWS_ROLE_ARN`
- **Variables** tab should list `S3_BUCKET`

If step 5 said it couldn't set them, add them by hand on that page using the
values the script printed.

---

## Step 6 — Push and watch it run

```bash
git push -u origin main
```

Watch the Action:

```bash
gh run watch
```

(Or in the browser: your repo → **Actions** tab → click the newest run.)
It should finish with a green check in under a minute.

---

## Step 7 — Confirm the files landed in S3

```bash
aws s3 ls s3://hants-fordham-ellucian-test/scripts/latest/
```

You should see `hello_ellucian.py` and `transfer_files.py`. Read one straight
from S3:

```bash
aws s3 cp s3://hants-fordham-ellucian-test/scripts/latest/hello_ellucian.py -
```

You can also look in the AWS console: search **S3** → your bucket →
`scripts/` → `latest/`.

**🎉 That's the whole pipeline working.**

---

## Step 8 — Prove it updates on every change

Edit `scripts/hello_ellucian.py` and change the message, e.g.:

```python
print("Hello from the Fordham <-> Ellucian shared scripts repo. Version 2!")
```

Then:

```bash
git add scripts/hello_ellucian.py
git commit -m "Test: update hello message"
git push
gh run watch
aws s3 cp s3://hants-fordham-ellucian-test/scripts/latest/hello_ellucian.py -
```

You should see "Version 2!". The old version is still kept as a zip under
`scripts/releases/`:

```bash
aws s3 ls s3://hants-fordham-ellucian-test/scripts/releases/
```

**Good to know:** the Action only runs when something inside `scripts/` (or
the workflow file itself) changes on `main`. Editing only the README won't
trigger it. To run it anyway: GitHub → **Actions** → **Sync scripts to S3** →
**Run workflow**.

---

## Troubleshooting

| What you see | What it means | Fix |
|---|---|---|
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` (in the Action log) | AWS doesn't recognize the repo or branch | Re-run Step 5 with the **exact** GitHub username (it's case-sensitive) and make sure you pushed to `main` |
| `Credentials could not be loaded` / `role-to-assume` is empty | `AWS_ROLE_ARN` secret is missing | Add it under Settings → Secrets and variables → Actions → **Secrets** |
| `Invalid bucket name ""` | `S3_BUCKET` is missing, or was added as a secret instead of a variable | Add it on the **Variables** tab |
| `BucketAlreadyExists` when running the setup script | Someone else in the world already uses that bucket name | Pick a more unique `BUCKET` name and re-run |
| `Unable to locate credentials` on your Mac | `aws configure` wasn't done, or you're using a different profile | Redo Step 2, then check `aws sts get-caller-identity` |
| `Set GITHUB_ORG first` | You forgot the `GITHUB_ORG=...` part | Copy the full command from Step 5 |
| `Missing required field Principal` in the S3 console | An IAM-role policy was pasted into the bucket policy box | See "Which policy goes where" in README.md; the setup script handles this for you |
| `git push` asks for a password | Git isn't using your `gh` login | Run `gh auth setup-git`, then push again |
| The Action didn't run at all | Nothing in `scripts/` changed, or you pushed to another branch | Use **Run workflow** on the Actions tab, or change a script |

For any failed run: GitHub → **Actions** → click the red ❌ run → click the
red step. The actual error is near the bottom of that step's log.

---

## Cleaning up when you're done testing

```bash
# 1. Remove the IAM role (asks for confirmation)
./aws/teardown_aws.sh

# 2. Empty and delete the bucket. Versioning keeps old copies, so the
#    easiest way is the console: S3 → select bucket → Empty → then Delete.

# 3. Delete the GitHub repo if you want
gh repo delete <your-github-username>/fordham-ellucian-s3-sync
```

Finally, in the AWS console → IAM → Users → `hants-admin` → Security
credentials, **deactivate or delete the access key** if you won't use it again.

---

## Moving from personal testing to Fordham

Nothing in the code changes. You:

1. Create the repo under the Fordham GitHub org (or transfer yours there).
2. Sign in to Fordham's AWS account (probably via SSO; ask whoever runs it,
   since creating IAM roles usually needs an admin).
3. Re-run Step 5 with the Fordham org name and a Fordham bucket name. Add
   `ELLUCIAN_ACCOUNT_ID=<their 12-digit AWS account>` to give Ellucian
   read access.
4. Tear down your personal test setup (above).

---

## Tiny glossary

- **Repo**: a project folder tracked by Git and stored on GitHub.
- **Commit / push**: save a snapshot locally / send it up to GitHub.
- **GitHub Action**: a script GitHub runs for you when something happens (like a push).
- **S3 bucket**: a storage container in AWS for files.
- **IAM role**: an AWS identity with specific permissions that something (here, GitHub) can temporarily use.
- **OIDC / trust policy**: how AWS checks that the request really comes from *your* GitHub repo, so no passwords need to be shared.
