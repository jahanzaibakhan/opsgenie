#!/bin/bash

set -e

echo "========== Updating System =========="
sudo apt update && sudo apt upgrade -y

echo "========== Installing NGINX =========="
sudo apt install nginx -y
sudo systemctl enable nginx
sudo systemctl start nginx

echo "========== Installing MySQL =========="
sudo apt install mysql-server -y
sudo systemctl enable mysql
sudo systemctl start mysql

echo "========== Securing MySQL =========="
sudo mysql_secure_installation

echo "========== Installing PHP and Extensions =========="
sudo apt install php-fpm php-mysql php-curl php-gd php-mbstring php-xml php-xmlrpc php-zip php-soap php-intl unzip -y

echo "========== Creating MySQL Database and User =========="
DB_NAME="wordpress"
DB_USER="wpuser"
DB_PASS="wppassword"

sudo mysql -u root <<EOF
CREATE DATABASE ${DB_NAME} DEFAULT CHARACTER SET utf8 COLLATE utf8_unicode_ci;
CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

echo "========== Downloading WordPress =========="
cd /tmp
wget https://wordpress.org/latest.tar.gz
tar -xvzf latest.tar.gz
sudo rm -rf /var/www/html/*
sudo mv wordpress/* /var/www/html/

echo "========== Setting Permissions =========="
sudo chown -R www-data:www-data /var/www/html/
sudo find /var/www/html/ -type d -exec chmod 755 {} \;
sudo find /var/www/html/ -type f -exec chmod 644 {} \;

echo "========== Configuring WordPress =========="
cd /var/www/html
cp wp-config-sample.php wp-config.php
sed -i "s/database_name_here/${DB_NAME}/" wp-config.php
sed -i "s/username_here/${DB_USER}/" wp-config.php
sed -i "s/password_here/${DB_PASS}/" wp-config.php

echo "========== Creating NGINX Virtual Host =========="
cat <<EOF | sudo tee /etc/nginx/sites-available/wordpress
server {
    listen 80;
    server_name _;
    root /var/www/html;
    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')-fpm.sock;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

sudo ln -s /etc/nginx/sites-available/wordpress /etc/nginx/sites-enabled/
sudo rm /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx

echo "========== Installation Complete =========="
echo "Visit your server IP in a browser to finish WordPress setup."
