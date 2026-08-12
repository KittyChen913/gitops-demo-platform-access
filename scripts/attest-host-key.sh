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
ssh_ready_timeout_seconds=600
control_plane_verify_attempts=6
control_plane_verify_retry_seconds=5

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
[[ "${host_key_parameter}" == /gitops/openvpn-dns/* && -f "${private_key_file}" ]] || { echo "invalid host-key or SSH credential contract" >&2; exit 2; }
[[ -n "${LINODE_TOKEN:-}" && -n "${ssh_user}" && -n "${expected_label}" ]] || { echo "runtime credentials and identity inputs are required" >&2; exit 2; }
if [[ ! "${admin_port}" =~ ^[1-9][0-9]{0,4}$ ]] || ((10#${admin_port} > 65535)); then
  echo "invalid OpenVPN Admin port" >&2
  exit 2
fi

api_get() {
  printf 'header = "Authorization: Bearer %s"\n' "${LINODE_TOKEN}" |
    curl --config - --fail --silent --show-error --proto '=https' --tlsv1.2 \
      --connect-timeout 10 --max-time 30 --retry 3 \
      -H 'Accept: application/json' "https://api.linode.com/v4$1"
}

instance_identity_matches=false
reserved_ip_attachment_matches=false
firewall_enabled=false
firewall_attached=false
temporary_rules_match=false
control_plane_verified=false

for ((attempt = 1; attempt <= control_plane_verify_attempts; attempt++)); do
  instance="$(api_get "/linode/instances/${instance_id}")"
  ip_record="$(api_get "/networking/ips/${reserved_ip}")"
  firewall="$(api_get "/networking/firewalls/${firewall_id}")"
  devices="$(api_get "/networking/firewalls/${firewall_id}/devices")"
  rules="$(api_get "/networking/firewalls/${firewall_id}/rules")"

  instance_identity_matches="$(jq -r --arg label "${expected_label}" --arg ip "${reserved_ip}" \
    '.status == "running" and .label == $label and any(.ipv4[]?; . == $ip)' \
    <<<"${instance}")"
  reserved_ip_attachment_matches="$(jq -r --arg ip "${reserved_ip}" \
    --argjson instance_id "${instance_id}" \
    '.address == $ip and .public == true and .linode_id == $instance_id' \
    <<<"${ip_record}")"
  firewall_enabled="$(jq -r '.status == "enabled"' <<<"${firewall}")"
  firewall_attached="$(jq -r --argjson instance_id "${instance_id}" \
    'any(.data[]?; .entity.id == $instance_id and .entity.type == "linode")' \
    <<<"${devices}")"
  temporary_rules_match="$(jq -r --arg cidr "${runner_cidr}" --arg admin_port "${admin_port}" '
    [.inbound[]? | select(
      .action == "ACCEPT" and
      (.protocol | ascii_upcase) == "TCP" and
      ((.ports | gsub(" "; "") | split(",")) | any(. == "22" or . == $admin_port))
    )] as $admin_rules |
    ($admin_rules | length) == 2 and
    all($admin_rules[];
      .addresses.ipv4 == [$cidr] and
      ((.addresses.ipv6 // []) | length) == 0 and
      (.ports == "22" or .ports == $admin_port)
    )
  ' <<<"${rules}")"

  if [[ "${instance_identity_matches}" == "true" &&
        "${reserved_ip_attachment_matches}" == "true" &&
        "${firewall_enabled}" == "true" &&
        "${firewall_attached}" == "true" &&
        "${temporary_rules_match}" == "true" ]]; then
    control_plane_verified=true
    break
  fi

  if ((attempt < control_plane_verify_attempts)); then
    echo "Waiting for Linode control-plane attestation (${attempt}/${control_plane_verify_attempts})."
    sleep "${control_plane_verify_retry_seconds}"
  fi
done

if [[ "${control_plane_verified}" != "true" ]]; then
  echo "::group::Linode control-plane attestation diagnostics"
  echo "instance_identity_matches=${instance_identity_matches}"
  echo "reserved_ip_attachment_matches=${reserved_ip_attachment_matches}"
  echo "firewall_enabled=${firewall_enabled}"
  echo "firewall_attached=${firewall_attached}"
  echo "temporary_rules_match=${temporary_rules_match}"
  echo "::endgroup::"
  echo "Linode control-plane attestation failed." >&2
  exit 1
fi

ssh_ready_deadline=$((SECONDS + ssh_ready_timeout_seconds))
scanned_key=""
keyscan_attempt=0
while ((SECONDS < ssh_ready_deadline)); do
  keyscan_attempt=$((keyscan_attempt + 1))
  if ! scanned_key="$(ssh-keyscan -T 10 -t ed25519 "${reserved_ip}" 2>/dev/null |
    awk 'NF >= 3 {print $2 " " $3}' |
    sort -u)"; then
    scanned_key=""
  fi
  if [[ "${scanned_key}" =~ ^ssh-ed25519\ [A-Za-z0-9+/]+={0,3}$ ]]; then
    break
  fi
  remaining=$((ssh_ready_deadline - SECONDS))
  if ((remaining <= 0)); then
    break
  fi
  echo "等待 SSH host key 可被掃描（第 ${keyscan_attempt} 次；剩餘約 ${remaining} 秒）..."
  sleep 10
done
[[ "${scanned_key}" =~ ^ssh-ed25519\ [A-Za-z0-9+/]+={0,3}$ ]] || { echo "host key scan did not become ready before timeout" >&2; exit 1; }

existing_key="$(aws ssm get-parameter --name "${host_key_parameter}" --query Parameter.Value --output text 2>/dev/null || true)"
if [[ -n "${existing_key}" && "${existing_key}" != "None" ]]; then
  [[ "${existing_key}" == "${scanned_key}" ]] || { echo "pinned SSH host key mismatch" >&2; exit 1; }
else
  aws ssm put-parameter --name "${host_key_parameter}" --type String --value "${scanned_key}" --no-overwrite >/dev/null
fi

umask 077
printf '%s %s\n' "${reserved_ip}" "${scanned_key}" > "${known_hosts_file}"
chmod 600 "${known_hosts_file}" "${private_key_file}"
ssh_attempt=0
while ! ssh -i "${private_key_file}" -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
  -o "UserKnownHostsFile=${known_hosts_file}" -o ConnectTimeout=10 "${ssh_user}@${reserved_ip}" true 2>/dev/null; do
  ssh_attempt=$((ssh_attempt + 1))
  if ((SECONDS >= ssh_ready_deadline)); then
    echo "strict-pinned SSH did not become ready before timeout" >&2
    exit 1
  fi
  echo "等待 strict host-key-pinned SSH 可接受連線（第 ${ssh_attempt} 次；剩餘約 $((ssh_ready_deadline - SECONDS)) 秒）..."
  sleep 10
done
echo "SSH host key verified after control-plane resource checks."
