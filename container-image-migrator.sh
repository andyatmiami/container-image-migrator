#! /usr/bin/env bash

set -euo pipefail

_usage()
{
	printf "%s\n" "Usage: $(basename "$0") -c <config file> [-x] [-h]"
}

function trap_exit() {
	rc=$?

    # unwind any pushd commands
    while popd >/dev/null 2>&1; do :; done

	set +x

	exit $rc
}

trap "trap_exit" EXIT

_check_dependency()
{
    local name="${1:-}"
    local url="${1:-}"

    if [ -z "$(which "${name}")" ]; then
        printf '%s\n%s\n' "'${name}' utility not found" "Please install appropriate distribution package from ${url} and re-run script."
        exit 1
    fi
}

_discover_container_engine()
{
    local possible_engine=
    possible_engine="$(which podman)"
    container_engine_auth_file="${HOME}/.config/containers/auth.json"
    if [ -z "${possible_engine}" ]; then
        possible_engine="$(which docker)"
        container_engine_auth_file="${HOME}/.docker/config.json"
    fi

    container_engine="${possible_engine}"

    if [ -z "${container_engine}" ]; then
        printf '%s\n%s\n' "Neither 'docker' nor 'podman' utility found" "Please install container engine of choice and re-run script."
        exit 1
    else
        printf '%s\n' "Using $(basename "${container_engine}") for container image migration."
    fi

    local auth_file_override=
    auth_file_override=$(jq '.container_engine_auth_file // empty' "${config_file}")
    if [ -n "${auth_file_override}" ]; then
        container_engine_auth_file="${auth_file_override}"
    fi
}

_verify_prereqs()
{
    _check_dependency "skopeo" "https://github.com/containers/skopeo/blob/main/install.md"
    _check_dependency "jq" "https://jqlang.org/download/"

    _discover_container_engine
}

_parse_opts()
{
	local OPTIND

	while getopts ':c:txh' OPTION; do
		case "${OPTION}" in
			c )
				config_file=$(readlink -f "${OPTARG}")
                if [ -z "${config_file}" ]; then
                    printf '%s: file not found\n' "${OPTARG}"
                    exit 1
                fi
                state_file="${config_file}.state"
				;;
			t)
				dry_run='t'
				;;
			x)
				set -x
				;;
			h)
				_usage
				exit
				;;
			* )
				_usage
				exit 1
				;;
		esac
	done


    if ! [ -e "${config_file}" ]; then
        printf '%s: file not found\n' "${config_file}"
        exit 1
    fi

    if ! jq 'empty' "${config_file}" &> /dev/null; then
        printf '%s: file cannot be parsed as JSON\n' "${config_file}"
        exit 1
    fi

    source_container_registry_host=$(jq -r '.container_registries.source.host // empty' "${config_file}")
    target_container_registry_host=$(jq -r '.container_registries.target.host // empty' "${config_file}")
}

_confirm_auth()
{
    printf '%s\n' "Checking ${container_engine_auth_file} to confirm appropriate authentication..."

    local source_container_registry_username=
    source_container_registry_username=$(jq -r '.container_registries.source.username // empty' "${config_file}")

    local target_container_registry_username=
    target_container_registry_username=$(jq -r '.container_registries.target.username // empty' "${config_file}")


    local source_container_registry_auth=
    source_container_registry_auth=$(jq -r --arg source_host "${source_container_registry_host}" '.auths[$source_host].auth // empty | @base64d' "${container_engine_auth_file}")
    if { [ -n "${source_container_registry_username}" ] && [ -z "${source_container_registry_auth}" ]; } \
        || { [ -n "${source_container_registry_username}" ] && [ "${source_container_registry_auth#"${source_container_registry_username}"}" = "$source_container_registry_auth" ]; } ; then

        printf '%s\n' "Enter your password for ${source_container_registry_username} on ${source_container_registry_host}:"
        read -rs password

        ${container_engine} login "${source_container_registry_host}" -u "${source_container_registry_username}" -p "${password}"
    fi

    local target_container_registry_auth=
    target_container_registry_auth=$(jq -r --arg target_host "${target_container_registry_host}" '.auths[$target_host].auth // empty | @base64d' "${container_engine_auth_file}")
    if { [ -n "${target_container_registry_username}" ] && [ -z "${target_container_registry_auth}" ]; } \
        || { [ -n "${target_container_registry_username}" ] && [ "${target_container_registry_auth#"${target_container_registry_username}"}" = "${target_container_registry_auth}" ]; } ; then

        printf '%s\n' "Enter your password for ${target_container_registry_username} on ${target_container_registry_host}:"
        read -rs password

        ${container_engine} login "${target_container_registry_host}" -u "${target_container_registry_username}" -p "${password}"
    fi
}

_initialize_state()
{
    if ! [ -e "${state_file}" ]; then
        printf '%s' '{"repos": {}}' > "${state_file}"
    fi
}

_cache_image_manifest()
{
    local image="${1:-}"
    local tag="${2:-}"

    local tag_url="${url}:${tag}"
    printf '%s\n' "Checking ${tag_url} for multi-arch references..."

    # 'skopeo inspect' is a rate-limited operation!
    local manifest_json=
    manifest_json=$(skopeo inspect --raw "${tag_url}")

    local manifest_media_type=
    manifest_media_type=$(jq -r '.mediaType' <<< "${manifest_json}")

    local platforms_json=
    case "${manifest_media_type}" in
        'application/vnd.oci.image.index.v1+json' | 'application/vnd.docker.distribution.manifest.list.v2+json')
            printf '%s\n' "${url} has a multi-arch manifest..."
            platforms_json=$(jq -rc '.manifests | map(select(.annotations["vnd.docker.reference.type"] == "attestation-manifest" | not) | (.platform.os + "/" + .platform.architecture))' <<< "${manifest_json}")
            ;;
        'application/vnd.docker.distribution.manifest.v2+json')
            printf '%s\n' "${url} has a simple manifest..."
            platforms_json='["*"]'
            ;;
        *)
            printf '%s\n' "Unrecognized manifest mediaType '${manifest_media_type}'... skipping"
            return
            ;;
    esac

    # Make sure we are tracking the mediaType and platforms in our state file (so we can reduce rate limit "hit" from script)
    jq --arg image "${image}" --arg tag "${tag}" --arg mediaType "${manifest_media_type}" --argjson platforms "${platforms_json}" \
        'if ( .repos[$image][$tag] | has("mediaType") ) | not then .repos[$image][($tag)] = {mediaType: $mediaType, platforms: ($platforms | map({key: ., value: {}}) | from_entries)} else . end' "${state_file}" \
    > "${temp_file}" && mv "${temp_file}" "${state_file}"

}

_discover_image_tags()
{
    # Single temp file used to store modifications to state file
    # Will need a more elegant solution if we need to look into parallelizing script execution
    local temp_file=
    temp_file=$(mktemp)

    for image in $(jq -r '.migration_plan | keys | join(" ")' "${config_file}"); do

        # Make sure we are tracking the repo in our state file
        jq --arg image "${image}" 'if ( .repos | has($image) ) | not then .repos[($image)] = {} else . end' "${state_file}" > "${temp_file}" && mv "${temp_file}" "${state_file}"

        local filter_array=
        filter_array=$(jq -rc --arg image "${image}" '.migration_plan[$image].tag_jq_filters // [".*"]' "${config_file}")

        local url="docker://${source_container_registry_host}/${image}"
        printf '%s\n' "Querying ${url} for tags matching filters '${filter_array}'..."
        local image_tags=
        image_tags=$(skopeo list-tags "${url}" | jq -r --argjson filters "${filter_array}" '.Tags | map(. as $tag | select(any($filters[]; . as $filter | $tag | test($filter)))) | join (" ")')

        for tag in ${image_tags}; do

            # Make sure we are tracking the image in our state file
            jq --arg image "${image}" --arg tag "${tag}" 'if ( .repos[$image] | has($tag) ) | not then .repos[$image][($tag)] = {} else . end' "${state_file}" > "${temp_file}" && mv "${temp_file}" "${state_file}"

            local cache_hit=
            cache_hit=$(jq -rc --arg image "${image}" --arg tag "${tag}" '.repos[$image][$tag].mediaType // empty' "${state_file}")

            if [ -z "${cache_hit}" ]; then
                _cache_image_manifest "${image}" "${tag}"
            fi
        done
    done

    rm -f "${temp_file}"

}


main()
{
    _verify_prereqs

    _parse_opts "$@"

    _confirm_auth

    _initialize_state

    _discover_image_tags
}

script_dir=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
config_file="${script_dir}/config.json"
state_file="${config_file}.state"

container_engine=
container_engine_auth_file=
dry_run=
source_container_registry_host=
target_container_registry_host=

if [[ "${BASH_SOURCE[0]}" = "${0}" ]]; then
    main "$@"
fi
