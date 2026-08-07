#!/usr/bin/env bash

# 確保 Terraform remote state 使用的 S3 bucket 已存在且符合安全基線。
# 部署順序改為 platform-access 先行之後，本 repo 成為第一個需要 remote
# backend 的 repository，不能再依賴 gitops-demo-cluster 的 bootstrap 先
# 建立 bucket。
#
# 行為為冪等：
#   - bucket 不存在：建立，並套用 Versioning、AES-256 加密與 Public Access Block。
#   - bucket 已存在：只做唯讀驗證，不改寫既有設定；不符基線即 fail closed。
#
# 本腳本不刪除 bucket，也不讀取或寫入任何 state object。bucket 的
# declarative ownership 仍屬 gitops-demo-cluster 的 bootstrap root；這裡只
# 負責 remote backend 的前置條件，因此不重複宣告該資源。
#
# 存在性探測使用 get-bucket-versioning 而非 HeadBucket，避免要求無 prefix
# 條件的 s3:ListBucket，讓 Inline Policy 維持既有的最小 object 範圍。
set -euo pipefail

readonly CONFIG="${GITHUB_WORKSPACE}/config/shared.json"
readonly PROBE_ATTEMPTS=5
readonly PROBE_INTERVAL=3

if [[ ! -f "${CONFIG}" ]]; then
  echo "The canonical configuration file is missing." >&2
  exit 1
fi

bucket="$(jq -r '.terraform_backend.bucket // empty' "${CONFIG}")"
credential_bucket="$(jq -r '.credential_bootstrap_backend.bucket // empty' "${CONFIG}")"
region="$(jq -r '.aws.region // empty' "${CONFIG}")"

if [[ -z "${bucket}" || -z "${region}" ]]; then
  echo "The Terraform backend bucket or AWS region is missing from the canonical configuration." >&2
  exit 1
fi

if [[ "${bucket}" != "${credential_bucket}" ]]; then
  echo "BASE and credential-bootstrap backends must resolve to the same bucket." >&2
  exit 1
fi

readonly bucket region

# 回傳 0 表示 bucket 存在，2 表示確定不存在，1 表示無法判定。
probe_bucket() {
  local output=""
  local status=0

  output="$(aws s3api get-bucket-versioning --bucket "${bucket}" 2>&1)" || status=$?

  if ((status == 0)); then
    return 0
  fi

  if [[ "${output}" == *NoSuchBucket* || "${output}" == *"Not Found"* || "${output}" == *"(404)"* ]]; then
    return 2
  fi

  printf '%s\n' "${output}" >&2
  return 1
}

create_bucket() {
  local output=""
  local status=0

  if [[ "${region}" == "us-east-1" ]]; then
    output="$(aws s3api create-bucket --bucket "${bucket}" --region "${region}" 2>&1)" || status=$?
  else
    output="$(aws s3api create-bucket \
      --bucket "${bucket}" \
      --region "${region}" \
      --create-bucket-configuration "LocationConstraint=${region}" 2>&1)" || status=$?
  fi

  # 併發部署時，另一個 run 可能已先建立同名 bucket，視為成功。
  if ((status != 0)) && [[ "${output}" != *BucketAlreadyOwnedByYou* ]]; then
    printf '%s\n' "${output}" >&2
    echo "Unable to create the Terraform state bucket." >&2
    return 1
  fi
}

wait_for_bucket() {
  local attempt=1

  while ((attempt <= PROBE_ATTEMPTS)); do
    if aws s3api get-bucket-versioning --bucket "${bucket}" >/dev/null 2>&1; then
      return 0
    fi
    echo "第 ${attempt} 次確認 bucket 尚未就緒，${PROBE_INTERVAL} 秒後重試。"
    sleep "${PROBE_INTERVAL}"
    attempt=$((attempt + 1))
  done

  echo "The newly created Terraform state bucket did not become available in time." >&2
  return 1
}

apply_baseline() {
  aws s3api put-bucket-versioning \
    --bucket "${bucket}" \
    --versioning-configuration Status=Enabled

  aws s3api put-bucket-encryption \
    --bucket "${bucket}" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

  aws s3api put-public-access-block \
    --bucket "${bucket}" \
    --public-access-block-configuration \
    'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'
}

verify_baseline() {
  local versioning=""
  local encryption=""
  local public_access=""
  local expected_public_access

  expected_public_access="$(printf 'True\tTrue\tTrue\tTrue')"

  versioning="$(aws s3api get-bucket-versioning \
    --bucket "${bucket}" --query 'Status' --output text 2>/dev/null)" || versioning=""
  if [[ "${versioning}" != "Enabled" ]]; then
    echo "The Terraform state bucket does not have versioning enabled." >&2
    return 1
  fi

  encryption="$(aws s3api get-bucket-encryption --bucket "${bucket}" \
    --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' \
    --output text 2>/dev/null)" || encryption=""
  if [[ "${encryption}" != "AES256" && "${encryption}" != "aws:kms" ]]; then
    echo "The Terraform state bucket does not enforce default encryption." >&2
    return 1
  fi

  public_access="$(aws s3api get-public-access-block --bucket "${bucket}" \
    --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]' \
    --output text 2>/dev/null)" || public_access=""
  if [[ "${public_access}" != "${expected_public_access}" ]]; then
    echo "The Terraform state bucket does not block all public access." >&2
    return 1
  fi
}

probe_status=0
probe_bucket || probe_status=$?

case "${probe_status}" in
  0)
    echo "The Terraform state bucket already exists; verifying the security baseline."
    ;;
  2)
    echo "The Terraform state bucket does not exist; creating it."
    create_bucket
    wait_for_bucket
    apply_baseline
    ;;
  *)
    echo "Unable to determine whether the Terraform state bucket exists." >&2
    exit 1
    ;;
esac

verify_baseline

echo "The Terraform state bucket is ready."
