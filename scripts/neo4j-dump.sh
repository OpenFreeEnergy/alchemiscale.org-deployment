#!/usr/bin/env bash
#
# Take a logical dump of a deployment's neo4j database and upload it to S3.
#
#   scripts/neo4j-dump.sh <deployment> [-b <bucket>] [-c prod|test] [-n <namespace>]
#   scripts/neo4j-dump.sh omsf
#   scripts/neo4j-dump.sh asap -b alchemiscale-backups-000000000000
#
# Logical dumps are the portable artifact: they survive neo4j version and
# storage-format changes, which block snapshots do not. This is the mechanism
# behind the EC2 -> EKS migration, the legacy `root` retirement archive, and any
# future version-crossing upgrade. For steady-state backup, the DLM policy takes
# daily EBS snapshots without any of this ceremony.
#
# The database must be offline for the duration, so this opens a maintenance
# window of a few minutes: neo4j is scaled to zero, the dump runs as a Job
# against the released volume, and neo4j is scaled back up. The APIs return
# errors while it is down.

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  sed -n '3,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-1}"
}

[ $# -ge 1 ] || usage
deployment="$1"
shift
[[ "${deployment}" == -* ]] && usage

cluster="prod"
namespace=""
bucket="${ALCHEMISCALE_BACKUPS_BUCKET:-}"
image=""

while getopts ":b:c:n:i:h" opt; do
  case "${opt}" in
    b) bucket="${OPTARG}" ;;
    c) cluster="${OPTARG}" ;;
    n) namespace="${OPTARG}" ;;
    i) image="${OPTARG}" ;;
    h) usage 0 ;;
    *) usage ;;
  esac
done

[ -n "${bucket}" ] || die "-b <bucket> (or ALCHEMISCALE_BACKUPS_BUCKET) is required"

namespace="${namespace:-${deployment}}"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
key="${deployment}/${stamp}.dump"
job="neo4j-dump-${stamp,,}"

use_cluster "${cluster}"
namespace_exists "${namespace}" || die "namespace ${namespace} does not exist"

# reuse the images the deployment is already running: neo4j for the dump, the
# server image for the upload (it carries boto3, and its ServiceAccount already
# has write access to this deployment's backups prefix)
neo4j_image="$(kubectl get statefulset "${NEO4J_STATEFULSET}" -n "${namespace}" \
  -o jsonpath='{.spec.template.spec.containers[0].image}')"
if [ -z "${image}" ]; then
  image="$(kubectl get deploy alchemiscale-client-api -n "${namespace}" \
    -o jsonpath='{.spec.template.spec.containers[0].image}')"
fi

cat <<EOF >&2

  deployment: ${deployment} (namespace ${namespace})
  destination: s3://${bucket}/${key}

neo4j will be offline for the duration of the dump.
EOF
read -r -p "continue? [y/N] " confirm
[[ "${confirm}" =~ ^[Yy]$ ]] || die "aborted"

scale_neo4j "${namespace}" 0

cleanup() {
  scale_neo4j "${namespace}" 1
}
trap cleanup EXIT

info "running dump job ${job}"
kubectl apply -n "${namespace}" -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job}
  labels:
    app.kubernetes.io/part-of: alchemiscale
    app.kubernetes.io/component: neo4j-dump
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      restartPolicy: Never
      serviceAccountName: alchemiscale
      securityContext:
        fsGroup: 7474
      initContainers:
        - name: dump
          image: ${neo4j_image}
          command:
            - neo4j-admin
            - database
            - dump
            - neo4j
            - --to-path=/dump
          volumeMounts:
            - name: data
              mountPath: /data
            - name: dump
              mountPath: /dump
      containers:
        - name: upload
          image: ${image}
          command:
            - /usr/local/bin/_entrypoint.sh
            - python
            - -u
            - -c
            - |
              import os
              import boto3

              source = "/dump/neo4j.dump"
              size = os.path.getsize(source)
              print(f"uploading {size} bytes to s3://{os.environ['BUCKET']}/{os.environ['KEY']}", flush=True)

              boto3.client("s3").upload_file(source, os.environ["BUCKET"], os.environ["KEY"])
              print("upload complete", flush=True)
          env:
            - name: BUCKET
              value: ${bucket}
            - name: KEY
              value: ${key}
            - name: AWS_DEFAULT_REGION
              value: ${AWS_REGION}
          volumeMounts:
            - name: dump
              mountPath: /dump
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: ${NEO4J_PVC}
        # scratch space for the dump before it is uploaded; if a database ever
        # outgrows the node's ephemeral storage, raise nodeClass.ephemeralStorage
        # in the cluster module
        - name: dump
          emptyDir: {}
EOF

if run_job "${namespace}" "${job}"; then
  info "dump complete: s3://${bucket}/${key}"
  kubectl delete job "${job}" -n "${namespace}" --ignore-not-found >/dev/null
else
  die "dump job failed; neo4j will be scaled back up, the job is left in place for inspection"
fi
