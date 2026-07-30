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
access_scope="${7:-ssh-admin}"

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

rules_match_file() {
  local expected_file="$1"
  local actual_rules
  local expected_rules

  actual_rules="$(api_get "/networking/firewalls/${firewall_id}/rules")"
  expected_rules="$(jq -S -c '{inbound, inbound_policy, outbound, outbound_policy}' "${expected_file}")"
  [[ "$(jq -S -c '{inbound, inbound_policy, outbound, outbound_policy}' <<<"${actual_rules}")" == "${expected_rules}" ]]
}

wait_for_rules_file() {
  local expected_file="$1"
  local deadline=$((SECONDS + 120))

  while ((SECONDS < deadline)); do
    if rules_match_file "${expected_file}"; then
      return 0
    fi
    sleep 5
  done
  return 1
}

wait_for_no_temporary_runner_access() {
  local deadline=$((SECONDS + 120))
  local attempt=0
  local matching_rule_count
  local rules

  while ((SECONDS < deadline)); do
    attempt=$((attempt + 1))
    rules="$(api_get "/networking/firewalls/${firewall_id}/rules")"
    if ! matching_rule_count="$(jq -er '
      [.inbound[]? | select(
        (.label == "temporary-runner-ssh" or .label == "temporary-runner-admin") and
        .action == "ACCEPT" and
        (.protocol | ascii_upcase) == "TCP"
      )] | length
    ' <<<"${rules}")"; then
      echo "unable to evaluate existing temporary-runner-* Firewall access" >&2
      return 2
    fi
    if ((matching_rule_count == 0)); then
      return 0
    fi
    echo "等待既有 temporary-runner-* Firewall access 收斂（第 ${attempt} 次；剩餘約 $((deadline - SECONDS)) 秒）..."
    sleep 5
  done
  return 1
}

if [[ "${mode}" == open ]]; then
  if [[ ! "${admin_port}" =~ ^[1-9][0-9]{0,4}$ ]] || ((10#${admin_port} > 65535)); then
    echo "invalid OpenVPN Admin port" >&2
    exit 2
  fi
  case "${access_scope}" in
    ssh-admin|admin-only) ;;
    *)
      echo "access scope must be ssh-admin or admin-only" >&2
      exit 2
      ;;
  esac
  firewall="$(api_get "/networking/firewalls/${firewall_id}")"
  devices="$(api_get "/networking/firewalls/${firewall_id}/devices")"
  jq -e '.status == "enabled"' <<<"${firewall}" >/dev/null
  jq -e --argjson instance_id "${instance_id}" '.data | any(.entity.id == $instance_id and .entity.type == "linode")' <<<"${devices}" >/dev/null
  if ! wait_for_no_temporary_runner_access; then
    echo "unexpected pre-existing temporary-runner-* firewall access remained after timeout" >&2
    exit 1
  fi
  umask 077
  rules="$(api_get "/networking/firewalls/${firewall_id}/rules")"
  jq '{inbound, inbound_policy, outbound, outbound_policy}' <<<"${rules}" > "${backup_file}"
  updated="${backup_file}.updated"
  if [[ "${access_scope}" == "ssh-admin" ]]; then
    jq --arg cidr "${runner_cidr}" --arg admin_port "${admin_port}" '.inbound += [
      {label:"temporary-runner-ssh",action:"ACCEPT",protocol:"TCP",ports:"22",addresses:{ipv4:[$cidr],ipv6:[]}},
      {label:"temporary-runner-admin",action:"ACCEPT",protocol:"TCP",ports:$admin_port,addresses:{ipv4:[$cidr],ipv6:[]}}
    ]' "${backup_file}" > "${updated}"
    expected_rule_count=2
  else
    jq --arg cidr "${runner_cidr}" --arg admin_port "${admin_port}" '.inbound += [
      {label:"temporary-runner-admin",action:"ACCEPT",protocol:"TCP",ports:$admin_port,addresses:{ipv4:[$cidr],ipv6:[]}}
    ]' "${backup_file}" > "${updated}"
    expected_rule_count=1
  fi
  restore_on_error() {
    local exit_code=$?

    trap - EXIT
    rm -f "${updated}"
    if ! api_put_rules "${backup_file}" || ! wait_for_rules_file "${backup_file}"; then
      echo "failed to restore the Firewall baseline after opening runner access failed" >&2
    fi
    exit "${exit_code}"
  }
  trap restore_on_error EXIT
  api_put_rules "${updated}"
  rm -f "${updated}"

  rules_ready_deadline=$((SECONDS + 120))
  rules_ready=""
  while ((SECONDS < rules_ready_deadline)); do
    rules="$(api_get "/networking/firewalls/${firewall_id}/rules")"
    if jq -e \
      --arg cidr "${runner_cidr}" \
      --arg admin_port "${admin_port}" \
      --arg access_scope "${access_scope}" \
      --argjson expected_rule_count "${expected_rule_count}" '
      [.inbound[]? | select(
        (.label == "temporary-runner-ssh" or .label == "temporary-runner-admin") and
        .action == "ACCEPT" and
        (.protocol | ascii_upcase) == "TCP"
      )] as $temporary_rules |
      ($temporary_rules | length) == $expected_rule_count and
      (
        $access_scope == "admin-only" or
        any($temporary_rules[];
          .label == "temporary-runner-ssh" and
          .ports == "22" and
          .addresses.ipv4 == [$cidr] and
          ((.addresses.ipv6 // []) | length) == 0
        )
      ) and
      any($temporary_rules[];
        .label == "temporary-runner-admin" and
        .ports == $admin_port and
        .addresses.ipv4 == [$cidr] and
        ((.addresses.ipv6 // []) | length) == 0
      )
    ' <<<"${rules}" >/dev/null; then
      rules_ready=1
      break
    fi
    sleep 5
  done
  [[ -n "${rules_ready}" ]] || {
    echo "temporary runner /32 Firewall rules did not become readable before timeout" >&2
    exit 1
  }
  trap - EXIT
  echo "Temporary runner /32 ${access_scope} access opened after identity checks."
else
  [[ -f "${backup_file}" && ! -L "${backup_file}" ]] || { echo "firewall cleanup backup is missing" >&2; exit 1; }
  api_put_rules "${backup_file}"
  if ! wait_for_rules_file "${backup_file}"; then
    echo "runner /32 cleanup did not restore the exact Firewall baseline before timeout" >&2
    exit 1
  fi
  rm -f "${backup_file}"
  echo "Temporary runner /32 access removed."
fi
