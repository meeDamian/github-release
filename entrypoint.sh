#!/bin/sh -le

PKG="meeDamian/github-release@2.0"

#
## Input verification
#
TOKEN="$INPUT_TOKEN"
if [ -z "$TOKEN" ]; then
	>&2 echo "::error::missing: token (see log for details)"
	>&2 printf "\nERR: Invalid input: 'token' is required, and must be specified.\n"
	>&2 printf "\tNote: It's necessary to interact with Github's API.\n\n"
	>&2 printf "Try:\n"
	>&2 printf "\tuses: %s\n" "$PKG"
	>&2 printf "\twith:\n"
	>&2 printf "\t  token: \${{ secrets.GITHUB_TOKEN }}\n"
	>&2 printf "\t  ...\n\n"
	exit 1
fi

# Try getting $tag from action input
tag="$INPUT_TAG"

# [fallback] Try getting $tag from Github context (only works on git-tag push action)
if [ -z "$tag" ]; then
	tag="$(echo "$GITHUB_REF" | grep 'refs/tags/' | awk -F/ '{ print $NF }')"
fi

# If all ways of getting the $tag failed, exit with an error
if [ -z "$tag" ]; then
	>&2 echo "::error::missing: tag (see log for details)"
	>&2 printf "\nERR: Invalid input: 'tag' is required, and must be specified.\n"
	>&2 printf "Try:\n"
	>&2 printf "\tuses: %s\n" "$PKG"
	>&2 printf "\twith:\n"
	>&2 printf "\t  tag: v0.0.1\n"
	>&2 printf "\t  ...\n\n"
	>&2 printf "Note: To use \$tag from env variable set before, use:\n"
	>&2 printf '\twith:\n'
	>&2 printf "\t  tag: \${{ env.TAG }}\n"
	>&2 printf "\t  ...\n\n"
	exit 1
fi

# Verify that gzip: option is set to any of the allowed values
if [ "$INPUT_GZIP" != "true" ] && [ "$INPUT_GZIP" != "false" ] && [ "$INPUT_GZIP" != "folders" ]; then
	>&2 echo "::error::invalid: gzip (see log for details)"
	>&2 printf "\nERR: Invalid input: 'gzip' can only be not set, or one of: true, false, folders\n"
	>&2 printf "\tNote: It defines what to do with assets before uploading them.\n\n"
	>&2 printf "Try:\n"
	>&2 printf "\tuses: %s\n" "$PKG"
	>&2 printf "\twith:\n"
	>&2 printf "\t  gzip: true\n"
	>&2 printf "\t  ...\n\n"
	exit 1
fi

releases_url="https://api.github.com/repos/$GITHUB_REPOSITORY/releases"

gh_release_api() {
	url="$1"
	method="${2:-GET}"
	curl -sS  -H "Authorization: token $TOKEN"  -X "$method"  "$releases_url/$url"
}

#
## Check for Github Release existence
#
# docs ref: https://developer.github.com/v3/repos/releases/#get-a-release-by-tag-name
release_id="$(gh_release_api "tags/$tag" | jq -r '.id | values')"

if [ -n "$release_id" ] && [ "$INPUT_ALLOW_OVERRIDE" != "true" ]; then
	>&2 echo "::error::missing: allow_override (see log for details)"
	>&2 printf "\nERR: Release for tag='%s' already exists, and overriding is not allowed.\n" "$tag"
	>&2 printf "\tNote: Either use different 'tag:' name, or set 'allow_override:'\n\n"
	>&2 printf "Try:\n"
	>&2 printf "\tuses: %s\n" "$PKG"
	>&2 printf "\twith:\n"
	>&2 printf "\t  ...\n"
	>&2 printf "\t  allow_override: true\n\n"
	exit 1
fi

echo "::group::Create Release"

TMP="$(mktemp -d)"

method="POST"
full_url="$releases_url"
if [ -n "$release_id" ]; then
	method="PATCH"
	full_url="$full_url/$release_id"
fi

# If `draft` is not set, while `files` are provided, then
#   1. Create Release as DRAFT
#   2. Upload all files as Release Assets
#   3. If all uploads succeed, publish the Release
draft="$INPUT_DRAFT"
if [ -z "$INPUT_DRAFT" ] && [ -n "$INPUT_FILES" ]; then
	draft=true
fi

# Creating the object in a PATCH-friendly way
#   If POST:  https://developer.github.com/v3/repos/releases/#create-a-release,
#   If PATCH: https://developer.github.com/v3/repos/releases/#edit-a-release
status_code="$(jq -nc \
	--arg tag_name         "$tag" \
	--arg name             "$INPUT_NAME" \
	--arg body             "$(printf '%s' "$INPUT_BODY" | sed 's|\\|\\\\|g')" \
	--arg target_commitish "$INPUT_COMMITISH" \
	--argjson draft        "${draft:-null}" \
	--argjson prerelease   "${INPUT_PRERELEASE:-null}" \
	'{$tag_name, $name, $body, $target_commitish, $draft, $prerelease} | del(.[] | select(. == null or . == ""))' | \
	curl -sS -X "$method" -d @- \
		--write-out "%{http_code}" -o "$TMP/$method.json" \
		-H "Authorization: token $TOKEN" \
		-H "Content-Type: application/json" \
		"$full_url")"

if [ "$status_code" != "200" ] && [ "$status_code" != "201" ]; then
	>&2 echo "::error::failed to create release (see log for details)"
	>&2 printf "\n\tERR: %s to Github release has failed\n" "$method"
	>&2 jq . < "$TMP/$method.json"
	exit 1
fi


release_id="$(jq '.id' < "$TMP/$method.json")"

# Make release ID available to other steps in user's workflow
echo "release_id=$release_id" >> $GITHUB_OUTPUT
echo "::endgroup::"

#
## Handle, and prepare assets
#

if [ -z "$INPUT_FILES" ]; then
	>&2 echo "No assets to upload. All done."
	exit 0
fi

echo "::group::Upload Assets"

assets="$HOME/assets"
mkdir -p "$assets/"


# This loop splits files on space
for entry in $INPUT_FILES; do
	# Well, that needs explaining…  If delimiter given in `-d` does not occur in string, `cut` always returns
	#   the original string, no matter what the field `-f` specifies.
	#
	# Prepend `:` to `$entry` to ensure match happens, because `-f` in `cut` is only respected when it does, and that way:
	#   * `-f 2` always contains the name of the asset
	#   * `-f 3` is either the custom name of the asset, or
	#            is empty, and needs to be set to value of `-f 2`
	asset_name="$(echo ":$entry" | cut -d: -f2)"
	asset_path="$(echo ":$entry" | cut -d: -f3)"

	if [ -z "$asset_path" ]; then
		asset_name="$(basename "$entry")"
		asset_path="$entry"
	fi

  # this loop, expands possible globs
	for file in $asset_path; do
		# Error out on the only illegal combination:  compression disabled AND folder provided
		if [ "$INPUT_GZIP" = "false" ] && [ -d "$file" ]; then
			>&2 echo "::error::invalid: gzip and files combination (see log for details)"
			>&2 printf "\nERR: Invalid configuration: 'gzip' cannot be set to 'false' while there are 'folders/' provided.\n"
			>&2 printf "\tNote: Either set 'gzip: folders', or remove directories from the 'files:' list.\n\n"
			>&2 printf "Try:\n"
			>&2 printf "\tuses: %s\n" "$PKG"
			>&2 printf "\twith:\n"
			>&2 printf "\t  ...\n"
			>&2 printf "\t  gzip: folders\n"
			>&2 printf "\t  files: >\n"
			>&2 printf "\t    README.md\n"
			>&2 printf "\t    my-artifacts/\n"
			exit 1
		fi

		# Just copy files, if compression not enabled for all
		if [ "$INPUT_GZIP" != "true" ] && [ -f "$file" ]; then
			cp "$file" "$assets/$asset_name"
			continue
		fi

		# In any other case compress
		tar -czf "$assets/$asset_name.tgz"  "$file"
	done
done


# At this point all assets to-be-uploaded (if any), are in `$assets/` folder
echo "Files to be uploaded to Github:"
ls "$assets/"


current_assets=

# If override is allowed, make sure there's no asset name collisions with ones already uploaded
if [ "$INPUT_ALLOW_OVERRIDE" = "true" ]; then
	# Get list of all assets as a JSON map of: name->id
	#   docs ref: https://developer.github.com/v3/repos/releases/#list-assets-for-a-release
	current_assets="$(gh_release_api "$release_id/assets" | jq -r 'map({ (.name): .id }) | add')"
fi


upload_url="$(echo "$releases_url" | sed -e 's|api|uploads|')"

for asset in "$assets"/*; do
	file_name="$(basename "$asset")"

	# If a list of previously uploaded assets is available, and contains
	#   item with the same name as currently uploaded, delete it first.
	if [ -n "$current_assets" ]; then
		asset_id="$(echo "$current_assets" | jq ".\"$file_name\"")"
		if [ -n "$asset_id" ]; then
			# docs ref: https://developer.github.com/v3/repos/releases/#delete-a-release-asset
			gh_release_api "assets/$asset_id" DELETE
		fi
	fi

	# docs ref: https://developer.github.com/v3/repos/releases/#upload-a-release-asset
	status_code="$(curl -sS  -X POST \
		--write-out "%{http_code}" -o "$TMP/$file_name.json" \
		-H "Authorization: token $TOKEN" \
		-H "Content-Length: $(stat -c %s "$asset")" \
		-H "Content-Type: $(file -b --mime-type "$asset")" \
		--upload-file "$asset" \
		"$upload_url/$release_id/assets?name=$file_name")"

	if [ "$status_code" -ne "201" ]; then
		>&2 echo "::error::failed to upload asset: $file_name (see log for details)"
		>&2 printf "\n\tERR: Failed asset upload: %s\n" "$file_name"
		>&2 jq . < "$TMP/$file_name.json"
		exit 1
	fi
done

echo "::endgroup::"

if [ -n "$INPUT_DRAFT" ]; then
	>&2 echo "Draft status already correct. All done."
	exit 0
fi

echo "::group::Complete Release"

# Publish Release
#   docs ref: https://developer.github.com/v3/repos/releases/#edit-a-release
status_code="$(curl -sS  -X PATCH  -d '{"draft": false}' \
	--write-out "%{http_code}" -o "$TMP/publish.json" \
	-H "Authorization: token $TOKEN" \
	-H "Content-Type: application/json" \
	"$releases_url/$release_id")"

if [ "$status_code" != "200" ]; then
	>&2 echo "::error::failed to complete release (see log for details)"
	>&2 printf "\n\tERR: Final publishing of the ready Github Release has failed\n"
	>&2 jq . < "$TMP/publish.json"
	exit 1
fi

echo "::endgroup::"

>&2 echo "All done."
