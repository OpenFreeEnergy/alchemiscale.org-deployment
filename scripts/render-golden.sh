#!/usr/bin/env bash
#
# Render every deployment's manifests to charts/alchemiscale/tests/__snapshots__/.
#
# CI re-runs this and diffs the result, so an unintended change to the chart
# shows up as a reviewable diff on the pull request that caused it — before any
# live deploy. Run it and commit the output whenever a chart or values change is
# intentional:
#
#   scripts/render-golden.sh
#
# Inputs are pinned (fixed digest, fixed generated secrets) so that the only
# thing that can move the output is a change to the chart or its values.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
chart="${repo_root}/charts/alchemiscale"
snapshots="${chart}/tests/__snapshots__"

# pinned so renders are reproducible
digest="sha256:0000000000000000000000000000000000000000000000000000000000000000"
tag="0.0.0-golden"

mkdir -p "${snapshots}"
rm -f "${snapshots}"/*.yaml

for values in "${repo_root}"/deployments/*/values.yaml; do
  deployment="$(basename "$(dirname "${values}")")"
  deployment_dir="$(dirname "${values}")"

  echo "rendering ${deployment} (production)"
  helm template "${deployment}" "${chart}" \
    --namespace "${deployment}" \
    --values "${values}" \
    --set image.tag="${tag}" \
    --set image.digest="${digest}" \
    > "${snapshots}/${deployment}.yaml"

  if [[ -f "${deployment_dir}/values-pr.yaml" ]]; then
    echo "rendering ${deployment} (pull request)"
    helm template "${deployment}-pr-0" "${chart}" \
      --namespace "${deployment}-pr-0" \
      --values "${values}" \
      --values "${deployment_dir}/values-pr.yaml" \
      --set image.tag="${tag}" \
      --set image.digest="${digest}" \
      --set s3.prefix="pr-0/${deployment}" \
      --set secrets.generate.neo4jPassword=golden-neo4j-password \
      --set secrets.generate.jwtSecretKey=golden-jwt-secret-key \
      > "${snapshots}/${deployment}-pr.yaml"
  fi
done

echo "snapshots written to ${snapshots}"
