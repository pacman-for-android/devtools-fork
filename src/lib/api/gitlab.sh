#!/hint/bash
#
# SPDX-License-Identifier: GPL-3.0-or-later

[[ -z ${DEVTOOLS_INCLUDE_API_GITLAB_SH:-} ]] || return 0
DEVTOOLS_INCLUDE_API_GITLAB_SH=1

_DEVTOOLS_LIBRARY_DIR=${_DEVTOOLS_LIBRARY_DIR:-@pkgdatadir@}
# shellcheck source=src/lib/common.sh
source "${_DEVTOOLS_LIBRARY_DIR}"/lib/common.sh
# shellcheck source=src/lib/config.sh
source "${_DEVTOOLS_LIBRARY_DIR}"/lib/config.sh

set -e


gitlab_api_call() {
	local outfile=$1
	local request=$2
	local endpoint=$3
	local data=${4:-}
	local error

	# empty token
	if [[ -z "${GITLAB_TOKEN}" ]]; then
		msg_error "  api call failed: No token provided"
		return 1
	fi

	if ! curl --request "${request}" \
			--url "https://${GITLAB_HOST}/api/v4/${endpoint}" \
			--header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
			--header "Content-Type: application/json" \
			--data "${data}" \
			--output "${outfile}" \
			--silent; then
		msg_error "  api call failed: $(cat "${outfile}")"
		return 1
	fi

	# check for general purpose api error
	if error=$(jq --raw-output --exit-status '.error' < "${outfile}"); then
		msg_error "  api call failed: ${error}"
		return 1
	fi

	# check for api specific error messages
	if ! jq --raw-output --exit-status '.id' < "${outfile}" >/dev/null; then
		if jq --raw-output --exit-status '.message | keys[]' < "${outfile}" &>/dev/null; then
			while read -r error; do
				msg_error "  api call failed: ${error}"
			done < <(jq --raw-output --exit-status '.message|to_entries|map("\(.key) \(.value[])")[]' < "${outfile}")
		elif error=$(jq --raw-output --exit-status '.message' < "${outfile}"); then
			msg_error "  api call failed: ${error}"
		fi
		return 1
	fi

	return 0
}

gitlab_api_get_user() {
	local outfile username

	[[ -z ${WORKDIR:-} ]] && setup_workdir
	outfile=$(mktemp --tmpdir="${WORKDIR}" pkgctl-gitlab-api.XXXXXXXXXX)

	# query user details
	if ! gitlab_api_call "${outfile}" GET "user/"; then
		msg_warn "  Invalid token provided?"
		exit 1
	fi

	# extract username from details
	if ! username=$(jq --raw-output --exit-status '.username' < "${outfile}"); then
		msg_error "  failed to query username: $(cat "${outfile}")"
		return 1
	fi

	printf "%s" "${username}"
	return 0
}

# Convert arbitrary project names to GitLab valid path names.
#
# GitLab has several limitations on project and group names and also maintains
# a list of reserved keywords as documented on their docs.
# https://docs.gitlab.com/ee/user/reserved_names.html
#
# 1. replace single '+' between word boundaries with '-'
# 2. replace any other '+' with literal 'plus'
# 3. replace any special chars other than '_', '-' and '.' with '-'
# 4. replace consecutive '_-' chars with a single '-'
# 5. replace 'tree' with 'unix-tree' due to GitLab reserved keyword
gitlab_project_name_to_path() {
	local name=$1
	printf "%s" "${name}" \
		| sed -E 's/([a-zA-Z0-9]+)\+([a-zA-Z]+)/\1-\2/g' \
		| sed -E 's/\+/plus/g' \
		| sed -E 's/[^a-zA-Z0-9_\-\.]/-/g' \
		| sed -E 's/[_\-]{2,}/-/g' \
		| sed -E 's/^tree$/unix-tree/g'
}

gitlab_api_create_project() {
	local pkgbase=$1
	local outfile data path project_path

	[[ -z ${WORKDIR:-} ]] && setup_workdir
	outfile=$(mktemp --tmpdir="${WORKDIR}" pkgctl-gitlab-api.XXXXXXXXXX)

	project_path=$(gitlab_project_name_to_path "${pkgbase}")

	# create GitLab project
	data='{
		"name": "'"${pkgbase}"'",
		"path": "'"${project_path}"'",
		"namespace_id": "'"${GIT_PACKAGING_NAMESPACE_ID}"'",
		"request_access_enabled": "false"
	}'
	if ! gitlab_api_call "${outfile}" POST "projects/" "${data}"; then
		return 1
	fi

	if ! path=$(jq --raw-output --exit-status '.path' < "${outfile}"); then
		msg_error "  failed to query path: $(cat "${outfile}")"
		return 1
	fi

	printf "%s" "${path}"
	return 0
}
