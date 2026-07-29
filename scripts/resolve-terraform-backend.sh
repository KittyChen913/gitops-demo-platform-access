#!/usr/bin/env bash

# 將 deployment 名稱解析為對應的 Terraform root 與 config/shared.json backend
# selector 是唯一來源，避免各 workflow 各自維護一份對應表。
# 產生 backend.hcl 到指定路徑後，於 stdout 印出對應的 Terraform root。
set -euo pipefail

deployment="${1:-}"
backend_file="${2:-}"

if [[ -z "${deployment}" || -z "${backend_file}" ]]; then
  echo "usage: resolve-terraform-backend.sh <credential-bootstrap|base> <backend-file-path>" >&2
  exit 2
fi

case "${deployment}" in
  credential-bootstrap)
    root="terraform/environments/shared/credential-bootstrap"
    backend_selector="credential_bootstrap_backend"
    ;;
  base)
    root="terraform/environments/shared/base"
    backend_selector="terraform_backend"
    ;;
  *)
    echo "The Terraform deployment is unsupported." >&2
    exit 2
    ;;
esac

umask 077
jq -r --arg key "${backend_selector}" \
  '.[$key] | "bucket = \"\(.bucket)\"\nkey = \"\(.key)\"\nregion = \"\(.region // $ENV.AWS_REGION)\"\nencrypt = \"\(.encrypt)\"\nuse_lockfile = \"\(.use_lockfile)\""' \
  "${GITHUB_WORKSPACE}/config/shared.json" > "${backend_file}"

printf '%s\n' "${root}"
