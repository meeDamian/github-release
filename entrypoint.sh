#!/bin/sh -l

set -e

#
# Input verification
#
TOKEN="${INPUT_TOKEN}"
if [ -z "${TOKEN}" ]; then
  >&2 printf "\nERR: Invalid input: 'token' is required, and must be specified.\n"
  >&2 printf "\tNote: It's necessary to interact with Github's API.\n\n"
  >&2 printf "Try:\n"
  >&2 printf "\tuses: meeDamian/github-release@TAG\n"
  >&2 printf "\twith:\n"
  >&2 printf "\t  token: \${{ secrets.GITHUB_TOKEN }}\n"
  >&2 printf "\t  ...\n"
  exit 1
fi

TAG="${INPUT_TAG}"

# If `tag:` not provided, let's try using one available from github's context
if [ -z "${TAG}" ]; then
  TAG="$(echo "${GITHUB_REF}" | awk -F/ '{print $NF}')"
fi

# If all ways of getting the tag failed, show error
if [ -z "${TAG}" ]; then
  >&2 printf "\nERR: Invalid input: 'tag' is required, and must be specified.\n"
  >&2 printf "\tNote: It's used as a reference to the release.\n\n"
  >&2 printf "Try:\n"
  >&2 printf "\tuses: meeDamian/github-release@TAG\n"
  >&2 printf "\twith:\n"
  >&2 printf "\t  tag: v0.0.1\n"
  >&2 printf "\t  ...\n"
  exit 1
fi

# Verify that gzip: option is set to any of the allowed values
if [ "${INPUT_GZIP}" != "true" ] && [ "${INPUT_GZIP}" != "false" ] && [ "${INPUT_GZIP}" != "folders" ]; then
  >&2 printf "\nERR: Invalid input: 'gzip' can only be not set, or one of: true, false, folders\n"
  >&2 printf "\tNote: It defines what to do with assets before uploading them.\n\n"
  >&2 printf "Try:\n"
  >&2 printf "\tuses: meeDamian/github-release@TAG\n"
  >&2 printf "\twith:\n"
  >&2 printf "\t  gzip: true\n"
  >&2 printf "\t  ...\n"
  exit 1
fi

BASE_URL="https://api.github.com/repos/${GITHUB_REPOSITORY}/releases"

#
## Check for Github Release existence
#
RELEASE_ID="$(curl -H "Authorization: token ${TOKEN}"  "${BASE_URL}/tags/${TAG}" | jq -r '.id | select(. != null)')"

if [ -n "${RELEASE_ID}" ] && [ "${INPUT_ALLOW_OVERRIDE}" != "true" ]; then
  >&2 printf "\nERR: Release '%s' already exists, and overriding is not allowed.\n" "${TAG}"
  >&2 printf "\tNote: Either use different 'tag:' name, or 'allow_override:'\n\n"
  >&2 printf "Try:\n"
  >&2 printf "\tuses: meeDamian/github-release@TAG\n"
  >&2 printf "\twith:\n"
  >&2 printf "\t  ...\n"
  >&2 printf "\t  allow_override: true\n"
  exit 1
fi


#
## Create, or update release on Github
#
# For a given string return either `null` (if empty), or `"quoted string"` (if not)
toJsonOrNull() {
  if [ -z "$1" ]; then
    echo null
    return
  fi

  if [ "$1" = "true" ] || [ "$1" = "false" ]; then
    echo "$1"
    return
  fi

  echo "\"$1\""
}

METHOD="POST"
URL="${BASE_URL}"
if [ -n "${RELEASE_ID}" ]; then
  METHOD="PATCH"
  URL="${URL}/${RELEASE_ID}"
fi

# Creating the object in a PATCH-friendly way
CODE="$(jq -nc \
  --arg tag_name              "${TAG}" \
  --argjson target_commitish  "$(toJsonOrNull "${INPUT_COMMITISH}")"  \
  --argjson name              "$(toJsonOrNull "${INPUT_NAME}")"       \
  --argjson body              "$(toJsonOrNull "${INPUT_BODY}")"       \
  --argjson draft             "$(toJsonOrNull "${INPUT_DRAFT}")"      \
  --argjson prerelease        "$(toJsonOrNull "${INPUT_PRERELEASE}")" \
  '{$tag_name, $target_commitish, $name, $body, $draft, $prerelease} | del(.[] | nulls)' | \
  curl -s -X "${METHOD}" -d @- \
  --write-out "%{http_code}" -o "/tmp/${METHOD}.json" \
  -H "Authorization: token ${TOKEN}" \
  -H "Content-Type: application/json" \
  "${URL}")"

if [ "${CODE}" != "200" ] && [ "${CODE}" != "201" ]; then
  >&2 printf "\n\tERR: %s to Github release has failed\n" "${METHOD}"
  >&2 jq < "/tmp/${METHOD}.json"
  exit 1
fi

RELEASE_ID="$(jq '.id' < "/tmp/${METHOD}.json")"

#
## Handle, and prepare assets
#
if [ -z "${INPUT_FILES}" ]; then
  >&2 echo "All done."
  exit 0
fi

ASSETS="${HOME}/assets"

mkdir -p "${ASSETS}/"

# this loop splits files by the space
for entry in $(echo "${INPUT_FILES}" | tr ' ' '\n'); do
  ASSET_NAME="${entry}"

  # Well, that needs explaining…  If delimiter given in `-d` does not occur in string, `cut` always returns
  #   the original string, no matter what the field `-f` specifies.
  #
  # I'm prepanding `:` to `${entry}` in `echo` to ensure match happens, because once it does, `-f` is respected,
  #   and I can easily check fields, and that way:
  #   * `-f 2` always contains the name of the asset
  #   * `-f 3` is either the custom name of the asset,
  #   * `-f 3` is empty, and needs to be set to `-f 2`
  ASSET_NAME="$(echo ":${entry}" | cut -d: -f2)"
  ASSET_PATH="$(echo ":${entry}" | cut -d: -f3)"

  if [ -z "${ASSET_PATH}" ]; then
    ASSET_NAME="$(basename "${entry}")"
    ASSET_PATH="${entry}"
  fi

  # this loop, expands possible globs
  for file in ${ASSET_PATH}; do
    # Error out on the only illegal combination: compression disabled, and folder provided
    if [ "${INPUT_GZIP}" = "false" ] && [ -d "${file}" ]; then
        >&2 printf "\nERR: Invalid configuration: 'gzip' cannot be set to 'false' while there are 'folders/' provided.\n"
        >&2 printf "\tNote: Either set 'gzip: folders', or remove directories from the 'files:' list.\n\n"
        >&2 printf "Try:\n"
        >&2 printf "\tuses: meeDamian/github-release@TAG\n"
        >&2 printf "\twith:\n"
        >&2 printf "\t  ...\n"
        >&2 printf "\t  gzip: folders\n"
        >&2 printf "\t  files: >\n"
        >&2 printf "\t    README.md\n"
        >&2 printf "\t    my-artifacts/\n"
        exit 1
    fi

    # Just copy files, if compression not enabled for all
    if [ "${INPUT_GZIP}" != "true" ] && [ -f "${file}" ]; then
      cp "${file}" "${ASSETS}/${ASSET_NAME}"
      continue
    fi

    # In any other case compress
    tar -cf "${ASSETS}/${ASSET_NAME}.tgz"  "${file}"
  done
done

# At this point all assets to-be-uploaded (if any), are in `${ASSETS}/` folder
echo "Files to be uploaded to Github:"
ls "${ASSETS}/"

UPLOAD_URL="$(echo "${BASE_URL}" | sed -e 's/api/uploads/')"

for asset in "${ASSETS}"/*; do
  FILE_NAME="$(basename "${asset}")"

  CODE="$(curl -sS  -X POST \
    --write-out "%{http_code}" -o "/tmp/${FILE_NAME}.json" \
    -H "Authorization: token ${TOKEN}" \
    -H "Content-Length: $(stat -c %s "${asset}")" \
    -H "Content-Type: $(file -b --mime-type "${asset}")" \
    --upload-file "${asset}" \
    "${UPLOAD_URL}/${RELEASE_ID}/assets?name=${FILE_NAME}")"

  if [ "${CODE}" -ne "201" ]; then
    >&2 printf "\n\tERR: Uploading %s to Github release has failed\n" "${FILE_NAME}"
    jq < "/tmp/${FILE_NAME}.json"
    exit 1
  fi
done

>&2 echo "All done."
