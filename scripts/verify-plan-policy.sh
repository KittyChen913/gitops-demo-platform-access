#!/usr/bin/env bash

# Apply Plan 只允許 create／update，Destroy Plan 只允許 delete；
# replacement 與 Terraform 未知 action 一律 fail closed。
set -euo pipefail

plan_json="${1:-}"
deployment="${2:-}"
operation="${3:-}"

if [[ -z "${plan_json}" || ! -f "${plan_json}" || -L "${plan_json}" ]]; then
  echo "usage: verify-plan-policy.sh <terraform-plan.json> <credential-bootstrap|base> <apply|destroy>" >&2
  exit 2
fi
case "${deployment}" in
  credential-bootstrap|base) ;;
  *) echo "The Terraform deployment is unsupported." >&2; exit 2 ;;
esac
case "${operation}" in
  apply|destroy) ;;
  *) echo "The Terraform plan operation is unsupported." >&2; exit 2 ;;
esac
if ! jq -e '
  .format_version and
  ((.resource_changes // []) | type == "array") and
  ((.resource_changes // []) | all(
    (.address | type) == "string" and
    (.change.actions | type) == "array"
  ))
' "${plan_json}" >/dev/null; then
  echo "Terraform plan JSON is missing required fields." >&2
  exit 1
fi

create_count="$(jq '[(.resource_changes // [])[] | select(.change.actions == ["create"])] | length' "${plan_json}")"
update_count="$(jq '[(.resource_changes // [])[] | select(.change.actions == ["update"])] | length' "${plan_json}")"
delete_count="$(jq '[(.resource_changes // [])[] | select(.change.actions == ["delete"])] | length' "${plan_json}")"
replace_count="$(jq '[(.resource_changes // [])[] | select((.change.actions | sort) == ["create", "delete"])] | length' "${plan_json}")"
unexpected_action_count="$(jq '[
  (.resource_changes // [])[] |
  select(
    .change.actions != ["no-op"] and
    .change.actions != ["create"] and
    .change.actions != ["update"] and
    .change.actions != ["delete"] and
    ((.change.actions | sort) != ["create", "delete"])
  )
] | length' "${plan_json}")"

printf 'Terraform resource actions: deployment=%s operation=%s create=%s update=%s delete=%s replace=%s unexpected=%s\n' \
  "${deployment}" "${operation}" "${create_count}" "${update_count}" "${delete_count}" "${replace_count}" "${unexpected_action_count}"

if [[ "${operation}" == "apply" ]]; then
  if ((delete_count != 0 || replace_count != 0 || unexpected_action_count != 0)); then
    echo "Apply plans may only create or update resources; delete and replacement are forbidden." >&2
    exit 1
  fi
else
  if ((create_count != 0 || update_count != 0 || replace_count != 0 || unexpected_action_count != 0)); then
    echo "Destroy plans may only delete resources; create, update and replacement are forbidden." >&2
    exit 1
  fi
fi

echo "Approved ${deployment} ${operation} plan accepted."
