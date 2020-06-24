#!/bin/sh -l

set -e

PKG="meeDamian/github-release@2.0"

all_done() { >&2 echo "${1:+$1 }All Done."; exit 0; }
panic() { (
	[ -n "$3" ] && echo "::error::$2: $3 (see log for details)"
	printf "\nERR: %s\n\n" "$1"
	[ -n "$4" ] && jq . < "$4"
) >&2; exit 1; }


#
## Input verification
#
TOKEN="$INPUT_TOKEN"
[ -z "$TOKEN" ] && panic "Invalid input: 'token' is required, and must be specified.
	Note: Needed to interact with Github's API.

Try:
	uses: $PKG
	with:
	  token: \${{ secrets.GITHUB_TOKEN }}
	  ..." 'missing' 'token'

# If $tag name not provided explicitly by user, fallback to extraction from `$GITHUB_REF`.
tag="${INPUT_TAG:-${GITHUB_REF#refs/tags/}}"

# Equality means $tag can't be determined from `$GITHUB_REF`, as Action was not run on git-tag push.
[ "$tag" = "$GITHUB_REF" ] && panic "Invalid input: 'tag' is required, and must be specified.

Try:
	uses: $PKG
	with:
	  tag: v0.0.1           # to hardcode tag
	  tag: \${{ env.TAG }}   # to use tag from env variable
	  ..." 'missing' 'tag'


# Verify that gzip: option is set to any of the allowed values
[ "$INPUT_GZIP" != "true" ] && \
[ "$INPUT_GZIP" != "false" ] && \
[ "$INPUT_GZIP" != "folders" ] && panic "Invalid input: 'gzip' if set, can be only: true, false, or folders
	Note: It defines what to do with assets before upload.

Try:
	uses: $PKG
	with:
	  gzip: true
	  ..." 'invalid' 'gzip'


releases_url="https://api.github.com/repos/$GITHUB_REPOSITORY/releases"
gh_release_api() {
	url="$1"; method="${2:-GET}"
	curl -sS  -H "Authorization: token $TOKEN"  -X "$method"  "$releases_url/$url"
}


#
## Check Github Release existence for $tag
#       docs: https://developer.github.com/v3/repos/releases/#get-a-release-by-tag-name
release_id="$(gh_release_api "tags/$tag" | jq -r '.id | select(. != null)')"

[ "$INPUT_ALLOW_OVERRIDE" != "true" ] && \
[ -n "$release_id" ] && panic "Release for tag='$tag' already exists, and overriding is not allowed.
	Note: Either use different 'tag:' name, or set 'allow_override:'.

Try:
	uses: $PKG
	with:
	  ...
	  allow_override: true" 'missing' 'allow_override'


#
## Create or update Github Release
#
echo "::group::Create Release"

# For a given value return either: bool, `null` (if empty), or `"quoted string"` (in all other cases)
toJsonOrNull() {
	val="$(echo "${1:-null}" | tr '[:upper:]' '[:lower:]')"

	case "$val" in
		true|false|null) echo "$val"   ;;
		*)               echo "\"$1\"" ;;
	esac
}

full_url="$releases_url${release_id:+/$release_id}"
method="POST"
[ -n "$release_id" ] && \
	method="PATCH"

# If `draft` is not set, while `files` is, then:
#   1. Create Release as DRAFT
#   2. Upload all files as Release Assets
#   3. If all uploads succeed, publish the Release
draft="$INPUT_DRAFT"
[ -z "$INPUT_DRAFT" ] && \
[ -n "$INPUT_FILES" ] && \
	draft=true

TMP="$(mktemp -d)"

# Create data-object in a PATCH-friendly way
#   docs POST:  https://developer.github.com/v3/repos/releases/#create-a-release,
#   docs PATCH: https://developer.github.com/v3/repos/releases/#edit-a-release
status_code="$(jq -nc \
	--arg     tag_name          "$tag" \
	--argjson draft             "$(toJsonOrNull "$draft")" \
	--argjson target_commitish  "$(toJsonOrNull "$INPUT_COMMITISH")"  \
	--argjson name              "$(toJsonOrNull "$INPUT_NAME")"       \
	--argjson prerelease        "$(toJsonOrNull "$INPUT_PRERELEASE")" \
	--argjson body              "$(toJsonOrNull "$(echo "$INPUT_BODY" | sed ':a;N;$!ba;s/\n/\\n/g')")" \
	'{$tag_name, $target_commitish, $name, $body, $draft, $prerelease} | del(.[] | nulls)' | \
	curl -sS  -X "$method"  -d @- \
	--write-out "%{http_code}"  -o "$TMP/$method.json" \
	-H "Authorization: token $TOKEN" \
	-H "Content-Type: application/json" \
	"$full_url")"

[ "$status_code" != "200" ] && \
[ "$status_code" != "201" ] && panic "$method to Github release has failed with $status_code" \
	'api' "fail on Release $method" \
	"$TMP/$method.json"

release_id="$(jq '.id' < "$TMP/$method.json")"

# Make release ID available to other steps in user's workflow
echo "::set-output name=release_id::$release_id"
echo "::endgroup::"


#
## Assets: handle & prepare
#
[ -z "$INPUT_FILES" ] && \
	all_done 'No assets to upload.'

echo "::group::Upload Assets"

assets="$HOME/assets"
mkdir -p "$assets/"

for entry in $INPUT_FILES; do
	asset_path="${entry#*:}"
	asset_name="${entry%:*}"
	[ "$asset_name" = "$entry" ] && \
		asset_name="$(basename "$entry")"

	# Loop on possible globs in paths
	for file in $asset_path; do
		[ "$INPUT_GZIP" = "false" ] && \
		[ -d "$file" ] && panic "Invalid configuration: 'gzip' can't be 'false' when 'folders/' are provided.
	Note: Either set 'gzip: folders', or remove directories from the 'files:' list.

Try:
	uses: $PKG
	with:
	  ...
	  gzip: folders
	  files: >
	    README.md
	    my-artifacts/" 'invalid' 'gzip and folders combination'

		# Don't compress files, if gzip not enabled for everything
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


# Overriding assets requires deleting them first, which in turn requires their ID.
#   So, when override is enabled fetch all, and format into a name->id map.
#       docs: https://developer.github.com/v3/repos/releases/#list-assets-for-a-release
current_assets=
[ "$INPUT_ALLOW_OVERRIDE" = "true" ] && \
	current_assets="$(gh_release_api "$release_id/assets" | jq -r 'map({ (.name): .id }) | add')"


upload_url="$(echo "$releases_url" | sed -e 's|api|uploads|')"

for asset in "$assets"/*; do
	file_name="$(basename "$asset")"

	# Delete already existing asset, if collides with one to-be-uploaded.
	if [ -n "$current_assets" ]; then
		asset_id="$(echo "$current_assets" | jq ".\"$file_name\"")"

		# docs: https://developer.github.com/v3/repos/releases/#delete-a-release-asset
		[ -n "$asset_id" ] && \
			gh_release_api "assets/$asset_id" DELETE
	fi

	# docs: https://developer.github.com/v3/repos/releases/#upload-a-release-asset
	status_code="$(curl -sS  -X POST \
		--write-out "%{http_code}"  -o "$TMP/$file_name.json" \
		-H "Authorization: token $TOKEN" \
		-H "Content-Length: $(stat -c %s "$asset")" \
		-H "Content-Type: $(file -b --mime-type "$asset")" \
		--upload-file "$asset" \
		"$upload_url/$release_id/assets?name=$file_name")"

	[ "$status_code" -ne "201" ] && panic "Failed asset upload: $file_name" \
		'api' "failed to upload asset: $file_name" \
		"$TMP/$file_name.json"
done

echo "::endgroup::"


#
## Finalize Release
#
[ -n "$INPUT_DRAFT" ] && \
	all_done 'Draft status already correct.'

echo "::group::Complete Release"

# docs: https://developer.github.com/v3/repos/releases/#edit-a-release
status_code="$(curl -sS  -X PATCH  -d '{"draft": false}' \
  --write-out "%{http_code}"  -o "$TMP/publish.json" \
  -H "Authorization: token $TOKEN" \
  -H "Content-Type: application/json" \
  "$releases_url/$release_id")"

[ "$status_code" != "200" ] && panic "Final publishing of the ready Github Release has failed" \
	'api' "failed to finalize release" \
	"$TMP/publish.json"

echo "::endgroup::"

all_done
