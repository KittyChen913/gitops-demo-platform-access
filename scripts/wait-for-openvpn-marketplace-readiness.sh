#!/usr/bin/env bash

# 在暫開 TCP/80 期間，等待 Marketplace StackScript 完成 Access Server 安裝
# （含 certbot）。逾時前持續回報第幾次嘗試、失敗原因與剩餘秒數；
# 逾時後印出遠端診斷，協助判斷卡在安裝的哪個階段。
set -euo pipefail

readonly READINESS_TIMEOUT_SECONDS=900
readonly READINESS_RETRY_SECONDS=10
readonly SSH_ATTEMPT_TIMEOUT_SECONDS=15

reserved_ip="${1:-}"
ssh_user="${2:-}"
private_key_file="${3:-}"
known_hosts_file="${4:-}"
credentials_path="${5:-}"

if [[ -z "${reserved_ip}" || -z "${ssh_user}" || ! -f "${private_key_file}" || -L "${private_key_file}" ||
      ! -f "${known_hosts_file}" || -L "${known_hosts_file}" || -z "${credentials_path}" ]]; then
  echo "usage: wait-for-openvpn-marketplace-readiness.sh <reserved-ip> <ssh-user> <private-key-file> <known-hosts-file> <remote-credentials-path>" >&2
  exit 2
fi

ssh_error_file="$(mktemp)"
trap 'rm -f "${ssh_error_file}"' EXIT

ssh_common_args=(
  -i "${private_key_file}"
  -o BatchMode=yes
  -o ConnectTimeout=5
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=1
  -o StrictHostKeyChecking=yes
  -o UserKnownHostsFile="${known_hosts_file}"
)

describe_readiness_failure() {
  local exit_code="$1"

  case "${exit_code}" in
    20) printf '%s\n' 'SSH 已連線，但遠端使用者無法執行免互動 sudo' ;;
    21) printf '%s\n' 'SSH 已連線，但 sacli 尚未安裝或不可執行' ;;
    22) printf '%s\n' 'SSH 已連線，但 openvpnas service 尚未 active' ;;
    23) printf '%s\n' 'SSH 已連線且 openvpnas 已 active，但 .credentials 尚未產生（Marketplace certbot 步驟可能尚未完成）' ;;
    124) printf 'SSH readiness 命令超過 %s 秒\n' "${SSH_ATTEMPT_TIMEOUT_SECONDS}" ;;
    255)
      if grep -qiE 'host key verification failed|remote host identification has changed|no .* host key is known' "${ssh_error_file}"; then
        printf '%s\n' 'SSH host key 驗證失敗；cloud-init 可能尚未安裝 Terraform 管理的 host key'
      elif grep -qiE 'permission denied|authentication failed' "${ssh_error_file}"; then
        printf '%s\n' 'SSH 使用者或 private key 驗證失敗'
      elif grep -qiE 'connection timed out|operation timed out|no route to host|connection refused' "${ssh_error_file}"; then
        printf '%s\n' 'TCP/22 無法連線；請檢查 Linode Firewall runner /32 與 ssh service'
      elif grep -qiE 'connection closed|connection reset|kex_exchange_identification' "${ssh_error_file}"; then
        printf '%s\n' 'SSH transport 或 key exchange 尚未 ready'
      else
        printf '%s\n' 'SSH 連線失敗；請檢查 Firewall、host key 與使用者認證'
      fi
      ;;
    *) printf '遠端 readiness 命令失敗（exit code %s）\n' "${exit_code}" ;;
  esac
}

report_marketplace_diagnostics() {
  local diagnostics_exit

  echo "::group::OpenVPN Marketplace 安裝診斷"
  set +e
  # 遠端命令中的變數應由 VM shell 展開，不可由 runner 預先展開。
  # shellcheck disable=SC2016
  timeout --signal=TERM "${SSH_ATTEMPT_TIMEOUT_SECONDS}s" ssh "${ssh_common_args[@]}" \
    "${ssh_user}@${reserved_ip}" \
    'if ! sudo -n true >/dev/null 2>&1; then
       echo "sudo=unavailable"
       exit 0
     fi

     if sudo -n test -x /usr/local/openvpn_as/scripts/sacli; then
       echo "sacli=present"
     else
       echo "sacli=absent"
     fi

     if dpkg-query -W openvpn-as >/dev/null 2>&1; then
       echo "openvpn_as_package=installed"
     else
       echo "openvpn_as_package=absent"
     fi

     printf "openvpnas_service=%s\n" "$(sudo -n systemctl is-active openvpnas 2>/dev/null || true)"
     printf "cloud_final_service=%s\n" "$(sudo -n systemctl is-active cloud-final.service 2>/dev/null || true)"

     if pgrep -x apt >/dev/null 2>&1 ||
        pgrep -x apt-get >/dev/null 2>&1 ||
        pgrep -x dpkg >/dev/null 2>&1; then
       echo "package_manager=active"
     else
       echo "package_manager=idle"
     fi

     if sudo -n test -r /var/log/stackscript.log; then
       marker_count="$(sudo -n grep -ciE "fatal:|FAILED!|Traceback|ERROR" /var/log/stackscript.log 2>/dev/null || true)"
       printf "stackscript_log=present,error_markers=%s\n" "${marker_count:-unknown}"
     else
       echo "stackscript_log=unavailable"
     fi' \
    2>/dev/null
  diagnostics_exit=$?
  set -e

  if [[ "${diagnostics_exit}" -ne 0 ]]; then
    echo "無法透過 SSH 取得 Marketplace 安裝診斷（exit code ${diagnostics_exit}）。"
  fi
  echo "::endgroup::"
}

remote_check="$(printf 'if ! sudo -n true 2>/dev/null; then exit 20; fi
if ! sudo -n test -x /usr/local/openvpn_as/scripts/sacli; then exit 21; fi
if ! sudo -n systemctl is-active --quiet openvpnas; then exit 22; fi
if ! sudo -n test -f %q; then exit 23; fi' "${credentials_path}")"

deadline=$((SECONDS + READINESS_TIMEOUT_SECONDS))
attempt=0
last_reason='尚未執行 readiness 檢查'

while ((SECONDS < deadline)); do
  attempt=$((attempt + 1))

  set +e
  timeout --signal=TERM "${SSH_ATTEMPT_TIMEOUT_SECONDS}s" ssh "${ssh_common_args[@]}" \
    "${ssh_user}@${reserved_ip}" \
    "${remote_check}" \
    2>"${ssh_error_file}"
  ssh_exit=$?
  set -e

  if [[ "${ssh_exit}" -eq 0 ]]; then
    echo "OpenVPN Access Server 已完成 Marketplace bootstrap。"
    exit 0
  fi

  last_reason="$(describe_readiness_failure "${ssh_exit}")"
  remaining=$((deadline - SECONDS))
  if ((remaining <= 0)); then
    break
  fi

  echo "等待 OpenVPN Access Server ready（第 ${attempt} 次；原因：${last_reason}；剩餘約 ${remaining} 秒）..."
  sleep_seconds=${READINESS_RETRY_SECONDS}
  if ((sleep_seconds > remaining)); then
    sleep_seconds=${remaining}
  fi
  sleep "${sleep_seconds}"
done

report_marketplace_diagnostics
echo "::error title=OpenVPN Bootstrap Timeout::Access Server 未在 ${READINESS_TIMEOUT_SECONDS} 秒內 ready；最後原因：${last_reason}" >&2
exit 1
