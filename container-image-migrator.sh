#! /usr/bin/env bash

set -uo pipefail

_usage()
{
	printf "%s\n" "Usage: $(basename "$0") -c <config file> [-t] [-x] [-h]"
}

function trap_exit() {
	rc=$?

    # ensure any logging output flushed
    sync

    # unwind any pushd commands
    while popd >/dev/null 2>&1; do :; done

    rm -f "${auth_file}"

	set +x

	exit $rc
}

trap "trap_exit" EXIT

_fail()
{
    local msg="${1:-}"

    printf '\n%s\n\n' "${msg}" >&2
    exit 1
}

_set_script_dir()
{
    if [ -n "${BASH_VERSION}" ]; then
        script_dir=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
    elif [ -n "${ZSH_VERSION}" ]; then
        # Zsh specific: Use $0 for the script path
        script_dir=$( cd -- "$( dirname -- "${0}" )" &> /dev/null && pwd )
    else
        # For other shells, assume $0 is the path
        printf '%s\n' "**WARNNING** Detected shell '${SHELL}' is not supported.  Consider using 'bash' or 'zsh'..." >&2
        script_dir=$( cd -- "$( dirname -- "${0}" )" &> /dev/null && pwd )
    fi
}

_do_invoke()
{
    if { [ -n "${ZSH_VERSION:-}" ] && [ "${0}" != "${ZSH_EVAL_CONTEXT:-}" ]; } || { [ -n "${BASH_VERSION:-}" ] && [ "${BASH_SOURCE:-}" != "${0}" ]; }; then
        return 1
    fi

}

_check_dependency()
{
    local name="${1:-}"
    local url="${1:-}"

    local binary=
    set +e
    binary=$(which "${name}")
    set -e

    if [ -z "${binary}" ]; then
        _fail "'${name}' utility not found... Please install appropriate distribution package from ${url} and re-run script."
    fi
}

_verify_prereqs()
{
    _check_dependency "skopeo" "https://github.com/containers/skopeo/blob/main/install.md"
    _check_dependency "jq" "https://jqlang.org/download/"
}

_parse_opts()
{
	local OPTIND

	while getopts ':c:txh' OPTION; do
		case "${OPTION}" in
			c )
				config_file=$(readlink -f "${OPTARG}")
                if [ -z "${config_file}" ]; then
                    _fail "file not found: '${OPTARG}'"
                fi
                state_file="${config_file}.state"
                auth_file="${config_file}.auth"
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
        _fail "file not found: '${config_file}'"
    fi

    if ! jq 'empty' "${config_file}" &> /dev/null; then
        _fail "file cannot be parsed as JSON: '${config_file}'"
    fi

    source_container_registry_host=$(jq -r '.container_registries.source.host // empty' "${config_file}")
    target_container_registry_host=$(jq -r '.container_registries.target.host // empty' "${config_file}")
}

_initialize_state()
{
    printf "{}" > "${auth_file}"

    if ! [ -e "${state_file}" ]; then
        printf '%s' '{"repos": {}}' > "${state_file}"
    fi
}

_login()
{
    local host="${1:-}"
    local username="${2:-}"
    local password_from_env="${3:-}"

    if [ -n "${username}" ]; then

        local rc=
        set +e
        local authenticated_user=
        authenticated_user=$(skopeo login --compat-auth-file "${auth_file}" "${host}" --get-login 2> /dev/null)
        rc="$?"
        set -e

        if [ "${rc}" -ne 0 ] || [ "${authenticated_user}" != "username" ]; then
            local password="${password_from_env}"

            if [ -z "${password_from_env}" ]; then
                printf '%s\n' "Enter your password for ${username} on ${host}:"
                read -rs password
            fi

            skopeo login --compat-auth-file "${auth_file}" -u "${username}" -p "${password}" "${host}"
        fi
    fi
}

_confirm_auth()
{
    printf '%s\n' "Checkingto confirm appropriate authentication..."

    local source_container_registry_username=
    source_container_registry_username=$(jq -r '.container_registries.source.username // empty' "${config_file}")

    local target_container_registry_username=
    target_container_registry_username=$(jq -r '.container_registries.target.username // empty' "${config_file}")

    _login "${source_container_registry_host}" "${source_container_registry_username}" "${SOURCE_CONTAINER_REGISTRY_PASSWORD:-}"
    _login "${target_container_registry_host}" "${target_container_registry_username}" "${TARGET_CONTAINER_REGISTRY_PASSWORD:-}"
}

_get_image_url()
{
    local host="${1:-}"
    local image="${2:-}"
    local tag="${3:-}"

    printf '%s' "docker://${host}/${image}${tag:+":$tag"}"
}

_cache_image_manifest()
{
    local image="${1:-}"
    local tag="${2:-}"

    local url="docker://${source_container_registry_host}/${image}:${tag}"
    printf '%s\n' "Checking ${url} for multi-arch references..."

    # 'skopeo inspect' is a rate-limited operation!
    local manifest_json=
    manifest_json=$(skopeo inspect --authfile "${auth_file}" --retry-times "${skopeo_retries}" --raw "${url}")

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
            platforms_json='[]'
            ;;
        *)
            printf '%s\n' "Unrecognized manifest mediaType '${manifest_media_type}'... skipping"
            return
            ;;
    esac

    # Single temp file used to store modifications to state file
    # Will need a more elegant solution if we need to look into parallelizing script execution
    local temp_file=
    temp_file=$(mktemp)

    # Make sure we are tracking the mediaType and platforms in our state file (so we can reduce rate limit "hit" from script)
    jq --arg image "${image}" --arg tag "${tag}" --arg mediaType "${manifest_media_type}" --argjson platforms "${platforms_json}" \
        'if ( .repos[$image][$tag] | has("mediaType") ) | not then .repos[$image][($tag)] = {mediaType: $mediaType, platforms: $platforms} else . end' "${state_file}" \
    > "${temp_file}" && mv "${temp_file}" "${state_file}"

    rm -f "${temp_file}"

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
        image_tags=$(skopeo list-tags --authfile "${auth_file}" --retry-times "${skopeo_retries}" "${url}" | jq -r --argjson filters "${filter_array}" '.Tags | map(. as $tag | select(any($filters[]; . as $filter | $tag | test($filter)))) | join (" ")')

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

_update_image_migration_status()
{
    local repo="${1:-}"
    local tag="${2:-}"
    local status="${3:-unknown}"

    local temp_file=
    temp_file=$(mktemp)

    if [ "${dry_run}" != 't' ]; then
        jq --arg repo "${repo}" --arg tag "${tag}" --arg status "${status}" '.repos[($repo)][($tag)].status = $status' "${state_file}" > "${temp_file}" && mv "${temp_file}" "${state_file}"
    fi

    rm -f "${temp_file}"
}

_copy_images()
{
    local remaining_work_json=
    remaining_work_json=$(jq -rc '.repos | to_entries | map(.key as $repo | .value | to_entries | map(select(.value.status != "complete") | {repo: $repo, tag: .key, platforms: .value.platforms}) | flatten[])' "${state_file}")
    num_remaining=$( jq -r 'length' <<< "${remaining_work_json}")

    printf '%s\n' "Count of unmigrated images: ${num_remaining}"

    # Use jq to extract the array and iterate over each object in the array
    jq -c '.[]' <<< "${remaining_work_json}" | while read -r obj; do
        local source_repo=
        source_repo=$(jq -r '.repo' <<< "${obj}")

        local tag=
        tag=$(jq -r '.tag' <<< "${obj}")

        local platforms_json=
        platforms_json=$(jq -r '.platforms' <<< "${obj}")
        local multi_arch=
        if [ "$(jq -r 'length' <<< "${platforms_json}")" -gt 0 ]; then
            multi_arch='all'
        fi

        local source_image_url=
        source_image_url="$(_get_image_url "${source_container_registry_host}" "${source_repo}" "${tag}")"

        local target_repo=
        target_repo=$(jq -r --arg source_repo "${source_repo}" '.migration_plan[$source_repo].target_repo // $source_repo' "${config_file}")

        local target_image_url=
        target_image_url="$(_get_image_url "${target_container_registry_host}" "${target_repo}" "${tag}")"

        local inspect_results=
        local rc=
        # Don't wait to exit on error here as we wanna do some post-processing based on outcome
        set +e
        # Should this be smarter to handle cases where the image might already exist but has a different set of supported platforms?!
        # shellcheck disable=SC2034
        inspect_results=$(skopeo inspect --authfile "${auth_file}" --retry-times "${skopeo_retries}" --raw "$target_image_url" 2>&1)
        rc="$?"
        set -e

        local status=

        if [ "${rc}" -ne 0 ]; then
            printf '%sCopying %s to %s%s\n' "$(if [ "${dry_run}" = 't' ]; then printf '%s' "[DRY RUN] "; fi)" "${source_image_url}" "${target_image_url}" "${multi_arch:+" for $multi_arch platforms [$(jq -rc 'join(",")' <<< "${platforms_json}")]"}"

            if [ "${dry_run}" != 't' ]; then
                # Don't wait to exit on error here as we wanna do some post-processing based on outcome
                set +e
                local rc=
                # TODO: detect and "handle" rate limiting errors somehow (really long sleep?  just immediately exit?)
                skopeo copy --authfile "${auth_file}"  --retry-times "${skopeo_retries}" --preserve-digests ${multi_arch:+--multi-arch "$multi_arch"} "${source_image_url}" "${target_image_url}" | sed 's/^/\t/'
                rc="$?"
                set -e

                local status=
                if [ "${rc}" -eq 0 ]; then
                    status="complete"
                else
                    status="error"
                fi
            fi
        else
            status="complete"
        fi

        _update_image_migration_status "${source_repo}" "${tag}" "${status}"
    done

}


main()
{
    _verify_prereqs

    _parse_opts "$@"

    _initialize_state

    _confirm_auth

    _discover_image_tags

    _copy_images
}

script_dir=
_set_script_dir

config_file="${script_dir}/config.json"
state_file="${config_file}.state"
auth_file="${config_file}.auth"

skopeo_retries=3

dry_run=
source_container_registry_host=
target_container_registry_host=

if _do_invoke; then
    main "$@"
fi
