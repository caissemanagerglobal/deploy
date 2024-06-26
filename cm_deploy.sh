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

# Get UUID from user input
echo "Enter your UUID:"
read UUID

# Get MAC address of the first network interface
MAC_ADDRESS=$(ip link show | awk '/ether/ {print $2; exit}')

# Send the token to the Odoo API and download the zip file
response=$(curl -s -w "%{http_code}" -o /tmp/cm.zip -X POST https://erp.caisse-manager.ma/deploy -H "Content-Type: application/json" -d '{"uuid": "'$UUID'", "mac_address": "'$MAC_ADDRESS'"}')

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
mkdir /root/cm_odoo
CM_FRONT_DIR="/var/www/cm_front"
CM_KDS_DIR="/var/www/cm_kds"
CM_ODOO_DIR="/root/cm_odoo"
ufw allow 3000
ufw allow 3001
ufw allow 8089

# Create directories
sudo mkdir -p $CM_FRONT_DIR $CM_KDS_DIR

# Copy the code to the appropriate directories
sudo cp -r /tmp/deploy_files/cm/cm_front/* $CM_FRONT_DIR/
sudo cp -r /tmp/deploy_files/cm/cm_kds/* $CM_KDS_DIR/
sudo cp -r /tmp/deploy_files/cm/cm_odoo/* /root/cm_odoo/

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

# Create a systemd service for ss.py
SERVICE_FILE="/etc/systemd/system/ss.service"

cat <<EOL | sudo tee $SERVICE_FILE
[Unit]
Description=Run ss.py as a service
After=network.target

[Service]
ExecStart=/usr/bin/python3 /root/cm_odoo/addons/cm_backend/cm_front_integration/addons/ss.py
WorkingDirectory=/root/cm_odoo/addons/cm_backend/cm_front_integration/addons
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOL

# Reload systemd and enable the service
sudo systemctl daemon-reload
sudo systemctl enable ss.service
sudo systemctl start ss.service
