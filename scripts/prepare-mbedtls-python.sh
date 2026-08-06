#!/usr/bin/env bash
set -euo pipefail

venv_dir="${1:?usage: prepare-mbedtls-python.sh <venv-directory>}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_dir="$(cd "${script_dir}/.." && pwd)"
source_dir="${repository_dir}/vendors/mbedtls"
python_bin="${PYTHON_BIN:-python3}"
stamp="${venv_dir}/.requirements.stamp"

if [[ -f "${stamp}" ]]; then
    printf '%s\n' "${venv_dir}/bin/python"
    exit 0
fi

rm -rf "${venv_dir}"
"${python_bin}" -m venv "${venv_dir}"
"${venv_dir}/bin/python" -m pip install --disable-pip-version-check \
    -r "${source_dir}/scripts/basic.requirements.txt" \
    -r "${source_dir}/tf-psa-crypto/scripts/basic.requirements.txt" >&2
touch "${stamp}"
printf '%s\n' "${venv_dir}/bin/python"
