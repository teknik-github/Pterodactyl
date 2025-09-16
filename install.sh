#!/bin/bash
# ========================================
# Pterodactyl Installer (Panel + Wings)
# Tested on Ubuntu 22.04+ / Debian 11+
# Run as ROOT
# ========================================

cat <<'EOF'
______ _                     _            _         _   _____          _        _ _           
| ___ \ |                   | |          | |       | | |_   _|        | |      | | |          
| |_/ / |_ ___ _ __ ___   __| | __ _  ___| |_ _   _| |   | | _ __  ___| |_ __ _| | | ___ _ __ 
|  __/| __/ _ \ '__/ _ \ / _` |/ _` |/ __| __| | | | |   | || '_ \/ __| __/ _` | | |/ _ \ '__|
| |   | ||  __/ | | (_) | (_| | (_| | (__| |_| |_| | |  _| || | | \__ \ || (_| | | |  __/ |   
\_|    \__\___|_|  \___/ \__,_|\__,_|\___|\__|\__, |_|  \___/_| |_|___/\__\__,_|_|_|\___|_|   
                                               __/ |                                          
                                              |___/                                           
EOF

# Pastikan dijalankan sebagai root
if [ "$(id -u)" -ne 0 ]; then
    echo "Harus dijalankan sebagai root!"
    exit 1
fi

START_TIME=$(date +%s)

echo "Dependency Installation and Update"
apt update
sleep 2

# Add "add-apt-repository" command
apt -y install software-properties-common curl apt-transport-https ca-certificates gnupg
sleep 2

# Add additional repositories for PHP (Ubuntu 22.04)
LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
sleep 2

# Add Redis official APT repository
curl -fsSL https://packages.redis.io/gpg | sudo gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/redis.list

# Update repositories list
apt update

# Install Dependencies
apt -y install php8.3 php8.3-{common,cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip} mariadb-server nginx tar unzip git redis-server
sleep 2

echo "Stopping old Nginx"
systemctl stop nginx >/dev/null 2>&1
pkill -9 nginx >/dev/null 2>&1
sleep 1

echo "Composer Installation"
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
sleep 2

echo "Pterodactyl Panel Installation"
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl

echo "Downloading Pterodactyl"
curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzvf panel.tar.gz
chmod -R 755 storage/* bootstrap/cache/
sleep 2
clear
echo ""
read -p "Masukkan domain untuk panel (contoh: xxx.com): " DOMAIN

echo "Generating Password Databases"
LENGTH=16

# Kalau ada argumen, pakai sebagai panjang
if [ ! -z "$1" ]; then
  LENGTH=$1
fi

# Generate password
PASSWORD=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9!@#$%^&*()_+=-' | head -c $LENGTH)

echo "Password Generated For Database: $PASSWORD"

read -p "Apakah Anda ingin menggunakan SMTP? (yes/no): " USE_SMTP

if [ "$USE_SMTP" == "yes" ]; then
  read -p "MAIL_HOST (contoh: mail.example.com): " MAIL_HOST
  read -p "MAIL_PORT (contoh: 587): " MAIL_PORT
  read -p "MAIL_USERNAME: " MAIL_USERNAME
  read -sp "MAIL_PASSWORD: " MAIL_PASSWORD
  echo ""
  read -p "MAIL_ENCRYPTION (tls/ssl/null): " MAIL_ENCRYPTION
else
  MAIL_HOST=null
  MAIL_PORT=null
  MAIL_USERNAME=null
  MAIL_PASSWORD=null
  MAIL_ENCRYPTION=null
fi

echo "Creating .env file"
cat << EOF > /var/www/pterodactyl/.env
APP_ENV=production
APP_DEBUG=false
APP_KEY=
APP_THEME=pterodactyl
APP_TIMEZONE=Asia/Jakarta
APP_URL=http://$DOMAIN
APP_LOCALE=id
APP_ENVIRONMENT_ONLY=true

DB_CONNECTION=mysql
DB_HOST=localhost
DB_PORT=3306
DB_DATABASE=panel
DB_USERNAME=ptero
DB_PASSWORD=$PASSWORD

REDIS_HOST=127.0.0.1
REDIS_PASSWORD=null
REDIS_PORT=6379

MAIL_DRIVER=smtp
MAIL_HOST=$MAIL_HOST
MAIL_PORT=$MAIL_PORT
MAIL_USERNAME=$MAIL_USERNAME
MAIL_PASSWORD=$MAIL_PASSWORD
MAIL_ENCRYPTION=$MAIL_ENCRYPTION
EOF

mysql -u root <<EOF
CREATE USER 'ptero'@'localhost' IDENTIFIED BY '$PASSWORD';
CREATE DATABASE panel;
GRANT ALL PRIVILEGES ON panel.* TO 'ptero'@'localhost' WITH GRANT OPTION;
EOF

echo "Generating Application Key"
COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader
php artisan key:generate --force

echo "Database Migration"
php artisan migrate --seed --force

echo "Set Permissions"
chown -R www-data:www-data /var/www/pterodactyl/*

echo "Make User Admin"
cd /var/www/pterodactyl && php artisan p:user:make

echo "Cron Jobs Pterodactyl"
CRON_JOB="* * * * * php /var/www/pterodactyl/artisan schedule:run >> /var/log/pterodactyl-schedule.log 2>&1"
(crontab -u www-data -l 2>/dev/null | grep -F "$CRON_JOB" >/dev/null) || \
(echo "$CRON_JOB" | crontab -u www-data -)

echo "pastikan port 80 kosong"
if ss -tulpn | grep -q ':80'; then
    echo "❌ Port 80 masih digunakan, cek manual dengan: ss -tulpn | grep :80"
    exit 1
fi

echo "Create Systemd Service"
cat << 'EOF' > /etc/systemd/system/pteroq.service
# Pterodactyl Queue Worker File
# ----------------------------------

[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
# On some systems the user and group might be different.
# Some systems use `apache` or `nginx` as the user and group.
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

echo "Starting Pterodactyl Queue Service"
systemctl enable --now redis-server
systemctl enable --now pteroq.service
sleep 2

echo "Nginx Configuration"
rm /etc/nginx/sites-enabled/default

cat << EOF > /etc/nginx/sites-available/pterodactyl.conf
server {
    listen 80;
    server_name $DOMAIN;

    root /var/www/pterodactyl/public;
    index index.html index.htm index.php;
    charset utf-8;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    access_log off;
    error_log  /var/log/nginx/pterodactyl.app-error.log error;

    client_max_body_size 100m;
    client_body_timeout 120s;

    sendfile off;

    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

sudo ln -s /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf

sleep 5

echo "Start Nginx"
systemctl enable --now nginx
sleep 2


cat <<'EOF'
______ _                     _            _         _   _    _ _                   _____          _        _ _           
| ___ \ |                   | |          | |       | | | |  | (_)                 |_   _|        | |      | | |          
| |_/ / |_ ___ _ __ ___   __| | __ _  ___| |_ _   _| | | |  | |_ _ __   __ _ ___    | | _ __  ___| |_ __ _| | | ___ _ __ 
|  __/| __/ _ \ '__/ _ \ / _` |/ _` |/ __| __| | | | | | |/\| | | '_ \ / _` / __|   | || '_ \/ __| __/ _` | | |/ _ \ '__|
| |   | ||  __/ | | (_) | (_| | (_| | (__| |_| |_| | | \  /\  / | | | | (_| \__ \  _| || | | \__ \ || (_| | | |  __/ |   
\_|    \__\___|_|  \___/ \__,_|\__,_|\___|\__|\__, |_|  \/  \/|_|_| |_|\__, |___/  \___/_| |_|___/\__\__,_|_|_|\___|_|   
                                               __/ |                    __/ |                                            
                                              |___/                    |___/                                             
EOF

echo "Installing Docker"
curl -sSL https://get.docker.com/ | CHANNEL=stable bash
sudo systemctl enable --now docker
sleep 2

echo "Downloading and Installing Pterodactyl Wings"
sudo mkdir -p /etc/pterodactyl
curl -L -o /usr/local/bin/wings "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_$([[ "$(uname -m)" == "x86_64" ]] && echo "amd64" || echo "arm64")"
sudo chmod u+x /usr/local/bin/wings
sleep 2

echo "Creating Wings Systemd Service"
cat << EOF > /etc/systemd/system/wings.service
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable --now wings
sleep 2

cat <<'EOF'
                             __________                    .__   
___________  ___ ____ ___.__.\______   \ ____   ____  ____ |  |  
\___   /\  \/  // ___<   |  | |     ___// __ \_/ ___\/ __ \|  |  
 /    /  >    <\  \___\___  | |    |   \  ___/\  \__\  ___/|  |__
/_____ \/__/\_ \\___  > ____| |____|    \___  >\___  >___  >____/
      \/      \/    \/\/                    \/     \/    \/      
EOF

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
echo ""
echo "Instalasi selesai dalam $((ELAPSED / 60)) menit $((ELAPSED % 60)) detik."