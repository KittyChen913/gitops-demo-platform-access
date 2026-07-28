#!/usr/bin/env bash

# 僅供 runtime 使用的 adapter。本機驗證不得針對 Linode 執行此腳本；
# fail-closed cleanup 必須使用 backup。
set -euo pipefail

mode="${1:-}"
firewall_id="${2:-}"
instance_id="${3:-}"
runner_cidr="${4:-}"
backup_file="${5:-}"
admin_port="${6:-}"

[[ "${mode}" == open || "${mode}" == cleanup ]] || { echo "mode must be open or cleanup" >&2; exit 2; }
[[ "${firewall_id}" =~ ^[0-9]+$ && "${instance_id}" =~ ^[0-9]+$ ]] || { echo "invalid Linode identity" >&2; exit 2; }
[[ "${runner_cidr}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/32$ ]] || { echo "runner access must be an IPv4 /32" >&2; exit 2; }
[[ -n "${backup_file}" && -n "${LINODE_TOKEN:-}" ]] || { echo "backup path and LINODE_TOKEN are required" >&2; exit 2; }

api_get() {
  printf 'header = "Authorization: Bearer %s"\n' "${LINODE_TOKEN}" |
    curl --config - --fail --silent --show-error --proto '=https' --tlsv1.2 \
      --connect-timeout 10 --max-time 30 --retry 3 \
      -H 'Accept: application/json' "https://api.linode.com/v4$1"
}

api_put_rules() {
  printf 'header = "Authorization: Bearer %s"\n' "${LINODE_TOKEN}" |
    curl --config - --fail --silent --show-error --proto '=https' --tlsv1.2 \
      --connect-timeout 10 --max-time 30 --retry 3 \
      -X PUT -H 'Content-Type: application/json' --data-binary "@$1" \
      "https://api.linode.com/v4/networking/firewalls/${firewall_id}/rules" >/dev/null
}

if [[ "${mode}" == open ]]; then
  if [[ ! "${admin_port}" =~ ^[1-9][0-9]{0,4}$ ]] || ((10#${admin_port} > 65535)); then
    echo "invalid OpenVPN Admin port" >&2
    exit 2
  fi
  firewall="$(api_get "/networking/firewalls/${firewall_id}")"
  devices="$(api_get "/networking/firewalls/${firewall_id}/devices")"
  rules="$(api_get "/networking/firewalls/${firewall_id}/rules")"
  jq -e '.status == "enabled"' <<<"${firewall}" >/dev/null
  jq -e --argjson instance_id "${instance_id}" '.data | any(.entity.id == $instance_id and .entity.type == "linode")' <<<"${devices}" >/dev/null
  jq -e --arg admin_port "${admin_port}" '[.inbound[]? | select(.action == "ACCEPT" and .protocol == "TCP" and ((.ports | gsub(" "; "") | split(",")) | any(. == "22" or . == $admin_port)))] | length == 0' <<<"${rules}" >/dev/null || {
    echo "unexpected pre-existing SSH/Admin firewall access" >&2
    exit 1
  }
  umask 077
  jq '{inbound, inbound_policy, outbound, outbound_policy}' <<<"${rules}" > "${backup_file}"
  updated="${backup_file}.updated"
  jq --arg cidr "${runner_cidr}" --arg admin_port "${admin_port}" '.inbound += [
    {label:"temporary-runner-ssh",action:"ACCEPT",protocol:"TCP",ports:"22",addresses:{ipv4:[$cidr],ipv6:[]}},
    {label:"temporary-runner-admin",action:"ACCEPT",protocol:"TCP",ports:$admin_port,addresses:{ipv4:[$cidr],ipv6:[]}}
  ]' "${backup_file}" > "${updated}"
  api_put_rules "${updated}"
  rm -f "${updated}"
  echo "Temporary runner /32 access opened after identity checks."
else
  [[ -f "${backup_file}" && ! -L "${backup_file}" ]] || { echo "firewall cleanup backup is missing" >&2; exit 1; }
  api_put_rules "${backup_file}"
  rules="$(api_get "/networking/firewalls/${firewall_id}/rules")"
  expected_rules="$(jq -S -c '{inbound, inbound_policy, outbound, outbound_policy}' "${backup_file}")"
  actual_rules="$(jq -S -c '{inbound, inbound_policy, outbound, outbound_policy}' <<<"${rules}")"
  if [[ "${actual_rules}" != "${expected_rules}" ]]; then
    echo "runner /32 cleanup did not restore the exact Firewall baseline" >&2
    exit 1
  fi
  rm -f "${backup_file}"
  echo "Temporary runner /32 access removed."
fi
