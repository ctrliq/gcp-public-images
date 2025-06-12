#!/bin/bash

if [ -e /usr/bin/podman ]; then
    PODMAN=/usr/bin/podman
else
    PODMAN=/usr/bin/docker
fi

# Check for --host-gauth-json flag for location of JSON auth file on host
if [[ "$@" == *"--host-gauth-json"* ]]; then
    HOST_GAUTH_JSON=$(echo "$@" | grep -oP '(?<=--host-gauth-json\s)\S+')
    if [ -z "$HOST_GAUTH_JSON" ]; then
        echo "Error: --host-gauth-json flag requires a file path."
        exit 1
    fi
    # Remove the flag from $@
    set -- $(echo "$@" | sed "s|--host-gauth-json\s\+$HOST_GAUTH_JSON||")
    echo "$@"
else
    # Show error
    echo "Error: --host-gauth-json flag is required to specify the location of the JSON auth file on the host."
    exit 1
fi
$PODMAN build -t daisy -f automation/Containerfile .
if [ $? -ne 0 ]; then
    echo "Failed to build the Docker image."
    exit 1
fi

$PODMAN run --rm -it \
    -v "$HOST_GAUTH_JSON":/creds.json:Z \
    daisy \
    "$@"
