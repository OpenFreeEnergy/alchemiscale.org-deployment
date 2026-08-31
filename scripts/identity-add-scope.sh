#!/usr/bin/env bash
#
# Grant scopes to an existing identity on a deployment.
#
#   scripts/identity-add-scope.sh <deployment> -t <user|compute> -i <identity> -s <org>-<campaign>-<project> [-s ...]
#   scripts/identity-add-scope.sh omsf -t user -i alice -s openfe-demo-project
#   scripts/identity-add-scope.sh omsf -c test -n omsf-pr-42 -t user -i debug -s '*-*-*'
#
# Repeated -s flags are passed through as the CLI accepts them.

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  sed -n '3,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-1}"
}

[ $# -ge 1 ] || usage
deployment="$1"
shift
[[ "${deployment}" == -* ]] && usage

cluster="prod"
namespace=""
identity_type=""
identifier=""
scopes=()

while getopts ":c:n:t:i:s:h" opt; do
  case "${opt}" in
    c) cluster="${OPTARG}" ;;
    n) namespace="${OPTARG}" ;;
    t) identity_type="${OPTARG}" ;;
    i) identifier="${OPTARG}" ;;
    s) scopes+=("${OPTARG}") ;;
    h) usage 0 ;;
    *) usage ;;
  esac
done

[ -n "${identity_type}" ] || die "-t <user|compute> is required"
[ -n "${identifier}" ] || die "-i <identity> is required"
[ ${#scopes[@]} -gt 0 ] || die "at least one -s <scope> is required"

namespace="${namespace:-${deployment}}"

scope_args=()
for scope in "${scopes[@]}"; do
  scope_args+=(-s "${scope}")
done

use_cluster "${cluster}"
namespace_exists "${namespace}" || die "namespace ${namespace} does not exist"

info "granting ${scopes[*]} to ${identity_type} identity '${identifier}' on ${deployment}"
alchemiscale_exec "${namespace}" identity add-scope -t "${identity_type}" -i "${identifier}" "${scope_args[@]}"
