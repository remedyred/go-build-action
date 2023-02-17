#!/bin/bash -eux

function jqGet() {
	local VALUE
	VALUE=$(echo "$INPUTS" | jq -r "$1")
	if [ "${VALUE}" == "null" ]; then
		VALUE=""
	fi
	echo "${VALUE}"
}

# Get inputs from JSON
INPUTS=${1-}
INPUT_ASSET_NAME=$(jqGet '.ASSET_NAME')
INPUT_BINARY_NAME=$(jqGet '.BINARY_NAME')
INPUT_BUILD_COMMAND=$(jqGet '.BUILD_COMMAND')
INPUT_BUILD_FLAGS=$(jqGet '.BUILD_FLAGS')
INPUT_COMPRESS_ASSETS=$(jqGet '.COMPRESS_ASSETS')
INPUT_EXECUTABLE_COMPRESSION=$(jqGet '.EXECUTABLE_COMPRESSION')
INPUT_EXTRA_FILES=$(jqGet '.EXTRA_FILES')
INPUT_GITHUB_TOKEN=$(jqGet '.GITHUB_TOKEN')
INPUT_GOAMD64=$(jqGet '.GOAMD64')
INPUT_GOARCH=$(jqGet '.GOARCH')
INPUT_GOOS=$(jqGet '.GOOS')
INPUT_LDFLAGS=$(jqGet '.LDFLAGS')
INPUT_MD5SUM=$(jqGet '.MD5SUM')
INPUT_OVERWRITE=$(jqGet '.OVERWRITE')
INPUT_POST_COMMAND=$(jqGet '.POST_COMMAND')
INPUT_PRE_COMMAND=$(jqGet '.PRE_COMMAND')
INPUT_PROJECT_PATH=$(jqGet '.PROJECT_PATH')
INPUT_RELEASE_NAME=$(jqGet '.RELEASE_NAME')
INPUT_RELEASE_TAG=$(jqGet '.RELEASE_TAG')
INPUT_RETRY=$(jqGet '.RETRY')
INPUT_SHA256SUM=$(jqGet '.SHA256SUM')
DRY_RUN=${DRY_RUN:-$(jqGet '.DRY_RUN')}
##

## DECLARE GLOBAL VARS ##
MD5_SUM=""
SHA256_SUM=""

BINARY_NAME=$(basename "${GITHUB_REPOSITORY}")
if [ "${INPUT_BINARY_NAME}" != "" ]; then
	BINARY_NAME="${INPUT_BINARY_NAME}"
fi

RELEASE_TAG=$(basename "${GITHUB_REF}")
if [ -n "${INPUT_RELEASE_TAG}" ]; then
	RELEASE_TAG="${INPUT_RELEASE_TAG}"
elif [ -n "${INPUT_RELEASE_NAME}" ]; then
	RELEASE_TAG=""
fi

RELEASE_NAME="${INPUT_RELEASE_NAME}"
if [ -n "${INPUT_ASSET_NAME}" ]; then
	RELEASE_ASSET_NAME="${INPUT_ASSET_NAME}"
else
	RELEASE_ASSET_NAME="${BINARY_NAME}"-"${RELEASE_TAG}"-"${INPUT_GOOS}"-"${INPUT_GOARCH}"
	if [ -n "${INPUT_GOAMD64}" ]; then
		RELEASE_ASSET_NAME="${RELEASE_ASSET_NAME}"-${INPUT_GOAMD64}
	fi
fi

ALLOWED_EVENTS=("release" "push" "workflow_dispatch" "workflow_run" "pull_request")
if [[ ${ALLOWED_EVENTS[*]} =~ $GITHUB_EVENT_NAME ]]; then
	echo "Event: ${GITHUB_EVENT_NAME}"
else
	echo "Unsupported event: ${GITHUB_EVENT_NAME}!"
	exit 1
fi
##

function run() {
	if $DRY_RUN; then
		echo "DRY_RUN: $1"
	else
		eval "$1"
	fi
}

function escape_quotes() {
	local input_string="$1"
	echo "$input_string" | sed "s/'/'\\\\''/g; s/\"/\\\\\"/g"
}

function preBuild() {
	if [ -n "${INPUT_PRE_COMMAND}" ]; then
		run "${INPUT_PRE_COMMAND}"
	fi
}

### BUILD EXECUTABLE ###
function build() {
	# binary suffix
	EXT=''
	if [ "${INPUT_GOOS}" == 'windows' ]; then
		EXT='.exe'
	fi

	# prefix for ldflags
	local LDFLAGS_PREFIX=''
	if [ -n "${INPUT_LDFLAGS}" ]; then
		LDFLAGS_PREFIX="-ldflags"
	fi

	# fulfill GOAMD64 option
	local GOAMD64_FLAG
	if [ -n "${INPUT_GOAMD64}" ]; then
		if [[ ${INPUT_GOARCH} =~ amd64 ]]; then
			GOAMD64_FLAG="${INPUT_GOAMD64}"
		else
			echo "GOAMD64 should only be use with amd64 arch." >>/dev/stderr
			GOAMD64_FLAG=""
		fi
	else
		if [[ ${INPUT_GOARCH} =~ amd64 ]]; then
			GOAMD64_FLAG="v1"
		else
			GOAMD64_FLAG=""
		fi
	fi

	local BUILD_ARTIFACTS_FOLDER=build-artifacts-$(date +%s)
	mkdir -p "${INPUT_PROJECT_PATH}/${BUILD_ARTIFACTS_FOLDER}"
	cd "${INPUT_PROJECT_PATH}"
	if [[ ${INPUT_BUILD_COMMAND} =~ ^make.* ]]; then
		# start with make, assumes using make to build golang binaries, execute it directly
		GOAMD64=${GOAMD64_FLAG} GOOS="${INPUT_GOOS}" GOARCH="${INPUT_GOARCH}" run "${INPUT_BUILD_COMMAND}"
		if [ -f "${BINARY_NAME}${EXT}" ]; then
			# assumes the binary will be generated in current dir, copy it for later processes
			cp "${BINARY_NAME}${EXT}" "${BUILD_ARTIFACTS_FOLDER}"/
		fi
	else
		local BUILD_CMD
		BUILD_CMD="${INPUT_BUILD_COMMAND} -o ${BUILD_ARTIFACTS_FOLDER}/${BINARY_NAME}${EXT} ${INPUT_BUILD_FLAGS} ${LDFLAGS_PREFIX} $(escape_quotes "$INPUT_LDFLAGS")"
		GOAMD64=${GOAMD64_FLAG} GOOS="${INPUT_GOOS}" GOARCH="${INPUT_GOARCH}" run "${BUILD_CMD}"
	fi

	if [ "${GITHUB_EVENT_NAME}" = "pull_request" ]; then
		# skip upload-asset, compression for pull_request event
		echo "Binary file: ${BUILD_ARTIFACTS_FOLDER}/${BINARY_NAME}${EXT}"
		if [[ -f "${BUILD_ARTIFACTS_FOLDER}/${BINARY_NAME}${EXT}" ]]; then
			ls -lha "${BUILD_ARTIFACTS_FOLDER}/${BINARY_NAME}${EXT}"
			exit 0
		else
			echo "ERROR: Build Failed! Binary file not found: ${BUILD_ARTIFACTS_FOLDER}/${BINARY_NAME}${EXT}"
			exit 1
		fi
	fi
}

### COMPRESS EXECUTABLE & ASSETS ###
function compress() {
	if [ -n "${INPUT_EXECUTABLE_COMPRESSION}" ]; then
		if [[ ${INPUT_EXECUTABLE_COMPRESSION} =~ ^upx.* ]]; then
			run "${INPUT_EXECUTABLE_COMPRESSION}" "${BUILD_ARTIFACTS_FOLDER}/${BINARY_NAME}${EXT}"
		else
			echo "Unsupported executable compression: ${INPUT_EXECUTABLE_COMPRESSION}!"
			exit 1
		fi
	fi

	# prepare extra files
	if [ -n "${INPUT_EXTRA_FILES}" ]; then
		cd "${GITHUB_WORKSPACE}"
		cp -r "${INPUT_EXTRA_FILES}" "${INPUT_PROJECT_PATH}/${BUILD_ARTIFACTS_FOLDER}/"
		cd "${INPUT_PROJECT_PATH}"
	fi

	cd "${BUILD_ARTIFACTS_FOLDER}"
	ls -lha

	# INPUT_COMPRESS_ASSETS=='TRUE' is used for backwards compatability. `AUTO`, `ZIP`, `OFF` are the recommended values
	if [ "${INPUT_COMPRESS_ASSETS^^}" == "TRUE" ] || [ "${INPUT_COMPRESS_ASSETS^^}" == "AUTO" ] || [ "${INPUT_COMPRESS_ASSETS^^}" == "ZIP" ]; then
		local RELEASE_ASSET_EXT='.tar.gz'
		local MEDIA_TYPE='application/gzip'
		local RELEASE_ASSET_FILE="${RELEASE_ASSET_NAME}${RELEASE_ASSET_EXT}"
		if [ "${INPUT_GOOS}" == 'windows' ] || [ "${INPUT_COMPRESS_ASSETS^^}" == "ZIP" ]; then
			RELEASE_ASSET_EXT='.zip'
			MEDIA_TYPE='application/zip'
			RELEASE_ASSET_FILE="${RELEASE_ASSET_NAME}${RELEASE_ASSET_EXT}"
			(
				shopt -s dotglob
				zip -vr "${RELEASE_ASSET_FILE}" -- *
			)
		else
			(
				shopt -s dotglob
				tar cvfz "${RELEASE_ASSET_FILE}" -- *
			)
		fi
	elif [ "${INPUT_COMPRESS_ASSETS^^}" == "OFF" ] || [ "${INPUT_COMPRESS_ASSETS^^}" == "FALSE" ]; then
		RELEASE_ASSET_EXT="${EXT}"
		MEDIA_TYPE="application/octet-stream"
		RELEASE_ASSET_FILE="${RELEASE_ASSET_NAME}${RELEASE_ASSET_EXT}"
		cp "${BINARY_NAME}${EXT}" "${RELEASE_ASSET_FILE}"
	else
		echo "Invalid value for INPUT_COMPRESS_ASSETS: ${INPUT_COMPRESS_ASSETS}. Acceptable values are AUTO, ZIP, or OFF."
		exit 1
	fi
	MD5_SUM=$(md5sum "${RELEASE_ASSET_FILE}" | cut -d ' ' -f 1)
	SHA256_SUM=$(sha256sum "${RELEASE_ASSET_FILE}" | cut -d ' ' -f 1)
}

### UPDATE RELEASE ###
function publish() {
	local GITHUB_ASSETS_UPLOADER_EXTRA_OPTIONS=''
	if [ "${INPUT_OVERWRITE^^}" == 'TRUE' ]; then
		GITHUB_ASSETS_UPLOADER_EXTRA_OPTIONS="-overwrite"
	fi

	github-assets-uploader -logtostderr -f "${RELEASE_ASSET_FILE}" -mediatype "${MEDIA_TYPE}" "${GITHUB_ASSETS_UPLOADER_EXTRA_OPTIONS}" -repo "${GITHUB_REPOSITORY}" -token "${INPUT_GITHUB_TOKEN}" -tag="${RELEASE_TAG}" -releasename="${RELEASE_NAME}" -retry "${INPUT_RETRY}"
	if [ "${INPUT_MD5SUM^^}" == 'TRUE' ]; then
		local MD5_EXT='.md5'
		local MD5_MEDIA_TYPE='text/plain'
		echo "${MD5_SUM}" >"${RELEASE_ASSET_FILE}"${MD5_EXT}
		github-assets-uploader -logtostderr -f "${RELEASE_ASSET_FILE}"${MD5_EXT} -mediatype ${MD5_MEDIA_TYPE} "${GITHUB_ASSETS_UPLOADER_EXTRA_OPTIONS}" -repo "${GITHUB_REPOSITORY}" -token "${INPUT_GITHUB_TOKEN}" -tag="${RELEASE_TAG}" -releasename="${RELEASE_NAME}" -retry "${INPUT_RETRY}"
	fi

	if [ "${INPUT_SHA256SUM^^}" == 'TRUE' ]; then
		local SHA256_EXT='.sha256'
		local SHA256_MEDIA_TYPE='text/plain'
		echo "${SHA256_SUM}" >"${RELEASE_ASSET_FILE}"${SHA256_EXT}
		github-assets-uploader -logtostderr -f "${RELEASE_ASSET_FILE}"${SHA256_EXT} -mediatype ${SHA256_MEDIA_TYPE} "${GITHUB_ASSETS_UPLOADER_EXTRA_OPTIONS}" -repo "${GITHUB_REPOSITORY}" -token "${INPUT_GITHUB_TOKEN}" -tag="${RELEASE_TAG}" -releasename="${RELEASE_NAME}" -retry "${INPUT_RETRY}"
	fi
}

### POST COMMAND ###
function postPublish() {
	if [ -n "${INPUT_POST_COMMAND}" ]; then
		run "${INPUT_POST_COMMAND}"
	fi
}

function main() {
	preBuild
	build
	compress
	publish
	postPublish
}

main
