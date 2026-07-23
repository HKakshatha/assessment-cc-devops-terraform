# FSL DevOps Challenge — Errors Encountered & Fixes Applied

A complete log of every real error hit during this project, what caused it, and how it was fixed. Use this as a reference during the actual challenge.

---

## Terraform Errors

### 1. `BucketAlreadyExists` on `aws_s3_bucket.app`

**Stage:** `terraform apply`

**Error:**
```
Error: creating S3 Bucket (rdicidr-app-devel): BucketAlreadyExists:
The requested bucket name is not available. The bucket namespace is
shared by all users of the system.
```

**Root Cause:**
S3 bucket names are globally unique across ALL AWS accounts on Earth. The name `rdicidr-app-devel` was already taken by another account (possibly another challenge candidate using the same repo).

**Fix:**
Added `random_id.suffix` resource to generate a random hex string, appended to bucket names:
```hcl
resource "random_id" "suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "app" {
  bucket = "rdicidr-app-${var.environment}-${random_id.suffix.hex}"
}
```
Also required adding the `random` provider to `required_providers` and re-running `terraform init`.

---

### 2. `AccessControlListNotSupported` on `aws_s3_bucket_acl.logs`

**Stage:** `terraform apply`

**Error:**
```
Error: creating S3 Bucket ACL: AccessControlListNotSupported:
The bucket does not allow ACLs
```

**Root Cause:**
Since April 2023, AWS disables ACLs on all new S3 buckets by default (`BucketOwnerEnforced` mode). CloudFront's legacy logging requires ACL `log-delivery-write` on the logs bucket, which fails if ACLs are disabled.

**Fix:**
Added `aws_s3_bucket_ownership_controls` to explicitly enable ACLs on the logs bucket, with `depends_on` to ensure correct ordering:
```hcl
resource "aws_s3_bucket_ownership_controls" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_acl" "logs" {
  depends_on = [aws_s3_bucket_ownership_controls.logs]
  bucket     = aws_s3_bucket.logs.id
  acl        = "log-delivery-write"
}
```

---

### 3. `InvalidArgument: Logging Bucket does not refer to a valid S3 bucket`

**Stage:** `terraform apply`

**Error:**
```
Error: creating CloudFront Distribution: InvalidArgument:
The parameter Logging Bucket does not refer to a valid S3 bucket.
```

**Root Cause:**
CloudFront's `logging_config.bucket` expects the S3 bucket's **domain name format** (`name.s3.amazonaws.com`), NOT the plain bucket name. Using `aws_s3_bucket.logs.bucket` (plain name) or `aws_s3_bucket.logs.bucket_regional_domain_name` (has region in it) both fail.

**Fix:**
Changed to `.bucket_domain_name` which produces the correct no-region domain format:
```hcl
logging_config {
  bucket          = aws_s3_bucket.logs.bucket_domain_name  # ✅ name.s3.amazonaws.com
  include_cookies = false
  prefix          = "cloudfront/logs/"
}
```

---

### 4. `InvalidArgument: S3 bucket does not enable ACL access` (race condition)

**Stage:** `terraform apply`

**Error:**
```
Error: creating CloudFront Distribution: InvalidArgument:
The S3 bucket that you specified for CloudFront logs does not enable ACL access
```

**Root Cause:**
Terraform was creating the CloudFront distribution in parallel with the `aws_s3_bucket_acl.logs` resource, since there was no explicit dependency between them. CloudFront validated the logs bucket's ACL state before the ACL resource had finished applying — a classic race condition.

**Fix:**
Added explicit `depends_on` to the CloudFront distribution to force it to wait for the ACL to be ready:
```hcl
resource "aws_cloudfront_distribution" "app" {
  depends_on = [aws_s3_bucket_acl.logs]
  ...
}
```

---

### 5. `openpgp: key expired` during `terraform init`

**Stage:** GitHub Actions — `terraform init`

**Error:**
```
Error: Failed to install provider
Error while installing hashicorp/aws v6.56.0: error checking signature:
openpgp: key expired
```

**Root Cause:**
Terraform version `1.6.0` had an expired GPG signing key, causing provider downloads to fail signature verification on the GitHub Actions runner.

**Fix:**
Upgraded Terraform version in the workflow to `1.9.0`:
```yaml
- name: Setup Terraform
  uses: hashicorp/setup-terraform@v2
  with:
    terraform_version: 1.9.0
```

---

### 6. `Workspace "devel" doesn't exist` in GitHub Actions

**Stage:** GitHub Actions — `terraform workspace select devel`

**Error:**
```
Workspace "devel" doesn't exist.
You can create this workspace with the "new" subcommand
or include the "-or-create" flag with the "select" subcommand.
```

**Root Cause:**
The GitHub Actions runner starts from a clean slate every run. Workspaces created locally don't exist on the runner — it only has the `default` workspace initially.

**Fix:**
Added `-or-create` flag to automatically create the workspace if it doesn't exist:
```yaml
run: terraform workspace select -or-create devel
```

---

### 7. `No valid credential sources found` for Terraform

**Stage:** GitHub Actions — `terraform apply`

**Error:**
```
Error: No valid credential sources found
Please see https://registry.terraform.io/providers/hashicorp/aws
for more information about providing credentials.
```

**Root Cause:**
GitHub Secrets were misconfigured — the access key ID itself was used as the secret name instead of `AWS_ACCESS_KEY_ID`. Only one secret existed instead of two.

**Fix:**
Deleted the incorrect secret and added two correctly named repository secrets:
- `AWS_ACCESS_KEY_ID` → value: the access key ID
- `AWS_SECRET_ACCESS_KEY` → value: the secret access key

Referenced in workflow at job level:
```yaml
env:
  AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
  AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
  AWS_DEFAULT_REGION: us-east-1
```

---

### 8. Remote state conflict — resources already exist in AWS

**Stage:** GitHub Actions — `terraform apply`

**Error:**
```
Error: creating S3 Bucket (rdicidr-cloudfront-access-logs-devel): BucketAlreadyExists
Error: creating CloudFront Origin Access Control: OriginAccessControlAlreadyExists
```

**Root Cause:**
Terraform state was stored locally on the developer's Mac. The GitHub Actions runner had no access to that state file, so it thought nothing existed and tried to create everything from scratch — but the resources were already in AWS from local applies.

**Fix:**
Set up S3 remote backend so both local machine and runner share the same state:

1. Created a dedicated state bucket:
```bash
aws s3api create-bucket --bucket rdicidr-terraform-state-800174642443 --region us-east-1
aws s3api put-bucket-versioning --bucket rdicidr-terraform-state-800174642443 \
  --versioning-configuration Status=Enabled
```

2. Added backend config to `main.tf`:
```hcl
terraform {
  backend "s3" {
    bucket = "rdicidr-terraform-state-800174642443"
    key    = "rdicidr/terraform.tfstate"
    region = "us-east-1"
  }
  ...
}
```

3. Destroyed all existing resources locally first, then re-ran `terraform init` to migrate to the remote backend.

---

### 9. `Invalid format` on `terraform output` in GitHub Actions

**Stage:** GitHub Actions — Get Terraform Output step

**Error:**
```
Error: Unable to process file command 'output' successfully.
Error: Invalid format 'rdicidr-app-devel-fdb9569e::debug::Terraform exited with code 0.'
```

**Root Cause:**
`hashicorp/setup-terraform@v2` wraps Terraform output with debug text by default. This extra text breaks parsing when capturing output with `>> $GITHUB_OUTPUT`.

**Fix:**
Added `terraform_wrapper: false` to the Setup Terraform step:
```yaml
- name: Setup Terraform
  uses: hashicorp/setup-terraform@v2
  with:
    terraform_version: 1.9.0
    terraform_wrapper: false
```

---

## GitHub Actions / npm Errors

### 10. `ENOENT: package.json not found`

**Stage:** GitHub Actions — `npm install`

**Error:**
```
npm error code ENOENT
npm error path /home/runner/work/.../package.json
npm error enoent Could not read package.json
```

**Root Cause:**
The workflow ran `npm install` from the repo root, but `package.json` lives inside `codebase/rdicidr-0.1.0/`. The workflow files were created while inside that subdirectory, so the working directory assumption was wrong.

**Fix:**
Added `working-directory` to npm steps:
```yaml
- name: Install dependencies
  working-directory: codebase/rdicidr-0.1.0
  run: npm install

- name: Build app
  working-directory: codebase/rdicidr-0.1.0
  run: npm run build
```

Also updated the S3 sync path:
```yaml
- name: Deploy to S3
  run: aws s3 sync codebase/rdicidr-0.1.0/build/ s3://${{ steps.tf_outputs.outputs.bucket_name }} --delete
```

---

### 11. `EBADENGINE: Unsupported engine` — Node version mismatch

**Stage:** GitHub Actions — `npm install`

**Error:**
```
npm error code EBADENGINE
npm error notsup Required: {"node":">=15.0.0 <16.0.0"}
npm error notsup Actual: {"node":"v18.20.8"}
```

**Root Cause:**
The app (`rdicidr@0.1.0`) requires Node 15.x. The workflow was configured with Node 18, which is incompatible.

**Fix:**
Changed node version in workflow to match what CI was already using:
```yaml
- name: Set up Node.js
  uses: actions/setup-node@v3
  with:
    node-version: '15.5.1'
```

---

### 12. CD workflows not triggering — wrong file location

**Stage:** GitHub Actions — CD workflow not appearing

**Problem:**
`cd-devel.yaml` and `cd-stage.yaml` were created while inside `codebase/rdicidr-0.1.0/`, so they ended up at `codebase/rdicidr-0.1.0/.github/workflows/` instead of the repo root `.github/workflows/`. GitHub only reads workflows from the repo root.

**Fix:**
Copied the files to the correct location:
```bash
cp codebase/rdicidr-0.1.0/.github/workflows/cd-devel.yaml .github/workflows/
cp codebase/rdicidr-0.1.0/.github/workflows/cd-stage.yaml .github/workflows/
```

---

### 13. CI not triggering on `devel`/`stage` PRs

**Stage:** GitHub Actions — CI not running on new PRs

**Problem:**
`ci.yaml` trigger only listed `main`:
```yaml
on:
  pull_request:
    branches:
      - main
```
PRs targeting `devel` or `stage` didn't trigger CI.

**Fix:**
```yaml
on:
  pull_request:
    branches:
      - main
      - devel
      - stage
```

---

## S3 Cleanup Errors

### 14. `BucketNotEmpty` when running `terraform destroy`

**Stage:** `terraform destroy`

**Error:**
```
Error: deleting S3 Bucket: BucketNotEmpty:
The bucket you tried to delete is not empty
```

**Root Cause:**
Terraform blocks deletion of non-empty S3 buckets by default (a safety guard). The app bucket had files synced to it, and the logs bucket had CloudFront access logs.

**Fix:**
Manually empty the bucket first, then destroy:
```bash
aws s3 rm s3://<bucket-name> --recursive
terraform destroy -var="environment=devel"
```

---

### 15. `BucketNotEmpty` when deleting versioned state bucket

**Stage:** Manual AWS CLI cleanup

**Error:**
```
An error occurred (BucketNotEmpty) when calling the DeleteBucket operation:
The bucket you tried to delete is not empty. You must delete all versions in the bucket.
```

**Root Cause:**
The state bucket had versioning enabled (intentionally, for state history). `aws s3 rm --recursive` only deletes current object versions, not older versions and delete markers.

**Fix:**
Delete all versions and delete markers explicitly before deleting the bucket:
```bash
# Delete all versions
aws s3api delete-objects --bucket rdicidr-terraform-state-800174642443 \
  --delete "$(aws s3api list-object-versions --bucket rdicidr-terraform-state-800174642443 \
  --query '{Objects: Versions[].{Key: Key, VersionId: VersionId}}' --output json)"

# Delete all delete markers
aws s3api delete-objects --bucket rdicidr-terraform-state-800174642443 \
  --delete "$(aws s3api list-object-versions --bucket rdicidr-terraform-state-800174642443 \
  --query '{Objects: DeleteMarkers[].{Key: Key, VersionId: VersionId}}' --output json)"

# Now delete the bucket
aws s3api delete-bucket --bucket rdicidr-terraform-state-800174642443 --region us-east-1
```

---

## Key Lessons

| Pattern | What to Remember |
|---|---|
| `validate`/`plan` pass ≠ `apply` will succeed | AWS API errors only surface at apply time |
| S3 bucket names are globally unique | Always add random suffix or account ID |
| Modern S3 buckets have ACLs disabled | CloudFront logging needs `BucketOwnerPreferred` + ACL |
| CloudFront logging needs domain name format | Use `.bucket_domain_name`, not `.bucket` or `.bucket_regional_domain_name` |
| GitHub Actions runner is always fresh | Remote state (S3 backend) needed for shared Terraform state |
| `setup-terraform@v2` wraps output | Add `terraform_wrapper: false` when capturing `terraform output` |
| Terraform workspaces are local | Use `-or-create` flag in CI, or workspaces are auto-created |
| Non-empty S3 buckets can't be destroyed | Always `aws s3 rm --recursive` before `terraform destroy` |
