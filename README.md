🌐 VPS Website Manager

Multi-Website Automation for Laravel, CodeIgniter, and PHP Apps

🧩 Deskripsi

VPS Website Manager adalah sistem otomatis untuk mengelola banyak website di satu VPS.
Mendukung:

🔧 Pembuatan website Laravel / CI otomatis

🗄️ Pembuatan database MySQL otomatis

🔐 SSL Let's Encrypt otomatis

☁️ Backup harian ke Google Drive

🤖 Kontrol penuh lewat Telegram Bot

📊 Monitoring CPU, RAM, dan Disk dari Telegram

Didesain agar ringan, aman, dan tanpa panel kontrol berat seperti cPanel atau Virtualmin.

🏗️ Fitur Utama
Fitur	Deskripsi
🌍 Multi-domain support	Host hingga 25+ domain dengan isolasi penuh
🧠 Auto Nginx config	Otomatis membuat virtual host Nginx
🗃️ Auto MySQL	Otomatis buat database & user unik
🔐 SSL Certbot	Otomatis pasang dan perbarui SSL
📦 Google Drive backup	Backup harian ke folder GDrive
🤖 Telegram Bot	Kendali VPS via chat (backup, SSL, status)
🧾 SQLite registry	Menyimpan daftar semua website
🕒 Cron automation	Jadwal backup dan SSL renew otomatis
🔒 PIN protection	Proteksi perintah berbahaya seperti delete & SSL renew
⚙️ Instalasi Otomatis
1️⃣ Jalankan installer:

wget -O setup_vps_manager.sh https://raw.githubusercontent.com/akmalfadli/setup-vps-manager/refs/heads/main/setup_vps_manager.sh
chmod +x setup_vps_manager.sh
sudo bash setup_vps_manager.sh

2️⃣ Masukkan data konfigurasi saat diminta:

Telegram Bot Token

Telegram Chat ID

Google Drive Folder ID

Token Telegram bisa didapat dari @BotFather
.
Folder ID GDrive dapat diambil dari URL folder drive kamu.
Contoh: https://drive.google.com/drive/folders/ABC123XYZ → ABC123XYZ

🧰 Struktur Sistem
Lokasi	Fungsi
/var/www/create_website.sh	Skrip utama manajemen website
/var/www/sites.db	Database SQLite daftar website
/var/www/backups/	Direktori penyimpanan backup
/etc/nginx/sites-available/	File konfigurasi Nginx
/var/www/telegram_bot.py	Bot Telegram listener
/etc/systemd/system/telegram-bot.service	Service Telegram Bot
/usr/local/bin/gdrive	CLI upload Google Drive
cron jobs	Jadwal backup & SSL renew otomatis
💻 Cara Menggunakan
🔹 Jalankan menu interaktif:
bash /var/www/create_website.sh


Menu akan menampilkan:

[1] Create New Website
[2] Renew SSL for Website
[3] Edit Website Config
[4] Backup One Website
[5] Delete Website
[6] List Websites
[7] Exit

☁️ Backup & Restore
🔹 Backup semua website otomatis (via cron):

Jalankan setiap hari jam 3 pagi:

0 3 * * * /var/www/create_website.sh --auto-backup >/dev/null 2>&1

🔹 Backup satu website manual:
bash /var/www/create_website.sh --backup example.com


Backup akan disimpan di /var/www/backups/example.com_YYYYMMDD.tar.gz
dan otomatis diupload ke Google Drive folder yang kamu tentukan.

🔐 SSL Otomatis

Certbot otomatis dipasang dan diatur melalui cron job:

0 2 * * * /usr/bin/certbot renew --quiet && systemctl reload nginx


Kamu juga bisa perbarui manual:

bash /var/www/create_website.sh --renew-ssl example.com

🤖 Telegram Bot Commands

Kamu bisa kendalikan VPS langsung lewat Telegram!

Command	Deskripsi
/list	Menampilkan semua website
/info example.com	Info lengkap website
/backup example.com	Backup satu website
/renew_ssl example.com 1234	Renew SSL (PIN 1234 default)
/delete example.com 1234	Hapus website (PIN diperlukan)
/ssl_status example.com	Status sertifikat SSL
/status	Menampilkan CPU, RAM, Disk VPS
/help	Bantuan daftar perintah

🔒 PIN default = 1234 (ubah di /etc/systemd/system/telegram-bot.service pada baris Environment="BOT_PIN=1234")



🧾 Logging & Monitoring
File	Fungsi
/var/log/nginx/error.log	Error dari web server
/var/log/syslog	Log bot Telegram & cron
/var/www/sites.db	Catatan domain & database
/var/www/backups/	File backup lokal
🛠️ Maintenance
Perintah	Fungsi
systemctl restart telegram-bot	Restart bot Telegram
systemctl status telegram-bot	Cek status bot
nginx -t && systemctl reload nginx	Tes dan reload Nginx
sqlite3 /var/www/sites.db "SELECT * FROM sites;"	Cek daftar website di DB
🧑‍💻 Author & Lisensi

Author: Akmal Fadli (ChatGPT-assisted)
Lisensi: MIT — bebas digunakan dan dimodifikasi.

⚠️ Script ini dirancang untuk VPS Ubuntu/Debian dan tidak direkomendasikan dijalankan di shared hosting.
Pastikan kamu sudah backup server sebelum menjalankan instalasi.

🚀 Roadmap (Coming Soon)

 /restore example.com untuk restore backup dari Google Drive

 Integrasi auto DNS dengan Cloudflare API

 Laporan harian status VPS via Telegram

 Auto restart service jika Nginx/PHP-FPM down

 Mode multi-user Telegram (whitelist ID admin)