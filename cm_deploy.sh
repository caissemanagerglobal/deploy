#!/bin/bash

# Check if curl and unzip are installed
if ! command -v curl &> /dev/null; then
    echo "curl could not be found, installing..."
    sudo apt-get update
    sudo apt-get install -y curl
fi

if ! command -v unzip &> /dev/null; then
    echo "unzip could not be found, installing..."
    sudo apt-get update
    sudo apt-get install -y unzip
fi

echo "Enter your deployment token:"
read TOKEN

# Replace UUID and MAC_ADDRESS with the actual values
UUID="your_uuid"
MAC_ADDRESS="your_mac_address"

# Send the token to the Odoo API and download the zip file
response=$(curl -s -w "%{http_code}" -o /tmp/cm.zip -X POST http://your_odoo_server/deploy -H "Content-Type: application/json" -d '{"uuid": "'$UUID'", "mac_address": "'$MAC_ADDRESS'"}')

if [ "$response" -eq 200 ]; then
    echo "Token validated and file downloaded successfully."
else
    echo "Invalid token or error downloading file. Response code: $response"
    exit 1
fi

# Extract the zip file
unzip /tmp/cm.zip -d /tmp/deploy_files

# Continue with the rest of the deployment
# Define directories
CM_FRONT_DIR="/var/www/cm_front"
CM_KDS_DIR="/var/www/cm_kds"
CM_ODOO_DIR="/root/cm_odoo"

# Create directories
sudo mkdir -p $CM_FRONT_DIR $CM_KDS_DIR

# Copy the code to the appropriate directories
sudo cp -r /tmp/deploy_files/cm_front/* $CM_FRONT_DIR/
sudo cp -r /tmp/deploy_files/cm_kds/* $CM_KDS_DIR/
sudo cp -r /tmp/deploy_files/cm_odoo/* /root/cm_odoo/

# Install Nginx
sudo apt-get update
sudo apt-get install -y nginx

# Configure Nginx
cat <<EOL | sudo tee /etc/nginx/sites-enabled/odoo
server {
    listen 3000;
    server_name localhost;

    root /var/www/cm_front;
    index index.html index.htm;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
server {
    listen 3001;
    server_name localhost;

    root /var/www/cm_kds;
    index index.html index.htm;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOL

# Restart Nginx
sudo systemctl restart nginx

# Install Docker and Docker Compose
sudo apt-get install -y docker.io docker-compose

# Run Docker Compose
cd $CM_ODOO_DIR
sudo docker-compose up -d
