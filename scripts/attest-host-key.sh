#!/usr/bin/env bash

# 每次部署都先確認 control plane resource 關係，再驗證或建立 SSH host-key pin。
# 此腳本絕不接受未釘選的 SSH session：先驗證 Instance／IP／Firewall，
# 再釘選掃描到的 public key，最後以 StrictHostKeyChecking=yes 驗證同一把 key。
set -euo pipefail

instance_id="${1:-}"
firewall_id="${2:-}"
reserved_ip="${3:-}"
runner_cidr="${4:-}"
host_key_parameter="${5:-}"
known_hosts_file="${6:-}"
private_key_file="${7:-}"
ssh_user="${8:-}"
expected_label="${9:-}"
admin_port="${10:-}"

validate_ipv4() {
  local address="$1"
  local octet
  local -a octets

  [[ "${address}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a octets <<<"${address}"
  for octet in "${octets[@]}"; do
    ((10#${octet} <= 255)) || return 1
  done
}

[[ "${instance_id}" =~ ^[0-9]+$ && "${firewall_id}" =~ ^[0-9]+$ ]] || { echo "invalid Linode identity" >&2; exit 2; }
if ! validate_ipv4 "${reserved_ip}" || [[ "${runner_cidr}" != */32 ]] || ! validate_ipv4 "${runner_cidr%/32}"; then
  echo "invalid IPv4 contract" >&2
  exit 2
fi
[[ "${host_key_parameter}" == /gitops/platform-access/* && -f "${private_key_file}" ]] || { echo "invalid host-key or SSH credential contract" >&2; exit 2; }
[[ -n "${LINODE_TOKEN:-}" && -n "${ssh_user}" && -n "${expected_label}" ]] || { echo "runtime credentials and identity inputs are required" >&2; exit 2; }
if [[ ! "${admin_port}" =~ ^[1-9][0-9]{0,4}$ ]] || ((10#${admin_port} > 65535)); then
  echo "invalid OpenVPN Admin port" >&2
  exit 2
fi

api_get() {
  printf 'header = "Authorization: Bearer %s"\n' "${LINODE_TOKEN}" |
    curl --config - --fail --silent --show-error --proto '=https' --tlsv1.2 \
      --connect-timeout 10 --max-time 30 --retry 3 --retry-all-errors \
      -H 'Accept: application/json' "https://api.linode.com/v4$1"
}

instance="$(api_get "/linode/instances/${instance_id}")"
ip_record="$(api_get "/networking/ips/${reserved_ip}")"
firewall="$(api_get "/networking/firewalls/${firewall_id}")"
devices="$(api_get "/networking/firewalls/${firewall_id}/devices")"
rules="$(api_get "/networking/firewalls/${firewall_id}/rules")"

jq -e --arg label "${expected_label}" --arg ip "${reserved_ip}" '.status == "running" and .label == $label and (.ipv4 | index($ip) != null)' <<<"${instance}" >/dev/null
jq -e --argjson instance_id "${instance_id}" '.reserved == true and .linode_id == $instance_id' <<<"${ip_record}" >/dev/null
jq -e '.status == "enabled"' <<<"${firewall}" >/dev/null
jq -e --argjson instance_id "${instance_id}" '.data | any(.entity.id == $instance_id and .entity.type == "linode")' <<<"${devices}" >/dev/null
jq -e --arg cidr "${runner_cidr}" --arg admin_port "${admin_port}" '
  [.inbound[]? | select(
    .action == "ACCEPT" and
    .protocol == "TCP" and
    ((.ports | gsub(" "; "") | split(",")) | any(. == "22" or . == $admin_port))
  )] as $admin_rules |
  ($admin_rules | length) == 2 and
  all($admin_rules[];
    .ipv4 == [$cidr] and
    ((.ipv6 // []) | length) == 0 and
    (.ports == "22" or .ports == $admin_port)
  )
' <<<"${rules}" >/dev/null

scanned_key="$(ssh-keyscan -T 10 -t ed25519 "${reserved_ip}" 2>/dev/null | awk 'NF >= 3 {print $2 " " $3}' | sort -u)"
[[ "${scanned_key}" =~ ^ssh-ed25519\ [A-Za-z0-9+/]+={0,3}$ ]] || { echo "host key scan was missing or ambiguous" >&2; exit 1; }

existing_key="$(aws ssm get-parameter --name "${host_key_parameter}" --query Parameter.Value --output text 2>/dev/null || true)"
if [[ -n "${existing_key}" && "${existing_key}" != "None" ]]; then
  [[ "${existing_key}" == "${scanned_key}" ]] || { echo "pinned SSH host key mismatch" >&2; exit 1; }
else
  aws ssm put-parameter --name "${host_key_parameter}" --type String --value "${scanned_key}" --no-overwrite >/dev/null
fi

umask 077
printf '%s %s\n' "${reserved_ip}" "${scanned_key}" > "${known_hosts_file}"
chmod 600 "${known_hosts_file}" "${private_key_file}"
ssh -i "${private_key_file}" -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
  -o "UserKnownHostsFile=${known_hosts_file}" -o ConnectTimeout=10 "${ssh_user}@${reserved_ip}" true
echo "SSH host key verified after control-plane resource checks."
