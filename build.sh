#!/bin/bash -eux

# Get inputs from JSON
INPUTS=${1-}
INPUT_ASSET_NAME=$(echo "$INPUTS" | jq -r '.ASSET_NAME')
INPUT_BINARY_NAME=$(echo "$INPUTS" | jq -r '.BINARY_NAME')
INPUT_BUILD_COMMAND=$(echo "$INPUTS" | jq -r '.BUILD_COMMAND')
INPUT_BUILD_FLAGS=$(echo "$INPUTS" | jq -r '.BUILD_FLAGS')
INPUT_COMPRESS_ASSETS=$(echo "$INPUTS" | jq -r '.COMPRESS_ASSETS')
INPUT_EXECUTABLE_COMPRESSION=$(echo "$INPUTS" | jq -r '.EXECUTABLE_COMPRESSION')
INPUT_EXTRA_FILES=$(echo "$INPUTS" | jq -r '.EXTRA_FILES')
INPUT_GITHUB_TOKEN=$(echo "$INPUTS" | jq -r '.GITHUB_TOKEN')
INPUT_GOAMD64=$(echo "$INPUTS" | jq -r '.GOAMD64')
INPUT_GOARCH=$(echo "$INPUTS" | jq -r '.GOARCH')
INPUT_GOOS=$(echo "$INPUTS" | jq -r '.GOOS')
INPUT_LDFLAGS=$(echo "$INPUTS" | jq -r '.LDFLAGS')
INPUT_MD5SUM=$(echo "$INPUTS" | jq -r '.MD5SUM')
INPUT_OVERWRITE=$(echo "$INPUTS" | jq -r '.OVERWRITE')
INPUT_POST_COMMAND=$(echo "$INPUTS" | jq -r '.POST_COMMAND')
INPUT_PRE_COMMAND=$(echo "$INPUTS" | jq -r '.PRE_COMMAND')
INPUT_PROJECT_PATH=$(echo "$INPUTS" | jq -r '.PROJECT_PATH')
INPUT_RELEASE_NAME=$(echo "$INPUTS" | jq -r '.RELEASE_NAME')
INPUT_RELEASE_TAG=$(echo "$INPUTS" | jq -r '.RELEASE_TAG')
INPUT_RETRY=$(echo "$INPUTS" | jq -r '.RETRY')
INPUT_SHA256SUM=$(echo "$INPUTS" | jq -r '.SHA256SUM')
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

function preBuild() {
	if [ -n "${INPUT_PRE_COMMAND}" ]; then
		eval "${INPUT_PRE_COMMAND}"
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
	LDFLAGS_PREFIX=''
	if [ -n "${INPUT_LDFLAGS}" ]; then
		LDFLAGS_PREFIX="-ldflags"
	fi

	# fulfill GOAMD64 option
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
		GOAMD64=${GOAMD64_FLAG} GOOS="${INPUT_GOOS}" GOARCH="${INPUT_GOARCH}" eval "${INPUT_BUILD_COMMAND}"
		if [ -f "${BINARY_NAME}${EXT}" ]; then
			# assumes the binary will be generated in current dir, copy it for later processes
			cp "${BINARY_NAME}${EXT}" "${BUILD_ARTIFACTS_FOLDER}"/
		fi
	else
		local BUILD_CMD="${INPUT_BUILD_COMMAND} -o ${BUILD_ARTIFACTS_FOLDER}/${BINARY_NAME}${EXT} ${INPUT_BUILD_FLAGS} ${LDFLAGS_PREFIX} ${INPUT_LDFLAGS}"
		GOAMD64=${GOAMD64_FLAG} GOOS="${INPUT_GOOS}" GOARCH="${INPUT_GOARCH}" eval "${BUILD_CMD}"
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
			eval "${INPUT_EXECUTABLE_COMPRESSION}" "${BUILD_ARTIFACTS_FOLDER}/${BINARY_NAME}${EXT}"
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
		eval "${INPUT_POST_COMMAND}"
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
