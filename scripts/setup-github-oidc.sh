#!/usr/bin/env bash
#
# Provision the AWS infrastructure that lets the GitHub Actions pipeline
# (.github/workflows/deploy.yml) deploy this stack with short-lived credentials
# via GitHub OIDC — no long-lived AWS access keys stored in the repo.
#
# It creates (idempotently):
#   1. An IAM OIDC identity provider for token.actions.githubusercontent.com
#   2. An IAM role the workflow assumes, trusted ONLY for this repo on `main`
#   3. A deploy policy scoped to what `sam deploy` needs for this stack
#
# Run it ONCE (or after changing the repo/branch/permissions) with an
# administrator identity. It uses your local AWS CLI profile — it is NOT run by
# CI. After it prints the role ARN, set it as the repo variable
# AWS_DEPLOY_ROLE_ARN (Settings → Secrets and variables → Actions → Variables).
#
# Usage:
#   scripts/setup-github-oidc.sh
#   AWS_PROFILE=maxi80 GITHUB_REPO=maxi80-com/maxi80-backend-swift scripts/setup-github-oidc.sh
#
set -euo pipefail

# ----------------------------------------------------------------------------
# Configuration (override via environment)
# ----------------------------------------------------------------------------
AWS_PROFILE="${AWS_PROFILE:-maxi80}"
AWS_REGION="${AWS_REGION:-eu-central-1}"
GITHUB_REPO="${GITHUB_REPO:-maxi80-com/maxi80-backend-swift}"   # owner/repo
GITHUB_REF="${GITHUB_REF:-refs/heads/main}"                 # branch the role trusts
ROLE_NAME="${ROLE_NAME:-Maxi80BackendGitHubDeploy}"
POLICY_NAME="Maxi80BackendDeployPolicy"
STACK_NAME="${STACK_NAME:-Maxi80Backend-2025}"
# The bootstrap stack `sam deploy` auto-creates (with resolve_s3) to hold its
# managed artifact bucket. CloudFormation actions must be allowed on it too.
SAM_MANAGED_STACK_NAME="${SAM_MANAGED_STACK_NAME:-aws-sam-cli-managed-default}"

OIDC_HOST="token.actions.githubusercontent.com"
OIDC_URL="https://${OIDC_HOST}"
OIDC_AUDIENCE="sts.amazonaws.com"

export AWS_PROFILE AWS_REGION

aws() { command aws --profile "$AWS_PROFILE" --region "$AWS_REGION" "$@"; }

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
echo "Account:   $ACCOUNT_ID"
echo "Region:    $AWS_REGION"
echo "Repo:      $GITHUB_REPO ($GITHUB_REF)"
echo "Role:      $ROLE_NAME"
echo

# ----------------------------------------------------------------------------
# 1. OIDC identity provider
# ----------------------------------------------------------------------------
OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_HOST}"

if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" >/dev/null 2>&1; then
  echo "✓ OIDC provider already exists: $OIDC_ARN"
else
  echo "Creating OIDC provider for ${OIDC_HOST}…"
  # Derive the root CA thumbprint from the IdP's TLS chain rather than hardcoding
  # a value that can rotate. (AWS no longer strictly validates it for well-known
  # IdPs, but the API still requires the argument.)
  THUMBPRINT="$(echo | openssl s_client -servername "$OIDC_HOST" -connect "${OIDC_HOST}:443" -showcerts 2>/dev/null \
    | openssl x509 -fingerprint -sha1 -noout 2>/dev/null \
    | sed 's/.*=//; s/://g' \
    | tr '[:upper:]' '[:lower:]')"
  if [ -z "${THUMBPRINT:-}" ]; then
    echo "ERROR: could not compute OIDC thumbprint via openssl" >&2
    exit 1
  fi
  aws iam create-open-id-connect-provider \
    --url "$OIDC_URL" \
    --client-id-list "$OIDC_AUDIENCE" \
    --thumbprint-list "$THUMBPRINT" >/dev/null
  echo "✓ Created OIDC provider (thumbprint ${THUMBPRINT})"
fi
echo

# ----------------------------------------------------------------------------
# 2. IAM role with a repo/branch-scoped trust policy
# ----------------------------------------------------------------------------
# The sub condition pins WHO can assume the role: only workflows from this repo
# running on the given ref. aud pins the token audience.
TRUST_POLICY="$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Federated": "${OIDC_ARN}" },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_HOST}:aud": "${OIDC_AUDIENCE}",
          "${OIDC_HOST}:sub": "repo:${GITHUB_REPO}:ref:${GITHUB_REF}"
        }
      }
    }
  ]
}
JSON
)"

if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "✓ Role exists, updating trust policy…"
  aws iam update-assume-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-document "$TRUST_POLICY" >/dev/null
else
  echo "Creating role ${ROLE_NAME}…"
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --description "GitHub Actions OIDC deploy role for ${GITHUB_REPO}" \
    --max-session-duration 3600 >/dev/null
  echo "✓ Created role"
fi
echo

# ----------------------------------------------------------------------------
# 3. Deploy permissions (inline policy)
# ----------------------------------------------------------------------------
# Scoped to this stack, region, and account where the AWS APIs allow it. SAM
# creates the Lambda execution roles itself, so iam:CreateRole/PassRole are
# required; they are constrained to roles whose name starts with the stack name.
# The SAM-managed artifact bucket (resolve_s3) is matched by its well-known
# `aws-sam-cli-managed-*` naming. This is deliberately pragmatic, not maximally
# least-privilege — review before using in a multi-tenant account.
DEPLOY_POLICY="$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CloudFormation",
      "Effect": "Allow",
      "Action": [
        "cloudformation:CreateStack",
        "cloudformation:UpdateStack",
        "cloudformation:DescribeStacks",
        "cloudformation:DescribeStackEvents",
        "cloudformation:DescribeStackResources",
        "cloudformation:DescribeStackResource",
        "cloudformation:GetTemplate",
        "cloudformation:GetTemplateSummary",
        "cloudformation:ListStackResources",
        "cloudformation:CreateChangeSet",
        "cloudformation:DescribeChangeSet",
        "cloudformation:ExecuteChangeSet",
        "cloudformation:DeleteChangeSet"
      ],
      "Resource": [
        "arn:aws:cloudformation:${AWS_REGION}:${ACCOUNT_ID}:stack/${STACK_NAME}/*",
        "arn:aws:cloudformation:${AWS_REGION}:${ACCOUNT_ID}:stack/${SAM_MANAGED_STACK_NAME}/*",
        "arn:aws:cloudformation:${AWS_REGION}:aws:transform/Serverless-2016-10-31"
      ]
    },
    {
      "Sid": "SamManagedArtifactBucket",
      "Effect": "Allow",
      "Action": [
        "s3:CreateBucket",
        "s3:GetBucketPolicy",
        "s3:PutBucketPolicy",
        "s3:PutBucketVersioning",
        "s3:PutBucketTagging",
        "s3:PutEncryptionConfiguration",
        "s3:PutBucketPublicAccessBlock",
        "s3:GetObject",
        "s3:PutObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::aws-sam-cli-managed-*",
        "arn:aws:s3:::aws-sam-cli-managed-*/*"
      ]
    },
    {
      "Sid": "Lambda",
      "Effect": "Allow",
      "Action": [
        "lambda:CreateFunction",
        "lambda:UpdateFunctionCode",
        "lambda:UpdateFunctionConfiguration",
        "lambda:GetFunction",
        "lambda:GetFunctionConfiguration",
        "lambda:DeleteFunction",
        "lambda:ListVersionsByFunction",
        "lambda:PublishVersion",
        "lambda:TagResource",
        "lambda:UntagResource",
        "lambda:AddPermission",
        "lambda:RemovePermission",
        "lambda:GetPolicy"
      ],
      "Resource": "arn:aws:lambda:${AWS_REGION}:${ACCOUNT_ID}:function:${STACK_NAME}-*"
    },
    {
      "Sid": "IamForFunctionRoles",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:DeleteRole",
        "iam:GetRole",
        "iam:PassRole",
        "iam:AttachRolePolicy",
        "iam:DetachRolePolicy",
        "iam:PutRolePolicy",
        "iam:DeleteRolePolicy",
        "iam:GetRolePolicy",
        "iam:TagRole",
        "iam:UntagRole"
      ],
      "Resource": "arn:aws:iam::${ACCOUNT_ID}:role/${STACK_NAME}-*"
    },
    {
      "Sid": "ApiGateway",
      "Effect": "Allow",
      "Action": [
        "apigateway:GET",
        "apigateway:POST",
        "apigateway:PUT",
        "apigateway:PATCH",
        "apigateway:DELETE"
      ],
      "Resource": "arn:aws:apigateway:${AWS_REGION}::*"
    },
    {
      "Sid": "EventsSnsCloudWatch",
      "Effect": "Allow",
      "Action": [
        "events:PutRule",
        "events:DeleteRule",
        "events:PutTargets",
        "events:RemoveTargets",
        "events:DescribeRule",
        "sns:CreateTopic",
        "sns:DeleteTopic",
        "sns:GetTopicAttributes",
        "sns:SetTopicAttributes",
        "sns:TagResource",
        "cloudwatch:PutMetricAlarm",
        "cloudwatch:DeleteAlarms",
        "cloudwatch:DescribeAlarms"
      ],
      "Resource": "*"
    }
  ]
}
JSON
)"

echo "Attaching inline deploy policy ${POLICY_NAME}…"
aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "$POLICY_NAME" \
  --policy-document "$DEPLOY_POLICY" >/dev/null
echo "✓ Policy attached"
echo

ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
cat <<DONE
──────────────────────────────────────────────────────────────────────────────
Done. Deploy role ARN:

  ${ROLE_ARN}

Next step — make it available to the workflow as a repo variable:

  gh variable set AWS_DEPLOY_ROLE_ARN \\
    --repo ${GITHUB_REPO} \\
    --body "${ROLE_ARN}"

(or via the GitHub UI: Settings → Secrets and variables → Actions → Variables).
──────────────────────────────────────────────────────────────────────────────
DONE
