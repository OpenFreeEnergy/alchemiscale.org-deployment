#!/usr/bin/env bash
#
# Check that a deployment's conda environments agree on the alchemiscale
# version, and that each environment pins it at all.
#
# A version bump touches four files per deployment — server, client, compute,
# fah-compute — and nothing else notices if one is missed. The result is a
# client that cannot talk to its own server, discovered by a user rather than by
# CI. This is the check that catches it.
#
# Deployments without chart values (`root`, `asap`) are skipped: they are not
# deployed by this automation and may legitimately sit on older versions.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
status=0

for values in "${repo_root}"/deployments/*/values.yaml; do
  deployment="$(basename "$(dirname "${values}")")"
  envs_dir="$(dirname "${values}")/conda-envs"
  [ -d "${envs_dir}" ] || continue

  declare -A versions=()
  missing=()

  for env_file in "${envs_dir}"/*.yml; do
    # the alchemiscale package differs per environment (server/client/compute);
    # the version after it should not
    pin="$(grep -oE '^\s*-\s*alchemiscale-(server|client|compute)\s*=\s*[0-9][^ ]*' "${env_file}" || true)"
    if [ -z "${pin}" ]; then
      missing+=("$(basename "${env_file}")")
      continue
    fi
    version="${pin##*=}"
    versions["${version}"]+="$(basename "${env_file}") "
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    echo "error: ${deployment}: no pinned alchemiscale version in: ${missing[*]}" >&2
    status=1
  fi

  if [ "${#versions[@]}" -gt 1 ]; then
    echo "error: ${deployment}: conda environments disagree on the alchemiscale version —" >&2
    for v in "${!versions[@]}"; do
      echo "         ${v}: ${versions[$v]}" >&2
    done
    status=1
  elif [ "${#versions[@]}" -eq 1 ]; then
    for v in "${!versions[@]}"; do
      echo "${deployment}: alchemiscale ${v}"
    done
  fi

  unset versions
done

exit "${status}"
