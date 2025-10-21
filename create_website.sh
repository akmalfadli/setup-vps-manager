#!/bin/bash
# ======================================================
#  Auto Website Manager (v3.0)
#  Features:
#   - Laravel / CI site automation
#   - MySQL auto creation
#   - Certbot SSL auto generation
#   - Google Drive backup integration
#   - Telegram notifications
#   - CLI mode (for Telegram bot)
# ======================================================

DB_PATH="/var/www/sites.db"
NGINX_SITES="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"
WWW_PATH="/var/www/sites"
BACKUP_PATH="/var/www/backups"
TELEGRAM_TOKEN="YOUR_TELEGRAM_BOT_TOKEN"
TELEGRAM_CHAT_ID="YOUR_TELEGRAM_CHAT_ID"
GDRIVE_FOLDER_ID="YOUR_GOOGLE_DRIVE_FOLDER_ID"
PHP_SOCKET="/run/php/php8.2-fpm.sock"  # sesuaikan versi PHP Anda

# ======================================================
#  Utility functions
# ======================================================
function send_telegram() {
  local MESSAGE="$1"
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    -d text="${MESSAGE}" >/dev/null
}

function check_db() {
  if [ ! -f "$DB_PATH" ]; then
    sqlite3 "$DB_PATH" "CREATE TABLE IF NOT EXISTS sites (id INTEGER PRIMARY KEY, name TEXT, domain TEXT, db_name TEXT, db_user TEXT, created_at TEXT);"
  fi
}

function list_sites() {
  check_db
  sqlite3 "$DB_PATH" "SELECT id, name, domain FROM sites;"
}

# ======================================================
#  CREATE WEBSITE
# ======================================================
function create_site() {
  echo "=== CREATE NEW WEBSITE ==="
  read -p "Website Name: " NAME
  read -p "Domain (e.g., example.com): " DOMAIN
  read -p "Database Name: " DB_NAME
  read -p "Database User: " DB_USER
  read -s -p "Database Password: " DB_PASS
  echo ""

  SITE_PATH="${WWW_PATH}/${DOMAIN}"
  mkdir -p "$SITE_PATH"
  chown -R www-data:www-data "$SITE_PATH"

  # Buat database
  mysql -e "CREATE DATABASE ${DB_NAME};"
  mysql -e "CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
  mysql -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;"

  # Nginx config
  CONF="${NGINX_SITES}/${DOMAIN}"
  cat > "$CONF" <<EOF
server {
    listen 80;
    server_name ${DOMAIN} www.${DOMAIN};
    root ${SITE_PATH}/public;

    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${PHP_SOCKET};
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

  ln -s "$CONF" "${NGINX_ENABLED}/${DOMAIN}"
  nginx -t && systemctl reload nginx

  # Certbot SSL
  certbot --nginx -d "$DOMAIN" -d "www.${DOMAIN}" --non-interactive --agree-tos -m admin@"${DOMAIN}" || true

  # Simpan database
  check_db
  sqlite3 "$DB_PATH" "INSERT INTO sites (name, domain, db_name, db_user, created_at) VALUES ('$NAME', '$DOMAIN', '$DB_NAME', '$DB_USER', datetime('now'));"

  send_telegram "✅ Website created: ${DOMAIN}"
  echo "Website ${DOMAIN} created successfully!"
}

# ======================================================
#  RENEW SSL
# ======================================================
function renew_ssl() {
  DOMAIN="$1"
  if [ -z "$DOMAIN" ]; then
    echo "Enter domain:"
    read DOMAIN
  fi
  certbot renew --cert-name "$DOMAIN" --quiet
  systemctl reload nginx
  send_telegram "🔄 SSL renewed for ${DOMAIN}"
  echo "SSL renewed for ${DOMAIN}"
}

# ======================================================
#  SSL STATUS
# ======================================================
function ssl_status() {
  DOMAIN="$1"
  certbot certificates | grep -A3 "$DOMAIN"
}

# ======================================================
#  EDIT WEBSITE CONFIG
# ======================================================
function edit_config() {
  list_sites
  read -p "Enter domain to edit: " DOMAIN
  nano "${NGINX_SITES}/${DOMAIN}"
  nginx -t && systemctl reload nginx
  send_telegram "⚙️ Config edited for ${DOMAIN}"
}

# ======================================================
#  BACKUP WEBSITE
# ======================================================
function backup_site() {
  DOMAIN="$1"
  if [ -z "$DOMAIN" ]; then
    echo "Enter domain:"
    read DOMAIN
  fi

  SITE_PATH="${WWW_PATH}/${DOMAIN}"
  BACKUP_FILE="${BACKUP_PATH}/${DOMAIN}_$(date +%Y%m%d_%H%M).tar.gz"
  mkdir -p "$BACKUP_PATH"
  tar -czf "$BACKUP_FILE" "$SITE_PATH"
  gdrive upload "$BACKUP_FILE" --parent "$GDRIVE_FOLDER_ID" >/dev/null

  send_telegram "💾 Backup completed for ${DOMAIN}"
  echo "Backup uploaded to Google Drive."
}

# ======================================================
#  DELETE WEBSITE
# ======================================================
function delete_site() {
  DOMAIN="$1"
  if [ -z "$DOMAIN" ]; then
    list_sites
    read -p "Enter domain to delete: " DOMAIN
  fi

  echo "Are you sure you want to delete ${DOMAIN}? (y/n)"
  read CONFIRM
  if [[ "$CONFIRM" != "y" ]]; then
    echo "Cancelled."
    return
  fi

  SITE_PATH="${WWW_PATH}/${DOMAIN}"
  DB_NAME=$(sqlite3 "$DB_PATH" "SELECT db_name FROM sites WHERE domain='$DOMAIN';")
  DB_USER=$(sqlite3 "$DB_PATH" "SELECT db_user FROM sites WHERE domain='$DOMAIN';")

  rm -rf "$SITE_PATH"
  rm -f "${NGINX_SITES}/${DOMAIN}" "${NGINX_ENABLED}/${DOMAIN}"
  nginx -t && systemctl reload nginx
  mysql -e "DROP DATABASE ${DB_NAME};"
  mysql -e "DROP USER '${DB_USER}'@'localhost';"
  sqlite3 "$DB_PATH" "DELETE FROM sites WHERE domain='$DOMAIN';"

  send_telegram "🗑️ Website deleted: ${DOMAIN}"
  echo "Website ${DOMAIN} deleted."
}

# ======================================================
#  AUTO BACKUP ALL
# ======================================================
function auto_backup_all() {
  mkdir -p "$BACKUP_PATH"
  for DOMAIN in $(sqlite3 "$DB_PATH" "SELECT domain FROM sites;"); do
    BACKUP_FILE="${BACKUP_PATH}/${DOMAIN}_$(date +%Y%m%d_%H%M).tar.gz"
    tar -czf "$BACKUP_FILE" "${WWW_PATH}/${DOMAIN}"
    gdrive upload "$BACKUP_FILE" --parent "$GDRIVE_FOLDER_ID" >/dev/null
  done
  send_telegram "📦 Auto backup completed for all sites"
}

# ======================================================
#  CLI MODE (for Telegram Bot)
# ======================================================
if [[ "$1" == "--backup" ]]; then
  backup_site "$2"
  exit
elif [[ "$1" == "--renew-ssl" ]]; then
  renew_ssl "$2"
  exit
elif [[ "$1" == "--ssl-status" ]]; then
  ssl_status "$2"
  exit
elif [[ "$1" == "--list" ]]; then
  list_sites
  exit
elif [[ "$1" == "--info" ]]; then
  DOMAIN="$2"
  sqlite3 "$DB_PATH" "SELECT * FROM sites WHERE domain='$DOMAIN';"
  exit
elif [[ "$1" == "--delete" ]]; then
  delete_site "$2"
  exit
elif [[ "$1" == "--auto-backup" ]]; then
  auto_backup_all
  exit
fi

# ======================================================
#  MAIN MENU
# ======================================================
function main_menu() {
  check_db
  PS3="Choose an option: "
  options=("Create Website" "Renew SSL" "Edit Website Config" "Backup Website" "Delete Website" "Exit")
  select opt in "${options[@]}"; do
    case $opt in
      "Create Website") create_site ;;
      "Renew SSL") renew_ssl ;;
      "Edit Website Config") edit_config ;;
      "Backup Website") backup_site ;;
      "Delete Website") delete_site ;;
      "Exit") exit ;;
      *) echo "Invalid option";;
    esac
  done
}

main_menu

