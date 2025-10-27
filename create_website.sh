#!/bin/bash
# ======================================================
#  Auto Website Manager (v3.1)
#  Features:
#   - Laravel / CI site automation
#   - MySQL auto creation
#   - PHP version selection
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
    sqlite3 "$DB_PATH" "CREATE TABLE IF NOT EXISTS sites (id INTEGER PRIMARY KEY, name TEXT, domain TEXT, db_name TEXT, db_user TEXT, php_version TEXT, created_at TEXT);"
  else
    # Check if php_version column exists, add if not
    sqlite3 "$DB_PATH" "PRAGMA table_info(sites);" | grep -q "php_version" || \
      sqlite3 "$DB_PATH" "ALTER TABLE sites ADD COLUMN php_version TEXT;"
  fi
}

function list_sites() {
  check_db
  sqlite3 "$DB_PATH" "SELECT id, name, domain, php_version FROM sites;"
}

# ======================================================
#  SCAN PHP VERSIONS
# ======================================================
function scan_php_versions() {
  echo ""
  echo "=== Scanning for installed PHP versions ==="
  
  declare -a PHP_VERSIONS
  declare -a PHP_SOCKETS
  
  # Scan for PHP-FPM sockets
  for socket in /run/php/php*-fpm.sock; do
    if [ -S "$socket" ]; then
      # Extract version from socket path (e.g., php8.2-fpm.sock -> 8.2)
      version=$(basename "$socket" | sed -n 's/php\([0-9]\+\.[0-9]\+\)-fpm.sock/\1/p')
      if [ -n "$version" ]; then
        PHP_VERSIONS+=("$version")
        PHP_SOCKETS+=("$socket")
      fi
    fi
  done
  
  # Also check for installed PHP CLI versions
  for php_bin in /usr/bin/php[0-9]*; do
    if [ -x "$php_bin" ] && [[ "$php_bin" =~ /usr/bin/php([0-9]+\.[0-9]+)$ ]]; then
      version="${BASH_REMATCH[1]}"
      # Check if not already in array
      if [[ ! " ${PHP_VERSIONS[@]} " =~ " ${version} " ]]; then
        socket="/run/php/php${version}-fpm.sock"
        if [ -S "$socket" ]; then
          PHP_VERSIONS+=("$version")
          PHP_SOCKETS+=("$socket")
        fi
      fi
    fi
  done
  
  if [ ${#PHP_VERSIONS[@]} -eq 0 ]; then
    echo "❌ No PHP-FPM installations found!"
    echo "Please install PHP-FPM first (e.g., apt install php8.2-fpm)"
    return 1
  fi
  
  echo ""
  echo "Found ${#PHP_VERSIONS[@]} PHP version(s):"
  for i in "${!PHP_VERSIONS[@]}"; do
    echo "  $((i+1)). PHP ${PHP_VERSIONS[$i]} (${PHP_SOCKETS[$i]})"
  done
  echo ""
  
  # Let user choose
  while true; do
    read -p "Select PHP version (1-${#PHP_VERSIONS[@]}): " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#PHP_VERSIONS[@]}" ]; then
      SELECTED_PHP_VERSION="${PHP_VERSIONS[$((choice-1))]}"
      SELECTED_PHP_SOCKET="${PHP_SOCKETS[$((choice-1))]}"
      echo "✓ Selected: PHP ${SELECTED_PHP_VERSION}"
      return 0
    else
      echo "Invalid choice. Please enter a number between 1 and ${#PHP_VERSIONS[@]}"
    fi
  done
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
  echo "Creating database..."
  mysql -e "CREATE DATABASE ${DB_NAME};"
  mysql -e "CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
  mysql -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;"
  echo "✓ Database created"

  # Scan and select PHP version
  if ! scan_php_versions; then
    echo "Cannot proceed without PHP-FPM."
    return 1
  fi

  # Nginx config
  echo "Creating Nginx configuration..."
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
        fastcgi_pass unix:${SELECTED_PHP_SOCKET};
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

  ln -s "$CONF" "${NGINX_ENABLED}/${DOMAIN}"
  nginx -t && systemctl reload nginx
  echo "✓ Nginx configured with PHP ${SELECTED_PHP_VERSION}"

  # Certbot SSL
  echo "Setting up SSL certificate..."
  certbot --nginx -d "$DOMAIN" -d "www.${DOMAIN}" --non-interactive --agree-tos -m admin@"${DOMAIN}" || true

  # Simpan database
  check_db
  sqlite3 "$DB_PATH" "INSERT INTO sites (name, domain, db_name, db_user, php_version, created_at) VALUES ('$NAME', '$DOMAIN', '$DB_NAME', '$DB_USER', '$SELECTED_PHP_VERSION', datetime('now'));"

  send_telegram "✅ Website created: ${DOMAIN} (PHP ${SELECTED_PHP_VERSION})"
  echo ""
  echo "=========================================="
  echo "✅ Website ${DOMAIN} created successfully!"
  echo "   PHP Version: ${SELECTED_PHP_VERSION}"
  echo "   Database: ${DB_NAME}"
  echo "   Path: ${SITE_PATH}"
  echo "=========================================="
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
#  MIGRATE WEBSITE FROM OLD SERVER
# ======================================================
function migrate_site() {
  echo "=== MIGRATE WEBSITE FROM OLD SERVER ==="
  
  list_sites
  read -p "Enter domain to migrate to: " DOMAIN
  
  SITE_PATH="${WWW_PATH}/${DOMAIN}"
  
  if [ ! -d "$SITE_PATH" ]; then
    echo "❌ Site ${DOMAIN} not found. Please create it first."
    return 1
  fi
  
  echo ""
  read -p "Old server address (e.g., root@panel.digidesa.id): " OLD_SERVER
  read -p "Remote path (e.g., /home/nangkod/public_html): " REMOTE_PATH
  
  echo ""
  echo "=== Step 1: Syncing files from old server ==="
  echo "Command: rsync -a -v ${OLD_SERVER}:${REMOTE_PATH}/* ${SITE_PATH}/"
  echo ""
  
  rsync -a -v "${OLD_SERVER}:${REMOTE_PATH}/"* "${SITE_PATH}/"
  
  if [ $? -ne 0 ]; then
    echo "❌ Rsync failed. Please check connection and paths."
    return 1
  fi
  
  echo "✓ Files synced successfully"
  
  # Ask if there's SQL dump to process
  echo ""
  read -p "Do you have SQL dump to import? (y/n): " HAS_SQL
  
  if [[ "$HAS_SQL" == "y" ]]; then
    echo ""
    echo "SQL dump files in ${SITE_PATH}:"
    find "$SITE_PATH" -type f -name "*.sql" 2>/dev/null
    echo ""
    read -p "Enter SQL dump filename (relative to site path): " SQL_FILE
    
    SQL_PATH="${SITE_PATH}/${SQL_FILE}"
    
    if [ ! -f "$SQL_PATH" ]; then
      echo "❌ SQL file not found: ${SQL_PATH}"
    else
      echo ""
      echo "=== Step 2: Removing DEFINER from SQL dump ==="
      echo "Command: sed -i 's/DEFINER[ ]*=[ ]*\`[^\`]*\`@\`[^\`]*\`//g' ${SQL_PATH}"
      
      sed -i 's/DEFINER[ ]*=[ ]*`[^`]*`@`[^`]*`//g' "$SQL_PATH"
      echo "✓ DEFINER removed from SQL dump"
      
      # Ask if want to import now
      echo ""
      read -p "Import SQL dump now? (y/n): " IMPORT_NOW
      
      if [[ "$IMPORT_NOW" == "y" ]]; then
        DB_NAME=$(sqlite3 "$DB_PATH" "SELECT db_name FROM sites WHERE domain='$DOMAIN';")
        DB_USER=$(sqlite3 "$DB_PATH" "SELECT db_user FROM sites WHERE domain='$DOMAIN';")
        
        if [ -z "$DB_NAME" ]; then
          echo "❌ Database info not found for ${DOMAIN}"
        else
          echo "Importing to database: ${DB_NAME}"
          read -s -p "Enter database password for ${DB_USER}: " DB_PASS
          echo ""
          
          mysql -u"${DB_USER}" -p"${DB_PASS}" "${DB_NAME}" < "$SQL_PATH"
          
          if [ $? -eq 0 ]; then
            echo "✓ SQL imported successfully"
          else
            echo "❌ SQL import failed"
          fi
        fi
      fi
    fi
  fi
  
  # Change ownership
  echo ""
  echo "=== Step 3: Changing ownership ==="
  echo "Command: chown -R www-data:www-data ${SITE_PATH}"
  
  chown -R www-data:www-data "$SITE_PATH"
  echo "✓ Ownership changed to www-data:www-data"
  
  send_telegram "🔄 Website migrated: ${DOMAIN}"
  
  echo ""
  echo "=========================================="
  echo "✅ Migration completed for ${DOMAIN}"
  echo "   Path: ${SITE_PATH}"
  echo "=========================================="
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
elif [[ "$1" == "--migrate" ]]; then
  migrate_site
  exit
fi

# ======================================================
#  MAIN MENU
# ======================================================
function main_menu() {
  check_db
  PS3="Choose an option: "
  options=("Create Website" "Migrate Website" "Renew SSL" "Edit Website Config" "Backup Website" "Delete Website" "Exit")
  select opt in "${options[@]}"; do
    case $opt in
      "Create Website") create_site ;;
      "Migrate Website") migrate_site ;;
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
