#!/usr/bin/env bash
set -euo pipefail

assets_dir="${1:?usage: aggregate-manifests.sh <assets-dir> [output-path]}"
output_path="${2:-${assets_dir}/manifest.json}"

for command_name in basename cmp diff find jq sort tar unzip; do
    command -v "${command_name}" >/dev/null 2>&1 || {
        echo "Required command not found: ${command_name}" >&2
        exit 1
    }
done

[[ -d "${assets_dir}" ]] || {
    echo "Assets directory not found: ${assets_dir}" >&2
    exit 1
}

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT
entry_count=0

add_manifest() {
    local manifest_path="${1}"
    local artifact_name="${2}"
    local entry_path

    jq -e 'type == "object" and (.target | type == "string") and (.libraries | type == "object")' \
        "${manifest_path}" >/dev/null || {
        echo "Invalid package manifest: ${manifest_path}" >&2
        exit 1
    }

    entry_path="${work_dir}/entry-${entry_count}.json"
    jq --arg artifact "${artifact_name}" '
        .vendor = (.vendor // (.libraries | keys_unsorted[0]))
        | .artifact = $artifact
    ' "${manifest_path}" > "${entry_path}"
    entry_count=$((entry_count + 1))
}

while IFS= read -r -d '' manifest_path; do
    artifact_count="$(jq '[.libraries[]?.artifact? // empty] | length' "${manifest_path}")"
    if [[ "${artifact_count}" -eq 0 ]]; then
        echo "No artifacts found in standalone manifest: ${manifest_path}" >&2
        exit 1
    fi
    while IFS=$'\t' read -r vendor_name artifact_name; do
        package_manifest="${work_dir}/standalone-${entry_count}.json"
        jq --arg vendor "${vendor_name}" '
            .vendor = $vendor
            | .libraries = {($vendor): .libraries[$vendor]}
        ' "${manifest_path}" > "${package_manifest}"
        add_manifest "${package_manifest}" "${artifact_name}"
    done < <(
        jq -r '.libraries | to_entries[] | select(.value.artifact?) | [.key, .value.artifact] | @tsv' \
            "${manifest_path}"
    )
done < <(find "${assets_dir}" -type f -name '*-manifest.json' -print0 | sort -z)

while IFS= read -r -d '' package_path; do
    manifest_member=""
    if [[ "${package_path}" == *.tar.gz ]]; then
        while IFS= read -r member; do
            if [[ "${member##*/}" == manifest.json ]]; then
                manifest_member="${member}"
                break
            fi
        done < <(tar -tzf "${package_path}")
    else
        while IFS= read -r member; do
            if [[ "${member##*/}" == manifest.json ]]; then
                manifest_member="${member}"
                break
            fi
        done < <(unzip -Z1 "${package_path}")
    fi

    if [[ -z "${manifest_member}" ]]; then
        echo "Package manifest not found in ${package_path}" >&2
        exit 1
    fi

    extracted_manifest="${work_dir}/manifest-${entry_count}.json"
    if [[ "${package_path}" == *.tar.gz ]]; then
        tar -xOzf "${package_path}" "${manifest_member}" > "${extracted_manifest}"
    else
        unzip -p "${package_path}" "${manifest_member}" > "${extracted_manifest}"
    fi
    add_manifest "${extracted_manifest}" "$(basename "${package_path}")"
done < <(
    find "${assets_dir}" -type f \( -name '*.tar.gz' -o -name '*.zip' \) \
        ! -name '*.xcframework.zip' -print0 | sort -z
)

if [[ "${entry_count}" -eq 0 ]]; then
    echo "No package manifests found in ${assets_dir}" >&2
    exit 1
fi

mkdir -p "$(dirname "${output_path}")"
jq -s '
    sort_by(.artifact) as $packages
    | if ($packages | group_by(.artifact) | map(select(length > 1)) | length) > 0 then
        error("duplicate artifact metadata")
      else
        { schemaVersion: 1, packages: $packages }
      end
' "${work_dir}"/entry-*.json > "${work_dir}/manifest.json"

find "${assets_dir}" -type f \( -name '*.tar.gz' -o -name '*.zip' \) \
    -exec basename {} \; | sort > "${work_dir}/expected-artifacts.txt"
jq -r '.packages[].artifact' "${work_dir}/manifest.json" | sort > "${work_dir}/manifest-artifacts.txt"
if ! cmp -s "${work_dir}/expected-artifacts.txt" "${work_dir}/manifest-artifacts.txt"; then
    echo "Aggregated metadata does not match the release archives:" >&2
    diff -u "${work_dir}/expected-artifacts.txt" "${work_dir}/manifest-artifacts.txt" >&2 || true
    exit 1
fi

mv "${work_dir}/manifest.json" "${output_path}"

echo "Aggregated ${entry_count} package manifests into ${output_path}"
