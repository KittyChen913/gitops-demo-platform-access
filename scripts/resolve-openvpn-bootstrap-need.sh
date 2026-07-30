#!/usr/bin/env bash

# 判斷 targeted plan 是否顯示 OpenVPN Linode 需要建立或 replace，
# 藉此決定候選 Plan 是否帶入 Marketplace certbot 所需的 TCP/80。
# 對 module.openvpn.linode_instance.openvpn 做 -target plan 就能同時涵蓋
# 「resource 尚未存在」與「resource 需要 replace」兩種情況：
# 兩者在 targeted plan 裡都會落在 actions 包含 create。
# 完整 Apply Plan 仍會由 policy 禁止 replacement，只有 create 能實際暫開。
set -euo pipefail

readonly OPENVPN_INSTANCE_ADDRESS='module.openvpn.linode_instance.openvpn'

plan_json="${1:-}"

if [[ -z "${plan_json}" || ! -f "${plan_json}" || -L "${plan_json}" ]]; then
  echo "usage: resolve-openvpn-bootstrap-need.sh <targeted-plan.json>" >&2
  exit 2
fi

if ! jq -e '.format_version and ((.resource_changes // []) | type == "array")' "${plan_json}" >/dev/null; then
  echo "Terraform targeted plan JSON is missing required fields." >&2
  exit 1
fi

if jq -e --arg address "${OPENVPN_INSTANCE_ADDRESS}" '
  any((.resource_changes // [])[]?; .address == $address and ((.change.actions // []) | index("create") != null))
' "${plan_json}" >/dev/null; then
  echo true
else
  echo false
fi
