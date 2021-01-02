# download-docker-image

## Introduction

It allows you to download a docker image in a loadable tar-format, but **without** using `docker pull`, and only relies on bash and some other CLI tools.

**Note**: I personally switched over to [Skopeo](https://github.com/containers/skopeo) because it provides much more features and is a static compiled binary, which is exactly what I needed. I left this bash script here for the public as an example on how to interact programmatically (in a hacky way) with a Container Registry, but do not plan to proactively maintain it in the future if there are changes to the Registry API.

## Requirements

- Bash 3+
- curl, jq, awk, sha256sum, cut, tr (+some other small trivial cmds) 

## Usage

```
Usage: download-docker-image.sh <options> image[:tag][@digest] ...
  options:
      -d|--dir <directory>        Output directory. Defaults to /tmp/docker_pull.XXXX
      -o|--output <file>          Write downloaded images as tar to <file>.
      -O|--stdout                 Write downloaded images as tar to stdout
      -l|--load                   Automatically use docker load afterwards. Disables output file.
      -I|--insecure               Use http instead of https protocol when not using official registry
      -p|--progress               Show additional download progress bar of curl.
      -q|--quiet                  Only output warnings and errors.
      -a|--auth                   Use authentication for accessing the registry.
                file:<file>       Credential store file for non-public registry images. Default: ~/.docker/config.json
                env:<varname>     Environment variable name holding the base64 encoded user:pass.
                <b64creds>        The base64 encoded version of 'user:pass'. NOT RECOMMENDED! MAY LEAK!
      -A|--no-auth                Do not use any form of authentication. Disables any --auth option.
      -D|--debug                  Debug output. If used twice, sensitive information might be displayed!
      -c|--color                  Force color even if not on tty
      -C|--no-color               No color output. Will be disabled if no tty is detected on stdout
      -r|--architecture <arch>    Architecture to download. Tries to be auto-detect according current arch...
      --force                     Overwrite --output <file> if it already exists. Default is to abort with error.

 Note:
  - Each option must be specified on it's own, like -D -D
  - You cannot mix secure and insecure registries.
  - The credentials must be a base64-encoded version of username:password like used in HTTP Basic Auth
  - Use http_proxy and https_proxy variables to download behind firewall. See your curl's man page
  - Required binaries (must be present in PATH or CWD): curl jq awk sha256sum uname
  - The --load and --output options require the 'tar' binary present in PATH
  - The --load option requires the 'docker' binary present in PATH
  - Output directory will be removed unless specified with --dir
  - Authentication has precedence if used multiple times: creds -> env -> file. Default file will be used if not defined otherwise.

```

## Origin

The Script is Based on the Moby Project's [download-frozen-image-v2.sh](https://github.com/moby/moby/blob/3cf82748dd5b31294fc2a303d98ced5a962f3f00/contrib/download-frozen-image-v2.sh), but was heavily modified and some parts removed.

## Licensing

The Script is licensed under the Apache License like it's original version was, Version 2.0. See LICENSE for the full license text.
