# download-docker-image

## Introduction

It allows you to download a docker image in a loadable tar-format, but **without** using `docker pull`, and only relies on bash and some other CLI tools.

## Requirements

- Bash 3+
- curl, jq, awk, sha256sum, cut, tr

## Usage

```
Usage: download-docker-image.sh <options> image[:tag][@digest] ...
  options:
      -d|--tmpdir <directory>     Temporary directory. Defaults to /tmp/docker_pull.XXXX
      -o|--output <file>          Write downloaded images as tar to <file>. Defaults to ./out.tar.
      -O|--stdout                 Write downloaded images as tar to stdout
      -l|--load                   Automatically use docker load in download. Disables output file.
      -k|--keep-tmpdir            Keep temporary directory, do not create tar file
      -I|--insecure               Use http instead of https protocol when not using official registry
      -p|--progress               Show download progress bar
      -q|--quiet                  Only minimal output
      -a|--auth-file <file>       Credentials for non-public registry images. Defaults to ~/.docker/config.json
      -A|--auth-env <varname>     Environment variable name holding the base64 encoded user:pass.
      -c|--credentials <creds>    The base64 encoded user:pass. NOT RECOMMENDED! MAY LEAK!
      --force                     Overwrite output file if it exists

 Note:
  - If [:tag] is omitted it defaults to :latest. Please use explicit tags where possible.
  - use http_proxy and https_proxy variables to download behind firewall. See your curl's man page
  - load and output as tar requires tar binary present in path
  - load requires docker binary present in path
  - Required binaries: curl, jq, awk, sha256sum, cut, tr (must be present in PATH or CWD)
  - Precendence of auth: --credentials, --auth-env, --auth-file, defaults.

```

## Origin

The Script is Based on the Moby Project's [download-frozen-image-v2.sh](https://github.com/moby/moby/blob/3cf82748dd5b31294fc2a303d98ced5a962f3f00/contrib/download-frozen-image-v2.sh), but was heavily modified and some parts removed.

## Licensing

The Script is licensed under the Apache License like it's original version was, Version 2.0. See LICENSE for the full license text.
