#!/usr/bin/env bash
set -euo pipefail

target="${1:?usage: package-partout-vendors.sh <target> <partials-directory>}"
partials_dir="${2:?usage: package-partout-vendors.sh <target> <partials-directory>}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_dir="$(cd "${script_dir}/.." && pwd)"
work_dir="${repository_dir}/.build/package/${target}"
install_dir="${work_dir}/install"
manifests_dir="${work_dir}/manifests"
artifacts_dir="${repository_dir}/artifacts"

case "${target}" in
    android-arm64-v8a)
        vendors=(openssl mbedtls wg-go)
        extension=tar.gz
        ;;
    windows-x64|windows-arm64)
        vendors=(openssl mbedtls wg-go wintun)
        extension=zip
        ;;
    *)
        echo "Unknown aggregate target: ${target}" >&2
        exit 1
        ;;
esac

rm -rf "${work_dir}" "${artifacts_dir}"
mkdir -p "${install_dir}" "${manifests_dir}" "${artifacts_dir}"

for vendor in "${vendors[@]}"; do
    archive="${partials_dir}/partout-vendor-${vendor}-${target}.${extension}"
    if [[ ! -f "${archive}" ]]; then
        echo "Missing ${vendor} build output: ${archive}" >&2
        exit 1
    fi

    partial_dir="${work_dir}/partials/${vendor}"
    mkdir -p "${partial_dir}"
    if [[ "${extension}" == zip ]]; then
        unzip -q "${archive}" -d "${partial_dir}"
    else
        tar -xzf "${archive}" -C "${partial_dir}"
    fi

    [[ -d "${partial_dir}/${vendor}" ]] || {
        echo "${archive} does not contain the ${vendor} directory" >&2
        exit 1
    }
    [[ -f "${partial_dir}/manifest.json" ]] || {
        echo "${archive} does not contain manifest.json" >&2
        exit 1
    }
    jq -e --arg target "${target}" --arg vendor "${vendor}" \
        '.target == $target and .vendor == $vendor' \
        "${partial_dir}/manifest.json" >/dev/null || {
            echo "${archive} manifest does not match ${vendor} for ${target}" >&2
            exit 1
        }
    cp -R "${partial_dir}/${vendor}" "${install_dir}/${vendor}"
    cp "${partial_dir}/manifest.json" "${manifests_dir}/${vendor}.json"
done

jq -s '
    .[0] as $first
    | {
        schemaVersion: $first.schemaVersion,
        target: $first.target,
        os: $first.os,
        arch: $first.arch,
        prebuilts: $first.prebuilts,
        libraries: (map(.libraries) | add),
        toolchains: (
            reduce (map(.toolchains)[] | to_entries[]) as $entry
                ({}; if (($entry.value // "") | tostring | length) > 0
                     then .[$entry.key] = $entry.value
                     else .
                     end)
        )
    }
' "${manifests_dir}"/*.json > "${install_dir}/manifest.json"

package_name="partout-vendors-${target}.${extension}"
package_path="${artifacts_dir}/${package_name}"
if [[ "${extension}" == zip ]]; then
    (
        cd "${install_dir}"
        zip -qr "${package_path}" .
    )
else
    tar -czf "${package_path}" -C "${install_dir}" .
fi

sha256="$(shasum -a 256 "${package_path}" | awk '{print $1}')"
printf '%s  %s\n' "${sha256}" "${package_name}" > "${package_path}.sha256"
