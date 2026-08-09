#!/usr/bin/env bash

# 讀取 gitops-demo-infra 發布的 ArgoCD private endpoint hand-off parameters，
# 驗證形狀後輸出成 mode 0600 的 JSON，供 SYNC playbook 消費。
#
# 設計約束：
#   - environment config 只維護授權群組；parameter 路徑與 hostname contract 由環境推導，
#     不讀取另一個 Repository 的 Terraform state，也不接受呼叫端直接傳入 endpoint 值。
#   - endpoint 值不進 Git；本腳本輸出的暫存檔由呼叫端負責清除。
#   - 任何形狀不符一律 fail closed，不猜測或正規化輸入。
#   - Dev 與 Prod 的 parameter 路徑固定在各自的 ArgoCD platform namespace。
set -euo pipefail

usage() {
  echo "usage: load-sync-endpoint.sh <dev|prod> <output-json-path>" >&2
  exit 2
}

readonly ENVIRONMENT="${1:-}"
readonly OUTPUT_PATH="${2:-}"

if [[ -z "${ENVIRONMENT}" || -z "${OUTPUT_PATH}" ]]; then
  usage
fi

if [[ ! "${ENVIRONMENT}" =~ ^(dev|prod)$ ]]; then
  usage
fi

readonly REPO_ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
readonly SHARED_CONFIG="${REPO_ROOT}/config/shared.json"
readonly ENVIRONMENT_CONFIG="${REPO_ROOT}/config/environments/${ENVIRONMENT}.json"

for config_file in "${SHARED_CONFIG}" "${ENVIRONMENT_CONFIG}"; do
  if [[ ! -f "${config_file}" || -L "${config_file}" ]]; then
    echo "The canonical configuration file is missing: ${config_file}" >&2
    exit 1
  fi
done

# 每個 octet 必須落在 0-255，且不接受前導零，避免 "010.1.1.1" 這類
# 在不同解析器下語意不一致的寫法通過驗證。
validate_ipv4() {
  local candidate="$1"
  local octet

  if [[ ! "${candidate}" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
    return 1
  fi

  for octet in "${BASH_REMATCH[@]:1:4}"; do
    if [[ "${#octet}" -gt 1 && "${octet:0:1}" == "0" ]]; then
      return 1
    fi
    if [[ "${octet}" -gt 255 ]]; then
      return 1
    fi
  done

  return 0
}

validate_public_ipv4() {
  local candidate="$1"
  local first second third

  validate_ipv4 "${candidate}" || return 1
  IFS=. read -r first second third _ <<< "${candidate}"

  ((first != 0 && first != 10 && first != 127 && first < 224)) || return 1
  ! ((first == 100 && second >= 64 && second <= 127)) || return 1
  ! ((first == 169 && second == 254)) || return 1
  ! ((first == 172 && second >= 16 && second <= 31)) || return 1
  ! ((first == 192 && second == 0 && third == 0)) || return 1
  ! ((first == 192 && second == 0 && third == 2)) || return 1
  ! ((first == 192 && second == 88 && third == 99)) || return 1
  ! ((first == 192 && second == 168)) || return 1
  ! ((first == 198 && (second == 18 || second == 19))) || return 1
  ! ((first == 198 && second == 51 && third == 100)) || return 1
  ! ((first == 203 && second == 0 && third == 113)) || return 1

  return 0
}

validate_domain() {
  local candidate="$1"
  local label
  local -a labels

  [[ "${#candidate}" -le 253 && "${candidate}" != .* && "${candidate}" != *. ]] || return 1
  IFS=. read -r -a labels <<< "${candidate}"
  for label in "${labels[@]}"; do
    [[ "${#label}" -ge 1 && "${#label}" -le 63 ]] || return 1
    if [[ "${#label}" -eq 1 ]]; then
      [[ "${label}" =~ ^[a-z0-9]$ ]] || return 1
    else
      [[ "${label}" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$ ]] || return 1
    fi
  done
}

internal_domain="$(jq -er '.network.internal_domain' "${SHARED_CONFIG}")"
config_environment="$(jq -er '.environment' "${ENVIRONMENT_CONFIG}")"
config_schema_version="$(jq -er '.schema_version' "${ENVIRONMENT_CONFIG}")"
readonly internal_domain config_environment config_schema_version

# Environment config 只保存真正需要版本化的授權矩陣。Parameter 路徑、hostname
# 與 TCP/443 都可由 environment 和 Shared internal domain 唯一推導，不再複製。
if [[ "${config_environment}" != "${ENVIRONMENT}" || "${config_schema_version}" != "1" ]]; then
  echo "The endpoint environment configuration is invalid." >&2
  exit 1
fi

if ! validate_domain "${internal_domain}"; then
  echo "The internal domain is invalid." >&2
  exit 1
fi

readonly ip_parameter="/gitops/${ENVIRONMENT}/platform/argocd/ENDPOINT_IP"
readonly hostname_parameter="/gitops/${ENVIRONMENT}/platform/argocd/ENDPOINT_HOSTNAME"
readonly EXPECTED_HOSTNAME="argocd.${ENVIRONMENT}.internal.${internal_domain}"

# Endpoint parameters 由 gitops-demo-infra 的 private-network root 建立。
# 讀不到通常代表該 root 尚未 apply 或已被 destroy，此時不應繼續套用 SYNC。
if ! endpoint_ip="$(aws ssm get-parameter --name "${ip_parameter}" --query Parameter.Value --output text 2>/dev/null)"; then
  echo "The endpoint IP parameter is unavailable: ${ip_parameter}" >&2
  echo "Apply the private-network root in gitops-demo-infra before running SYNC." >&2
  exit 1
fi

if ! endpoint_hostname="$(aws ssm get-parameter --name "${hostname_parameter}" --query Parameter.Value --output text 2>/dev/null)"; then
  echo "The endpoint hostname parameter is unavailable: ${hostname_parameter}" >&2
  echo "Apply the private-network root in gitops-demo-infra before running SYNC." >&2
  exit 1
fi

readonly endpoint_ip endpoint_hostname

if [[ "${endpoint_ip}" =~ [[:space:]] ]] || ! validate_public_ipv4 "${endpoint_ip}"; then
  echo "The endpoint IP is not a valid public IPv4 address." >&2
  exit 1
fi

if [[ "${endpoint_hostname}" =~ [[:space:]] ]] || [[ "${endpoint_hostname}" != "${EXPECTED_HOSTNAME}" ]]; then
  echo "The endpoint hostname does not match the internal domain contract." >&2
  exit 1
fi

umask 077
if [[ -L "${OUTPUT_PATH}" || ( -e "${OUTPUT_PATH}" && ! -f "${OUTPUT_PATH}" ) ]]; then
  echo "The endpoint output path must be a regular file." >&2
  exit 1
fi

output_directory="$(dirname -- "${OUTPUT_PATH}")"
readonly output_directory
if [[ ! -d "${output_directory}" || -L "${output_directory}" ]]; then
  echo "The endpoint output directory is invalid." >&2
  exit 1
fi

temporary_output="$(mktemp "${OUTPUT_PATH}.tmp.XXXXXX")"
readonly temporary_output
trap 'rm -f -- "${temporary_output}"' EXIT
chmod 600 "${temporary_output}"

jq -n \
  --arg environment "${ENVIRONMENT}" \
  --arg endpoint_ip "${endpoint_ip}" \
  --arg endpoint_hostname "${endpoint_hostname}" \
  '{
    environment: $environment,
    endpoint_ip: $endpoint_ip,
    endpoint_cidr: ($endpoint_ip + "/32"),
    endpoint_hostname: $endpoint_hostname
  }' > "${temporary_output}"

mv -f -- "${temporary_output}" "${OUTPUT_PATH}"
trap - EXIT

echo "Resolved the ${ENVIRONMENT} ArgoCD endpoint contract."
