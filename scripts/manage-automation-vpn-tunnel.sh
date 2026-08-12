#!/usr/bin/env bash

# 這個 adapter 只處理 runner-local OpenVPN process 與精確的 split-tunnel
# host routes；Cloud、Firewall 與 Access Server desired state 不在此修改。
set -euo pipefail

mode="${1:-}"
state_directory="${2:-}"

[[ "${mode}" == "open" || "${mode}" == "close" ]] || {
  echo "mode must be open or close" >&2
  exit 2
}
[[ -n "${RUNNER_TEMP:-}" && -n "${state_directory}" ]] || {
  echo "RUNNER_TEMP and state directory are required" >&2
  exit 2
}

runner_temp_real="$(realpath -m -- "${RUNNER_TEMP}")"
state_directory_real="$(realpath -m -- "${state_directory}")"
case "${state_directory_real}" in
  "${runner_temp_real}"/automation-vpn-*) ;;
  *)
    echo "state directory is outside the approved runner temporary scope" >&2
    exit 2
    ;;
esac

close_tunnel() {
  local pid=""

  if [[ -f "${state_directory_real}/openvpn.pid" ]]; then
    pid="$(sudo cat "${state_directory_real}/openvpn.pid" 2>/dev/null || true)"
  fi
  if [[ "${pid}" =~ ^[1-9][0-9]*$ ]] &&
    [[ -r "/proc/${pid}/comm" ]] &&
    [[ "$(<"/proc/${pid}/comm")" == "openvpn" ]]; then
    sudo kill -TERM "${pid}"
    for _ in {1..20}; do
      [[ ! -d "/proc/${pid}" ]] && break
      sleep 1
    done
    if [[ -d "/proc/${pid}" ]]; then
      sudo kill -KILL "${pid}"
    fi
  fi

  sudo rm -rf -- "${state_directory_real}"
}

if [[ "${mode}" == "close" ]]; then
  close_tunnel
  echo "Automation VPN tunnel closed."
  exit 0
fi

cleanup_on_error() {
  local exit_code=$?
  trap - EXIT
  # close_tunnel 會把 state_directory_real 整個砍掉，openvpn.log 會跟著消失，
  # 之後完全看不出握手失敗的真正原因（只看得到 workflow 印出的逾時訊息）。
  # 在砍之前先把它印到 stderr，讓失敗原因留在 CI log 裡。
  if [[ -f "${state_directory_real}/openvpn.log" ]]; then
    echo "----- openvpn.log (dumped before cleanup) -----" >&2
    sudo cat "${state_directory_real}/openvpn.log" >&2 || true
    echo "----- end openvpn.log -----" >&2
  fi
  close_tunnel
  exit "${exit_code}"
}
trap cleanup_on_error EXIT

identity="${AUTOMATION_VPN_IDENTITY:-}"
profile_path="${VPN_PROFILE_PATH:-}"
password_path="${VPN_PASSWORD_PATH:-}"
expected_tunnel_ip="${VPN_EXPECTED_TUNNEL_IP:-}"
route_targets="${VPN_ROUTE_TARGETS:-}"
health_targets="${VPN_HEALTH_TARGETS:-}"

[[ "${identity}" =~ ^ci-(cluster|argocd|user-provisioning)$ ]] || {
  echo "invalid automation VPN identity" >&2
  exit 2
}
if [[ -n "${expected_tunnel_ip}" ]] &&
  [[ ! "${expected_tunnel_ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "invalid expected tunnel IPv4 address" >&2
  exit 2
fi
for required_file in "${profile_path}" "${password_path}"; do
  [[ -f "${required_file}" && ! -L "${required_file}" ]] || {
    echo "automation VPN credential file is missing" >&2
    exit 2
  }
done
[[ -n "${route_targets//[[:space:]]/}" ]] || {
  echo "at least one split-tunnel route target is required" >&2
  exit 2
}
[[ -n "${health_targets//[[:space:]]/}" ]] || {
  echo "at least one tunnel health target is required" >&2
  exit 2
}

if grep -Eiq '^[[:space:]]*(script-security|up|down|route-up|plugin)[[:space:]]' "${profile_path}"; then
  echo "automation VPN profile contains a prohibited local execution directive" >&2
  exit 1
fi

mkdir -p "${state_directory_real}"
chmod 700 "${state_directory_real}"
auth_file="${state_directory_real}/auth"
routes_file="${state_directory_real}/routes"
default_interface_file="${state_directory_real}/default-interface"
umask 077
{
  printf '%s\n' "${identity}"
  cat "${password_path}"
  printf '\n'
} > "${auth_file}"

default_interface="$(
  ip -4 route show default |
    awk 'NR == 1 {for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}'
)"
[[ -n "${default_interface}" ]] || {
  echo "unable to resolve the runner default interface" >&2
  exit 1
}
printf '%s\n' "${default_interface}" > "${default_interface_file}"

: > "${routes_file}"
while IFS= read -r raw_target; do
  target="${raw_target#"${raw_target%%[![:space:]]*}"}"
  target="${target%"${target##*[![:space:]]}"}"
  [[ -n "${target}" ]] || continue
  target="${target#*://}"
  target="${target%%/*}"
  target="${target%%:*}"
  [[ "${target}" =~ ^[A-Za-z0-9.-]+$ ]] || {
    echo "invalid split-tunnel route target" >&2
    exit 2
  }

  if [[ "${target}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    printf '%s\n' "${target}" >> "${routes_file}"
  else
    getent ahostsv4 "${target}" |
      awk '{print $1}' |
      sort -u >> "${routes_file}"
  fi
done <<< "${route_targets}"
sort -u -o "${routes_file}" "${routes_file}"
[[ -s "${routes_file}" ]] || {
  echo "split-tunnel targets did not resolve to IPv4 addresses" >&2
  exit 1
}

openvpn_arguments=(
  --config "${profile_path}"
  --auth-user-pass "${auth_file}"
  --auth-nocache
  --route-nopull
  --persist-key
  --persist-tun
  --writepid "${state_directory_real}/openvpn.pid"
  --log "${state_directory_real}/openvpn.log"
  --daemon "automation-vpn-${identity}"
)
while IFS= read -r route_ip; do
  openvpn_arguments+=(--route "${route_ip}" 255.255.255.255)
done < "${routes_file}"

sudo openvpn "${openvpn_arguments[@]}"

ready=""
for _ in {1..60}; do
  pid="$(sudo cat "${state_directory_real}/openvpn.pid" 2>/dev/null || true)"
  if [[ "${pid}" =~ ^[1-9][0-9]*$ ]] &&
    sudo grep -q "Initialization Sequence Completed" "${state_directory_real}/openvpn.log" 2>/dev/null; then
    ready=1
    break
  fi
  sleep 2
done
[[ -n "${ready}" ]] || {
  echo "automation VPN tunnel did not become ready before timeout" >&2
  exit 1
}

tunnel_interface=""
while IFS= read -r route_ip; do
  route="$(ip -4 route get "${route_ip}")"
  route_interface="$(
    awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}' <<< "${route}"
  )"
  [[ -n "${route_interface}" && "${route_interface}" != "${default_interface}" ]] || {
    echo "split-tunnel route did not use the VPN interface" >&2
    exit 1
  }
  tunnel_interface="${tunnel_interface:-${route_interface}}"
done < "${routes_file}"
printf '%s\n' "${tunnel_interface}" > "${state_directory_real}/tunnel-interface"

if [[ -n "${expected_tunnel_ip}" ]]; then
  actual_tunnel_ip="$(
    ip -4 -o address show dev "${tunnel_interface}" |
      awk 'NR == 1 {sub(/\/.*/, "", $4); print $4}'
  )"
  [[ "${actual_tunnel_ip}" == "${expected_tunnel_ip}" ]] || {
    echo "automation VPN tunnel did not receive the expected static IPv4 address" >&2
    exit 1
  }
fi

while IFS= read -r health_target; do
  health_target="${health_target#"${health_target%%[![:space:]]*}"}"
  health_target="${health_target%"${health_target##*[![:space:]]}"}"
  [[ -n "${health_target}" ]] || continue
  health_host="${health_target%:*}"
  health_port="${health_target##*:}"
  [[ "${health_host}" =~ ^[A-Za-z0-9.-]+$ ]] || {
    echo "invalid tunnel health host" >&2
    exit 2
  }
  if [[ ! "${health_port}" =~ ^[1-9][0-9]{0,4}$ ]] ||
    ((10#"${health_port}" > 65535)); then
    echo "invalid tunnel health port" >&2
    exit 2
  fi
  timeout 10 bash -c "exec 3<>\"/dev/tcp/\$1/\$2\"" _ "${health_host}" "${health_port}" || {
    echo "automation VPN tunnel target is unreachable" >&2
    exit 1
  }
done <<< "${health_targets}"

trap - EXIT
echo "Automation VPN tunnel opened with isolated host routes."
