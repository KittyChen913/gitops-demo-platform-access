#!/usr/bin/env bash

# 從兩個獨立服務確認 GitHub-hosted runner 的公開 IPv4。
# Workflow 會將結果轉成 /32，暫時加入 Linode Firewall inbound rules，
# 只允許該 runner 連入 OpenVPN 主機的 SSH 與 Admin ports。
# 本腳本不修改 Firewall；workflow 結束後必須恢復原始 Firewall baseline。
set -euo pipefail

fetch_ip() {
  local url="$1"

  curl --fail --silent --show-error \
    --retry 3 \
    --retry-all-errors \
    --connect-timeout 10 \
    --max-time 20 \
    "${url}" \
    | tr -d '[:space:]'
}

validate_ipv4() {
  local address="$1"
  local octet
  local -a octets

  if [[ ! "${address}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    return 1
  fi

  IFS='.' read -r -a octets <<< "${address}"
  for octet in "${octets[@]}"; do
    if ((10#${octet} > 255)); then
      return 1
    fi
  done
}

ipify_address="$(fetch_ip 'https://api.ipify.org')"
aws_address="$(fetch_ip 'https://checkip.amazonaws.com')"

if ! validate_ipv4 "${ipify_address}" || ! validate_ipv4 "${aws_address}"; then
  echo "Unable to obtain a valid runner public IPv4 address." >&2
  exit 1
fi

if [[ "${ipify_address}" != "${aws_address}" ]]; then
  echo "Runner public IPv4 cross-check results do not match." >&2
  exit 1
fi

printf '%s\n' "${ipify_address}"
