#!/usr/bin/env bash
#
# Show compute manager registrations on a deployment, including the error a
# manager recorded when it went into the ERROR state.
#
#   scripts/compute-manager-status.sh <deployment> [-m <manager name>] [-c prod|test] [-n <namespace>]
#   scripts/compute-manager-status.sh omsf
#   scripts/compute-manager-status.sh omsf -m nrp.omsf
#
# The compute API has no endpoint for reading a registration back, and a
# manager that errored then crash-loops on registration, losing the logs of the
# run that failed. The registration's `detail` keeps the exception, so this
# reads it from neo4j directly.

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  sed -n '3,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-1}"
}

[ $# -ge 1 ] || usage
deployment="$1"
shift
[[ "${deployment}" == -* ]] && usage

cluster="prod"
namespace=""
manager=""

while getopts ":c:n:m:h" opt; do
  case "${opt}" in
    c) cluster="${OPTARG}" ;;
    n) namespace="${OPTARG}" ;;
    m) manager="${OPTARG}" ;;
    h) usage 0 ;;
    *) usage ;;
  esac
done

namespace="${namespace:-${deployment}}"

match="(cmr:ComputeManagerRegistration)"
if [ -n "${manager}" ]; then
  require_manager_name "${manager}"
  match="(cmr:ComputeManagerRegistration {name: '${manager}'})"
fi

use_cluster "${cluster}"
namespace_exists "${namespace}" || die "namespace ${namespace} does not exist"

info "compute manager registrations on ${deployment} (namespace ${namespace})"
cypher_exec "${namespace}" "
MATCH ${match}
RETURN cmr.name AS name, cmr.uuid AS uuid, cmr.status AS status,
       toString(cmr.registered) AS registered,
       toString(cmr.last_status_update) AS last_status_update,
       cmr.saturation AS saturation, cmr.detail AS detail
ORDER BY name;"
