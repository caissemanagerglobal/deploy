#!/bin/bash

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

if [[ "$node_version" == "v18.20.2" && "$npm_version" == "10.5.0" ]]; then
    echo "Node.js and npm installed successfully: Node.js $node_version, npm $npm_version"
else
    echo "Failed to install the required Node.js or npm version."
    exit 1
fi

echo "Enter your UUID:"
read UUID

MAC_ADDRESS=$(ip link show | awk '/ether/ {print $2; exit}')

response=$(curl -s -w "%{http_code}" -o /tmp/cm.zip -X POST https://erp.caisse-manager.ma/deploy -H "Content-Type: application/json" -d '{"uuid": "'$UUID'", "mac_address": "'$MAC_ADDRESS'"}')

if [ "$response" -eq 200 ]; then
    echo "Token validated and file downloaded successfully."
else
    echo "Invalid token or error downloading file. Response code: $response"
    exit 1
fi

unzip /tmp/cm.zip -d /tmp/deploy_files

CM_FRONT_DIR="/var/www/cm_front"
CM_KDS_DIR="/var/www/cm_kds"
CM_ODOO_DIR="/root/cm_odoo"
sudo ufw allow 3000
sudo ufw allow 3001
sudo ufw allow 8089

sudo mkdir -p $CM_FRONT_DIR $CM_KDS_DIR $CM_ODOO_DIR

cd /tmp/deploy_files/cm/cm_pos
npm install
npm run build
sudo cp -r build/* $CM_FRONT_DIR/

cd /tmp/deploy_files/cm/cm_kds
npm install
npm run build
sudo cp -r build/* $CM_KDS_DIR/

sudo cp -r /tmp/deploy_files/cm/cm_odoo/* $CM_ODOO_DIR/

EXPIRATION_DATE=$(date -d "+6 months" +%Y-%m-%d)

cat <<EOL > $CM_ODOO_DIR/.env
UUID=$UUID
EXPIRATION_DATE=$EXPIRATION_DATE
EOL

cat <<EOL > $CM_ODOO_DIR/docker-compose.yml
version: '2'
services:
  db:
    image: postgres:16
    user: root
    environment:
      - POSTGRES_USER=odoo
      - POSTGRES_PASSWORD=odoo17@2023
      - POSTGRES_DB=postgres
    restart: always
    volumes:
      - ./postgresql:/var/lib/postgresql/data

  odoo17:
    image: odoo:17
    user: root
    depends_on:
      - db
    ports:
      - "8089:8069"
      - "2029:8072"
    tty: true
    command: --
    environment:
      - HOST=db
      - USER=odoo
      - PASSWORD=odoo17@2023
      - ed_odoo=\${EXPIRATION_DATE}
      - uuid=\${UUID}
    volumes:
      - ./entrypoint.sh:/entrypoint.sh
      - ./addons/cm_backend:/mnt/extra-addons
      - ./etc:/etc/odoo
      - ./enterprise:/mnt/enterprise
    restart: always
EOL

sudo apt-get update
sudo apt-get install -y nginx

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

sudo apt-get install -y docker.io docker-compose
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
