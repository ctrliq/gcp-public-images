# Compute Image Tools for Rocky Optimized and Accelerated images on GCP

This repository contains the scripts and configuration necessary to build Rocky Linux optimized and accelerated images for Google Cloud Platform (GCP).

## Prerequisites

* A Google Cloud Platform account with billing enabled.
* Podman (or Docker) installed on your local machine.

## Building the Image

1. Clone the repository:
    ```bash
    git clone https://github.com/ctrliq/gcp-public-images.git
    ```

2. Navigate to the directory:
    ```bash
    cd gcp-public-images
    ```

3. Run the daisy script, which will build the image and run it with your commands:
    ```bash
    ./automation/run_daisy.sh --host-gauth-json ~/.config/gcloud/application_default_credentials.json \
        -project <project> \
        -zone <zone (i.e. us-central1-b)> \
        -var:installer_iso=<bucket with installer image> \
        rocky/8/rocky_linux_8_optimized_gcp_nvidia_latest.wf.json
    ```
