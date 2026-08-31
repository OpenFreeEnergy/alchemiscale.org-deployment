#!/usr/bin/env bash
#
# Register a user or compute identity on a deployment.
#
#   scripts/identity-add.sh <deployment> -t <user|compute> -i <identity> [-k <key>]
#   scripts/identity-add.sh omsf -t user -i alice            # key generated and printed
#   scripts/identity-add.sh omsf -t compute -i hpc-1 -k "$KEY"
#   scripts/identity-add.sh omsf -c test -n omsf-pr-42 -t user -i debug
#
# `alchemiscale identity add` talks to neo4j over bolt, and neo4j is never
# exposed outside its namespace — so identity administration always runs inside
# the cluster. This wraps the `kubectl exec` that does it.
#
# Note: the argument list of an exec appears in the EKS control-plane audit log,
# so a key passed with -k lands there. That is acceptable for an internal audit
# log, but generate keys randomly (which is what this script does when -k is
# omitted) rather than choosing memorable ones, and rotate by re-running this
# command if a key is mishandled.

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  sed -n '3,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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
key=""

while getopts ":c:n:t:i:k:h" opt; do
  case "${opt}" in
    c) cluster="${OPTARG}" ;;
    n) namespace="${OPTARG}" ;;
    t) identity_type="${OPTARG}" ;;
    i) identifier="${OPTARG}" ;;
    k) key="${OPTARG}" ;;
    h) usage 0 ;;
    *) usage ;;
  esac
done

[ -n "${identity_type}" ] || die "-t <user|compute> is required"
[ -n "${identifier}" ] || die "-i <identity> is required"

namespace="${namespace:-${deployment}}"

generated=false
if [ -z "${key}" ]; then
  require openssl
  key="$(openssl rand -base64 32)"
  generated=true
fi

use_cluster "${cluster}"
namespace_exists "${namespace}" || die "namespace ${namespace} does not exist"

info "adding ${identity_type} identity '${identifier}' to ${deployment} (namespace ${namespace})"
alchemiscale_exec "${namespace}" identity add -t "${identity_type}" -i "${identifier}" -k "${key}"

if [ "${generated}" = true ]; then
  cat <<EOF

identity: ${identifier}
key:      ${key}

This key is shown once and is not stored anywhere. Pass it to its owner over a
secure channel; if it is lost, re-run this command to set a new one.
EOF
fi
