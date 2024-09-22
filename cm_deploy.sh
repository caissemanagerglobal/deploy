#!/bin/bash

set -e

# Ensure the script is run with sudo
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root"
    exit 1
fi

# Ensure the script is called with the correct number of arguments
if [ "$#" -ne 2 ]; then
    exit 1
fi

# Assign arguments to variables
HOST_IP_ADDRESS=$1
KEY=$2

install_if_not_exists() {
    local package=$1
    if ! command -v $package &> /dev/null; then
        echo "$package could not be found, installing..."
        apt-get update
        apt-get install -y $package
    fi
}

# Install necessary packages
install_if_not_exists curl
install_if_not_exists unzip
install_if_not_exists docker
install_if_not_exists docker-compose

# Get the MAC address of the first network interface
MAC_ADDRESS=$(ip addr show | awk '/ether/ {print $2; exit}')

# Fetch the deployment file from the server
response_headers=$(mktemp)
response_body=$(mktemp)
curl -s -D "$response_headers" -o "$response_body" -X POST http://erp.caisse-manager.ma/deploy/new -H "Content-Type: application/json" -d '{"key": "'$KEY'"}'

http_code=$(awk 'NR==1{print $2}' "$response_headers")

if [ "$http_code" -ne 200 ]; then
    echo "Invalid key or error downloading file. Response code: $http_code"
    exit 1
fi

# Unzip the deployment file
if ! unzip "$response_body" -d /tmp/deploy_files; then
    echo "Error extracting /tmp/cm.zip. Exiting."
    rm -f "$response_body"
    exit 1
fi

CM_DJANGO_DIR="/tmp/deploy_files/cm_django_backend"
CM_FRONT_DIR="/tmp/deploy_files/cm_front"
CM_PREP_DIR="/tmp/deploy_files/cm_preparation_display"
CM_BACKOFFICE_DIR="/tmp/deploy_files/cm_backoffice"

# Replace HOST_IP_ADDRESS_var in cm_django_backend/docker-compose.yml with the provided IP
sed -i "s/HOST_IP_ADDRESS_var/$HOST_IP_ADDRESS/g" "$CM_DJANGO_DIR/docker-compose.yml"

# Start Docker services for each directory
docker_compose_up() {
    local dir=$1
    if [ -f "$dir/docker-compose.yml" ]; then
        echo "Running docker-compose in $dir..."
        cd "$dir"
        docker-compose up -d
    else
        echo "docker-compose.yml not found in $dir"
    fi
}

# Run docker-compose for each component
docker_compose_up $CM_DJANGO_DIR
docker_compose_up $CM_FRONT_DIR
docker_compose_up $CM_PREP_DIR
docker_compose_up $CM_BACKOFFICE_DIR

# Clean up temporary files
rm -r /tmp/deploy_files
rm "$response_body"
rm "$response_headers"

echo "Deployment completed successfully."
