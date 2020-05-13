#!/usr/bin/env bash

## Origin: https://raw.githubusercontent.com/moby/moby/master/contrib/download-frozen-image-v2.sh

set -eo pipefail

# check if essential commands are in our PATH
# We extend our path to include local directory to ease jq finding.
export PATH=$PATH:.

for cmd in curl jq awk sha256sum cut tr; do
    if ! command -v $cmd &> /dev/null; then
        echo >&2 "* Error: \"$cmd\" not found!"
        exit 1
    fi
done

usage() {
    echo ""
    echo "Usage: $0 <options> image[:tag][@digest] ..."
    echo "  options:"
    echo "      -d|--tmpdir <directory>     Temporary directory. Defaults to /tmp/docker_pull.XXXX"
    echo "      -o|--output <file>          Write downloaded images as tar to <file>. Defaults to ./out.tar."
    echo "      -O|--stdout                 Write downloaded images as tar to stdout"
    echo "      -l|--load                   Automatically use docker load in download. Disables output file."
    echo "      -k|--keep-tmpdir            Keep temporary directory, do not create tar file"
    echo "      -I|--insecure               Use http instead of https protocol when not using official registry"
    echo "      -p|--progress               Show download progress bar"
    echo "      -q|--quiet                  Only minimal output"
    echo "      --force                     Overwrite output file if it exists"
    echo ""
    echo " Note: "
    echo "  - use http_proxy and https_proxy variables to download behind firewall. See your curl's man page"
    echo "  - load and output as tar requires tar binary present in path"
    echo "  - load requires docker binary present in path"
    echo "  - Required binaries: curl, jq, awk, sha256sum, cut, tr (must be present in PATH or CWD)"
    echo ""
    [ -z "$1" ] || exit "$1"
}

PROGRESS="-s"
QUIET=0
LOAD=0
KEEP=0
STDOUT=0
FORCE=0
protocol='https'
dir="/tmp/docker_pull.$$.$RANDOM"
ARGS=()
DESTFILE="./out.tar"

while [[ -n $1 ]]; do
    case $1 in
        -o|--output)        DESTFILE="$2"; STDOUT=0; shift ;;
        -O|--stdout)        DESTFILE="";   STDOUT=1; LOAD=0;;
        -l|--load)          DESTFILE="";   STDOUT=0; LOAD=1;;
        -I|--insecure)      protocol='http' ;;
        -d|--tmpdir)        dir="$2"; shift ;;
        -k|--keep-tmpdir)   KEEP=1;;
        -p|--progress)      QUIET=0 ; PROGRESS="--progress-bar";;
        -q|--quiet)         QUIET=1 ; PROGRESS="-s";;
        --force)            FORCE=1;;
        -*)
            echo "* Error: Unknown option: $1" >&2
            exit 255
            ;;
        *) ARGS+=( "$1" );;
    esac
    shift;
done

if [[ ${#ARGS[@]} -eq 0 ]]; then
    usage 255
fi

if [[ $FORCE -eq 0 && $DESTFILE != "" && -e $DESTFILE ]]; then
    echo "* Error: output file $DESTFILE already exists and not using --force" >&2
    exit 255
fi

if ((LOAD==1)); then
    if ! command -v docker &> /dev/null; then
        echo "* Error: docker command not in path" >&2
        exit 255
    fi
fi

if ((KEEP==0)); then
    trap 'rm -rf "$dir"' EXIT QUIT INT
else
    echo "* Info: Output will be kept at: $dir" >&2
fi

if ! [[ -d $dir ]]; then
    mkdir -p "$dir"
fi

# hacky workarounds for Bash 3 support (no associative arrays)
images=()
rm -f "$dir"/tags-*.tmp
manifestJsonEntries=()
doNotGenerateManifestJson=
# repositories[busybox]='"latest": "...", "ubuntu-14.04": "..."'

newlineIFS=$'\n'

registryBase='https://registry-1.docker.io'

# https://github.com/moby/moby/issues/33700
fetch_blob() {
    local token="$1"
    shift
    local image="$1"
    shift
    local digest="$1"
    shift
    local targetFile="$1"
    shift

    curl -fSL $PROGRESS \
        ${token:+ -H "Authorization: Bearer $token"} \
        "$registryBase/v2/$image/blobs/$digest" \
        -o "$targetFile"

    if ! [[ -s "$targetFile" ]]; then
        echo "* Error: Failed to fetch URL '$registryBase/v2/$image/blobs/$digest'" >&2
        exit 1
    fi
}

fssize() {
    local file="$1" timing="$2"
    stat -c %s "$file" | awk -v TIME="$timing" '
        function format_size(size, x, f) {
            f[1024^3]="GiB";
            f[1024^2]="MiB";
            f[1024^1]="KiB";
            f[1024^0]="bytes";

            for (x=1024^3; x>=1; x/=1024) {
                if (size >= x) {
                    return sprintf("%.1f %s", size/x, f[x]);
                }
            }
        }
        function format_time(sec, x, fullpart, subpart, f) {
            if (sec<0) {
                return;
            }
            f[60^2] = "h";
            f[60^1] = "m";
            f[60^0] = "s";
            if (sec==0) {
                return "one instant";
            }
            for (x=60^3; x>=1; x/=60) {
                if (sec >= x) {
                    fullpart = int(sec/x);
                    subpart = sec - ( fullpart * x );
                    if (subpart == 0) {
                        return sprintf("%s%s", fullpart, f[x] );
                    } else {
                        return sprintf("%s%s %s", fullpart, f[x], format_time(subpart) );
                    }
                    break;
                }
            }
        }
        { printf "%s/%s\n", format_size($0), format_time(TIME); }
    '
}

# handle 'application/vnd.docker.distribution.manifest.v2+json' manifest
handle_single_manifest_v2() {
    local manifestJson="$1"
    shift
    local token="$1"
    shift;

    local configDigest="$(echo "$manifestJson" | jq --raw-output '.config.digest')"
    local imageId="${configDigest#*:}" # strip off "sha256:"

    local configFile="$imageId.json"
    ((QUIET)) || echo "Downloading image '$imageIdentifier'..." 
    T0=$SECONDS
    fetch_blob "$token" "$image" "$configDigest" "$dir/$configFile"
    T1=$SECONDS
    ((QUIET)) || echo  " - Manifest '$imageId': $( fssize "$dir/$configFile" $((T1-T0)) )"

    local layersFs="$(echo "$manifestJson" | jq --raw-output --compact-output '.layers[]')"
    local IFS="$newlineIFS"
    local layers=($layersFs)
    unset IFS

    local layerCount="${#layers[@]}"
    ((QUIET)) || echo " - Downloading '$imageIdentifier' (${layerCount} layers)..."
    local layerId=
    local layerFiles=()
    for i in "${!layers[@]}"; do
        local layerMeta="${layers[$i]}"

        local layerMediaType="$(echo "$layerMeta" | jq --raw-output '.mediaType')"
        local layerDigest="$(echo "$layerMeta" | jq --raw-output '.digest')"

        # save the previous layer's ID
        local parentId="$layerId"
        # create a new fake layer ID based on this layer's digest and the previous layer's fake ID
        layerId="$(echo "$parentId"$'\n'"$layerDigest" | sha256sum | cut -d' ' -f1)"
        # this accounts for the possibility that an image contains the same layer twice (and thus has a duplicate digest value)

        mkdir -p "$dir/$layerId"
        echo '1.0' > "$dir/$layerId/VERSION"

        if [ ! -s "$dir/$layerId/json" ]; then
            local parentJson="$(printf ', parent: "%s"' "$parentId")"
            local addJson="$(printf '{ id: "%s"%s }' "$layerId" "${parentId:+$parentJson}")"
            # this starter JSON is taken directly from Docker's own "docker save" output for unimportant layers
            jq "$addJson + ." > "$dir/$layerId/json" <<'EOJSON'
                {
                    "created": "0001-01-01T00:00:00Z",
                    "container_config": {
                        "Hostname": "",
                        "Domainname": "",
                        "User": "",
                        "AttachStdin": false,
                        "AttachStdout": false,
                        "AttachStderr": false,
                        "Tty": false,
                        "OpenStdin": false,
                        "StdinOnce": false,
                        "Env": null,
                        "Cmd": null,
                        "Image": "",
                        "Volumes": null,
                        "WorkingDir": "",
                        "Entrypoint": null,
                        "OnBuild": null,
                        "Labels": null
                    }
                }
EOJSON
        fi

        case "$layerMediaType" in
            application/vnd.docker.image.rootfs.diff.tar.gzip)
                local layerTar="$layerId/layer.tar"
                layerFiles+=("$layerTar")
                # TODO figure out why "-C -" doesn't work here
                # "curl: (33) HTTP server doesn't seem to support byte ranges. Cannot resume."
                # "HTTP/1.1 416 Requested Range Not Satisfiable"
                if [ -f "$dir/$layerTar" ]; then
                    # TODO hackpatch for no -C support :'(
                    ((QUIET)) || echo "skipping existing ${layerId:0:12}"
                    continue
                fi
                T0=$SECONDS
                fetch_blob "$token" "$image" "$layerDigest" "$dir/$layerTar"
                T1=$SECONDS
                ((QUIET)) || printf "   [%02d/%02d] %s: %s\n" "$((i+1))" "$layerCount" "$layerDigest" "$( fssize "$dir/$layerTar" $((T1-T0)) )"
                ;;

            *)
                echo >&2 "* Error: unknown layer mediaType ($imageIdentifier, $layerDigest): '$layerMediaType'"
                exit 1
                ;;
        esac
    done

    # change "$imageId" to be the ID of the last layer we added (needed for old-style "repositories" file which is created later -- specifically for older Docker daemons)
    imageId="$layerId"

    # munge the top layer image manifest to have the appropriate image configuration for older daemons
    local imageOldConfig="$(jq --raw-output --compact-output '{ id: .id } + if .parent then { parent: .parent } else {} end' "$dir/$imageId/json")"
    jq --raw-output "$imageOldConfig + del(.history, .rootfs)" "$dir/$configFile" > "$dir/$imageId/json"

    local manifestJsonEntry="$(
        echo '{}' | jq --raw-output '. + {
            Config: "'"$configFile"'",
            RepoTags: ["'"${image#library\/}:$tag"'"],
            Layers: '"$(echo '[]' | jq --raw-output ".$(for layerFile in "${layerFiles[@]}"; do echo " + [ \"$layerFile\" ]"; done)")"'
        }'
    )"
    manifestJsonEntries=("${manifestJsonEntries[@]}" "$manifestJsonEntry")
}

for ind in "${!ARGS[@]}"; do
    image="${ARGS[$ind]}"
    ## Bash regex matching with capture groups
    ## BASH_REMATCH        2             4     5      7      9
    ##              image='registry.fqdn/group/sles15:latest@sha256:checksum'
    if ! [[ "$image" =~ ^(([^/]+)/)?(([^/]+)/)?([^:@]+)(:([^@]+))?(@(.+))?$ ]]; then
        echo "skipping malformatted image: $image"
        continue
    fi
    if [[ -n "${BASH_REMATCH[2]}" ]]; then
        registryBase="${protocol}://${BASH_REMATCH[2]}"
    fi
    if [[ -z "${BASH_REMATCH[4]}" ]]; then
        # add prefix library if passed official image
        image="library/${BASH_REMATCH[5]}"
    else
        image="${BASH_REMATCH[4]}/${BASH_REMATCH[5]}"
    fi
    tag="${BASH_REMATCH[7]}"
    if [[ -z $tag ]]; then
        tag='latest'
    fi
    digest="${BASH_REMATCH[9]}"
    if [[ -z $digest ]]; then
        reference="$tag"
    else
        reference="$digest"
    fi

    imageFile="$( tr '/' '_' <<<"${image}")" # "/" can't be in filenames :)

    ## Details for registry auth via bearer token:
    ##   https://docs.docker.com/registry/spec/auth/token/

    # Only fetch header so we will receive a 401 Unautorized with the necessary infos 
    rc=0
    auth_hdr="$( curl -sL -X HEAD -I "$registryBase/v2/$image/manifests/$reference" )" || :
    auth_url="$( awk '
            # URLEncode function from: https://rosettacode.org/wiki/URL_encoding#AWK
            BEGIN { for (i = 0; i <= 255; i++) ord[sprintf("%c", i)] = i; IGNORECASE = 1; }

            function escape(str,    c, len, res) {
                len = length(str)
                res = ""
                for (i = 1; i <= len; i++) {
                    c = substr(str, i, 1);
                    if (c ~ /[0-9A-Za-z]/)
                        res = res c
                    else
                        res = res "%" sprintf("%02X", ord[c])
                }
                return res
            }

            /Connection established/ { next; }

            # We did not receive an unauthorized, so no need to get a bearer token?
            $1 ~ "^HTTP/" && $2 != "401" { exit 11; }

            # Not a bearer token auth, we cannot handle this
            $1 == "www-authenticate:" && $2 != "Bearer" { 
                print "* Error: Unknown Authentication schema: " $2 > "/dev/stderr";
                print "  line was: " $0 > "/dev/stderr";
                exit 12; 
            }

            $1 == "www-authenticate:" {
                begin = match($0, /realm="([^"]+)",service="([^"]+)",scope="([^"]+)"/ , result);
                if (begin == 0) {
                    # We did not find the expected matching result headers
                    # TODO: Add better header parsing?
                    print "* Error: Could not parse header! " > "/dev/stderr";
                    print "  line was: " $0 > "/dev/stderr";
                    exit 13;
                }
                printf "%s?service=%s&scope=%s\n", result[1], escape(result[2]), result[3];
                exit 10;
            }
        ' <<<"$auth_hdr" )" || rc=$?;
    token=''
    case $rc in
        10)
            token="$(curl -fsSL "$auth_url" | jq --raw-output 'if .token != null  then .token elif .access_token != null then .access_token else . end ')"
            ;;
        12|13)
            exit 1
            ;;
        11) ;;
        *)
            echo >&2 "* Error: Unknown error during authentication: $rc"
            exit 1
            ;;
    esac
    manifestJson="$(
        curl -fsSL \
            ${token:+ -H "Authorization: Bearer $token"} \
            -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
            -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
            -H 'Accept: application/vnd.docker.distribution.manifest.v1+json' \
            "$registryBase/v2/$image/manifests/$reference"
    )"
    if [ "${manifestJson:0:1}" != '{' ]; then
        echo >&2 "* Error: /v2/$image/manifests/$reference returned something unexpected:"
        echo >&2 "  $manifestJson"
        exit 1
    fi

    imageIdentifier="$image:$tag${digest:+@$digest}"

    schemaVersion="$(echo "$manifestJson" | jq --raw-output '.schemaVersion')"
    case "$schemaVersion" in
        2)
            mediaType="$(echo "$manifestJson" | jq --raw-output '.mediaType')"

            case "$mediaType" in
                application/vnd.docker.distribution.manifest.v2+json)
                    handle_single_manifest_v2 "$manifestJson" "$token"
                    ;;
                application/vnd.docker.distribution.manifest.list.v2+json)
                    layersFs="$(echo "$manifestJson" | jq --raw-output --compact-output '.manifests[]')"
                    IFS="$newlineIFS"
                    layers=($layersFs)
                    unset IFS

                    found=""
                    # parse first level multi-arch manifest
                    for i in "${!layers[@]}"; do
                        layerMeta="${layers[$i]}"
                        maniArch="$(echo "$layerMeta" | jq --raw-output '.platform.architecture')"
                        if [ "$maniArch" = "amd64" ]; then
                            digest="$(echo "$layerMeta" | jq --raw-output '.digest')"
                            # get second level single manifest
                            submanifestJson="$(
                                curl -fsSL \
                                    ${token:+ -H "Authorization: Bearer $token"} \
                                    -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
                                    -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
                                    -H 'Accept: application/vnd.docker.distribution.manifest.v1+json' \
                                    "$registryBase/v2/$image/manifests/$digest"
                            )"
                            handle_single_manifest_v2 "$submanifestJson" "$token"
                            found="found"
                            break
                        fi
                    done
                    if [ -z "$found" ]; then
                        echo >&2 "* Error: manifest for $maniArch is not found"
                        exit 1
                    fi
                    ;;
                *)
                    echo >&2 "* Error: unknown manifest mediaType ($imageIdentifier): '$mediaType'"
                    exit 1
                    ;;
            esac
            ;;

        1)
            if [ -z "$doNotGenerateManifestJson" ]; then
                echo >&2 "warning: '$imageIdentifier' uses schemaVersion '$schemaVersion'"
                echo >&2 "  this script cannot (currently) recreate the 'image config' to put in a 'manifest.json' (thus any schemaVersion 2+ images will be imported in the old way, and their 'docker history' will suffer)"
                echo >&2
                doNotGenerateManifestJson=1
            fi

            layersFs="$(echo "$manifestJson" | jq --raw-output '.fsLayers | .[] | .blobSum')"
            IFS="$newlineIFS"
            layers=($layersFs)
            unset IFS

            history="$(echo "$manifestJson" | jq '.history | [.[] | .v1Compatibility]')"
            imageId="$(echo "$history" | jq --raw-output '.[0]' | jq --raw-output '.id')"

            local layerCount="${#layers[@]}"
            echo "Downloading '$imageIdentifier' (${layerCount} layers)..."
            for i in "${!layers[@]}"; do
                local layerTar="$layerId/layer.tar"
                imageJson="$(echo "$history" | jq --raw-output ".[${i}]")"
                layerId="$(echo "$imageJson" | jq --raw-output '.id')"
                imageLayer="${layers[$i]}"

                mkdir -p "$dir/$layerId"
                echo '1.0' > "$dir/$layerId/VERSION"

                echo "$imageJson" > "$dir/$layerId/json"

                # TODO figure out why "-C -" doesn't work here
                # "curl: (33) HTTP server doesn't seem to support byte ranges. Cannot resume."
                # "HTTP/1.1 416 Requested Range Not Satisfiable"
                if [ -f "$dir/$layerTar" ]; then
                    # TODO hackpatch for no -C support :'(
                    echo "skipping existing ${layerId:0:12}"
                    continue
                fi
                T0=$SECONDS
                fetch_blob "$token" "$image" "$imageLayer" "$dir/$layerTar"
                T1=$SECONDS
                ((QUIET)) || printf "   [%02d/%02d] %s: %s\n" "$((i+1))" "$layerCount" "$imageLayer" "$( fssize "$dir/$layerTar" $((T1-T0)) )"
            done
            ;;

        *)
            echo >&2 "* Error: unknown manifest schemaVersion ($imageIdentifier): '$schemaVersion'"
            exit 1
            ;;
    esac

    echo

    if [ -s "$dir/tags-$imageFile.tmp" ]; then
        echo -n ', ' >> "$dir/tags-$imageFile.tmp"
    else
        images+=("$image")
    fi
    echo -n '"'"$tag"'": "'"$imageId"'"' >> "$dir/tags-$imageFile.tmp"
done

echo -n '{' > "$dir/repositories"
firstImage=1
for image in "${images[@]}"; do
    imageFile="$( tr '/' '_' <<<"${image}")" # "/" can't be in filenames :)
    image="${image#library\/}"

    [ "$firstImage" ] || echo -n ',' >> "$dir/repositories"
    firstImage=
    echo -n $'\n\t' >> "$dir/repositories"
    echo -n '"'"$image"'": { '"$(cat "$dir/tags-$imageFile.tmp")"' }' >> "$dir/repositories"
done
echo -n $'\n}\n' >> "$dir/repositories"

rm -f "$dir"/tags-*.tmp

if [ -z "$doNotGenerateManifestJson" ] && [ "${#manifestJsonEntries[@]}" -gt 0 ]; then
    echo '[]' | jq --raw-output ".$(for entry in "${manifestJsonEntries[@]}"; do echo " + [ $entry ]"; done)" > "$dir/manifest.json"
else
    rm -f "$dir/manifest.json"
fi

if ((LOAD == 1)); then
    ((QUIET)) || echo "Loading image into docker..."
    tar -cC "$dir" . | docker load $( ((QUIET)) && echo '--quiet' )
    exit $?
fi

if ((STDOUT == 1)); then
    tar -cC "$dir" .
    exit $?
fi

if [[ $DESTFILE != "" ]]; then
    tar -cC "$dir" . -f $DESTFILE
    exit $?
fi
