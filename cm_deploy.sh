#!/bin/bash

# Ensure the script is run with sudo

# Ensure the script is called with the correct number of arguments
if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <UUID> <API_IP> <EXPIRATION_DATE>"
    exit 1
fi

# Assign arguments to variables
UUID=$1
API_IP=$2
EXPIRATION_DATE=$3

install_if_not_exists() {
    local package=$1
    if ! command -v $package &> /dev/null; then
        echo "$package could not be found, installing..."
        sudo apt-get update
        sudo apt-get install -y $package
    fi
}

install_if_not_exists curl
install_if_not_exists unzip

echo "Installing Node.js v18.20.2 and npm 10.5.0..."
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt-get install -y nodejs

node_version=$(node -v)
npm_version=$(npm -v)

# Get MAC address of the first network interface
MAC_ADDRESS=$(ip addr show | awk '/ether/ {print $2; exit}')

response=$(curl -s -w "%{http_code}" -o /tmp/cm.zip -X POST https://erp.caisse-manager.ma/deploy -H "Content-Type: application/json" -d '{"uuid": "'$UUID'", "mac_address": "'$MAC_ADDRESS'"}')

if [ "$response" -ne 200 ]; then
    echo "Invalid token or error downloading file. Response code: $response"
    exit 1
fi

# Unzip the downloaded file
if ! unzip /tmp/cm.zip -d /tmp/deploy_files; then
    echo "Error extracting /tmp/cm.zip. Exiting."
    rm -f /tmp/cm.zip
    exit 1
fi

CM_FRONT_DIR="/var/www/cm_front"
CM_KDS_DIR="/var/www/cm_kds"
CM_ODOO_DIR="/root/cm_odoo"
sudo ufw allow 3000
sudo ufw allow 3001
sudo ufw allow 8089

sudo mkdir -p $CM_FRONT_DIR $CM_KDS_DIR $CM_ODOO_DIR

# Create .env file for React apps
cat <<EOL > /tmp/deploy_files/cm/cm_pos/.env
REACT_APP_API_URL=http://$API_IP:8089
REACT_APP_SOCKET_URL=http://$API_IP:5010
EOL

cat <<EOL > /tmp/deploy_files/cm/cm_kds/.env
REACT_APP_API_URL=http://$API_IP:8089
REACT_APP_SOCKET_URL=http://$API_IP:5010
EOL

cd /tmp/deploy_files/cm/cm_pos
npm install
npm run build
sudo cp -r build/* $CM_FRONT_DIR/

cd /tmp/deploy_files/cm/cm_kds
npm install
npm run build
sudo cp -r build/* $CM_KDS_DIR/

sudo cp -r /tmp/deploy_files/cm/cm_odoo/* $CM_ODOO_DIR/

cat <<EOL > $CM_ODOO_DIR/.env
UUID=$UUID
EXPIRATION_DATE=$EXPIRATION_DATE
EOL

cd 
# Replace placeholders in docker-compose.yml
sed -i "s/ed_odoo_code/$EXPIRATION_DATE/g" $CM_ODOO_DIR/docker-compose.yml
sed -i "s/uuid_code/$UUID/g" $CM_ODOO_DIR/docker-compose.yml
sed -i "s/mac_address_code/$MAC_ADDRESS/g" $CM_ODOO_DIR/docker-compose.yml

sudo apt-get update
sudo apt-get install -y nginx python3-pip python3-setuptools

# Install Docker Compose V2
DOCKER_COMPOSE_VERSION="v2.3.3"
sudo curl -SL "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-linux-x86_64" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
sudo ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose

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

sudo systemctl restart nginx

sudo apt-get install -y docker.io
sudo chmod +x /root/cm_odoo/entrypoint.sh

cd $CM_ODOO_DIR
sudo docker-compose up -d

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

sudo systemctl daemon-reload
sudo systemctl enable ss.service
sudo systemctl start ss.service

rm -r /tmp/deploy_files
rm /tmp/cm.zip

# Verify replacements in docker-compose.yml
echo "Final docker-compose.yml:"
cat $CM_ODOO_DIR/docker-compose.yml

fi # End of sudo check
