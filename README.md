# Pterodactyl Installer

## Cara Instalasi Otomatis

1. Pastikan Anda menjalankan sebagai root di Ubuntu 22.04+ atau Debian 11+.
2. Unduh atau salin file `install.sh` ke server Anda.
3. Jalankan perintah berikut di terminal:

   ```bash
   chmod +x install.sh
   ./install.sh
   ```

4. Ikuti instruksi yang muncul di layar untuk konfigurasi domain, database, dan SMTP (jika diperlukan).

> Script ini akan menginstal seluruh dependensi, mengatur database, mengonfigurasi Nginx, serta menginstal dan menjalankan Pterodactyl Panel dan Wings secara otomatis.