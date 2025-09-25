#!/bin/bash
set -euo pipefail

# ===========================
# raspberry-noaa installer (Debian 12 Bookworm)
# DB: /home/pi/raspberry-noaa/panel.db
# ===========================

# ---- UI ----
RED=$(tput setaf 1 || true); GREEN=$(tput setaf 2 || true); YELLOW=$(tput setaf 3 || true); RESET=$(tput sgr0 || true)
die(){ >&2 echo "${RED}error:${RESET} $1"; exit 1; }
ok(){  echo " ${GREEN}[OK]${RESET} $1"; }
run(){ echo " ${YELLOW}*${RESET} $1"; }
warn(){ echo " ${YELLOW}warn:${RESET} $1"; }

# ---- not root ----
[ "${EUID}" -eq 0 ] && die "Sio skripto NEREIKIA paleisti kaip root. Paleisk kaip 'pi'."

# ---- paths ----
USER_NAME="$(id -un)"
REPO_DIR="/home/pi/raspberry-noaa"
WEB_ROOT="/var/www/wx"
LOG_DIR="/var/log/raspberry-noaa"
VENV_DIR="$REPO_DIR/.venv"
DB_FILE="$REPO_DIR/panel.db"
CONN_PHP="$WEB_ROOT/Model/Conn.php"
LANG_DIR="$REPO_DIR/templates/webpanel/language"
TLE_SRC="http://192.168.1.116:8080/tle.txt"

[ -d "$REPO_DIR" ] || die "Nerasta $REPO_DIR. Klonuok: git clone https://github.com/andriux26/Seva_versija_raspberry-noaa.git \"$REPO_DIR\""
cd "$REPO_DIR"

# ---- APT ----
run "Instaliuojami paketai..."
sudo apt-get update -yq
sudo apt-get install -yq \
  wget curl git jq rsync bc at coreutils sed gawk \
  python3 python3-venv python3-pip python3-setuptools \
  build-essential pkg-config cmake unzip \
  rtl-sdr sox imagemagick libusb-1.0-0-dev \
  libncurses5-dev libncursesw5-dev libatlas-base-dev \
  libjpeg-dev zlib1g-dev libopenjp2-7-dev \
  libfreetype6-dev liblcms2-dev libwebp-dev \
  libharfbuzz-dev libfribidi-dev libimagequant-dev libxcb1-dev \
  tcl-dev tk-dev \
  nginx sqlite3 ntp ca-certificates socat libxft-dev libxft2 \
  autoconf automake libtool libreadline-dev \
  php-fpm php-sqlite3 libgfortran5 \
  libhamlib4 libhamlib-utils
sudo update-ca-certificates || true

# timesync
if systemctl list-unit-files | grep -q '^systemd-timesyncd\.service'; then
  sudo systemctl unmask systemd-timesyncd 2>/dev/null || true
  sudo systemctl enable --now systemd-timesyncd 2>/dev/null || true
  timedatectl set-ntp true 2>/dev/null || true
else
  sudo systemctl enable --now ntp 2>/dev/null || true
fi
ok "Paketai idiegti"

# ---- PREDICT (source) + symlink ----
if ! command -v predict >/dev/null 2>&1; then
  run "Kompiliuojamas PREDICT..."
  tmpdir="$(mktemp -d)"
  (
    set -e
    cd "$tmpdir"
    git clone https://github.com/jj1bdx/predict.git
    cd predict
    make -j"$(nproc)"
    sudo install -m0755 predict /usr/local/bin/predict
    sudo ldconfig || true
  )
  rm -rf "$tmpdir"
fi
sudo ln -sf /usr/local/bin/predict /usr/bin/predict
ok "PREDICT paruostas"

# ---- Python venv (PEP668) ----
run "Python priklausomybes (venv)..."
python3 -m venv "$VENV_DIR" || { sudo apt-get install -y python3-venv && python3 -m venv "$VENV_DIR"; }
# shellcheck disable=SC1090
source "$VENV_DIR/bin/activate"
cat > "$VENV_DIR/pip.conf" <<'CONF'
[global]
index-url = https://pypi.org/simple
timeout = 120
retries = 3
CONF
export PIP_CONFIG_FILE="$VENV_DIR/pip.conf"
unset PIP_EXTRA_INDEX_URL PIP_INDEX_URL
python -m pip install --upgrade pip setuptools wheel packaging
python -m pip install --no-cache-dir \
  numpy==1.26.4 Pillow==10.4.0 tweepy==3.8.0 urllib3==1.25.8 \
  requests==2.32.5 idna==3.7 ephem
deactivate
ok "Python priklausomybes idiegtos"

# ---- DB schema (REPO viduje) + TEISES PHP prieigai ----
run "DB schema (repo) ir teises..."
if [ ! -f "$DB_FILE" ]; then
  if [ -f "$REPO_DIR/templates/webpanel_schema.sql" ]; then
    sqlite3 "$DB_FILE" < "$REPO_DIR/templates/webpanel_schema.sql"
    ok "Sukurta $DB_FILE"
  else
    warn "Nerasta templates/webpanel_schema.sql – DB praleista"
  fi
else
  ok "DB jau yra: $DB_FILE"
fi
# leidimai – svarbu: praeinamumas iki DB
sudo chown pi:www-data "$DB_FILE"
sudo chmod 664 "$DB_FILE"
sudo chmod 755 /home
sudo chmod 711 /home/pi
sudo chgrp www-data "$REPO_DIR"
sudo chmod 2775 "$REPO_DIR"
sudo -u www-data php -r '$db=new SQLite3("/home/pi/raspberry-noaa/panel.db"); echo $db?"OK\n":"FAIL\n";' || true

# ---- DVB blacklist ----
if [ ! -f /etc/modprobe.d/rtlsdr.conf ] && [ -f "$REPO_DIR/templates/modprobe.d/rtlsdr.conf" ]; then
  sudo cp "$REPO_DIR/templates/modprobe.d/rtlsdr.conf" /etc/modprobe.d/rtlsdr.conf
  ok "DVB moduliai uzblokuoti"
else
  ok "DVB moduliai jau tvarkoje"
fi

# ---- RTL-SDR ----
if ! command -v rtl_fm >/dev/null 2>&1; then
  run "Diegiam rtl-sdr is osmocom..."
  (
    set -e
    cd /tmp
    rm -rf rtl-sdr
    git clone https://github.com/osmocom/rtl-sdr.git
    cd rtl-sdr
    mkdir -p build && cd build
    cmake ../ -DINSTALL_UDEV_RULES=ON -DDETACH_KERNEL_DRIVER=ON
    make -j"$(nproc)"
    sudo make install
    sudo ldconfig
    sudo cp ../rtl-sdr.rules /etc/udev/rules.d/ || true
  )
  ok "rtl-sdr idiegtas"
else
  ok "rtl-sdr jau idiegtas"
fi

# ---- WxToIMG (optional, armhf on aarch64, su libtiff5/6 aptikimu) ----
if [ -f "$REPO_DIR/software/wxtoimg-armhf-2.11.2-beta.deb" ] && ! command -v xwxtoimg >/dev/null 2>&1; then
  ARCH="$(uname -m || true)"
  if [ "$ARCH" = "aarch64" ]; then
    run "64-bit OS – ijungiam armhf multiarch WxToIMG'ui..."
    sudo dpkg --add-architecture armhf
    sudo apt-get update

    ARMHF_DEPS="libc6:armhf libx11-6:armhf libxext6:armhf libjpeg62-turbo:armhf zlib1g:armhf libgtk2.0-0:armhf"
    if apt-cache show libtiff5:armhf >/dev/null 2>&1; then
      ARMHF_DEPS="$ARMHF_DEPS libtiff5:armhf"
    elif apt-cache show libtiff6:armhf >/dev/null 2>&1; then
      ARMHF_DEPS="$ARMHF_DEPS libtiff6:armhf"
    else
      warn "Nerasta nei libtiff5:armhf, nei libtiff6:armhf – tesiu be TIFF."
    fi
    sudo apt-get install -y $ARMHF_DEPS
  fi

  run "Diegiame WxToIMG..."
  sudo dpkg -i "$REPO_DIR/software/wxtoimg-armhf-2.11.2-beta.deb" || warn "WxToIMG nepavyko idiegti – praleidziu"
  command -v xwxtoimg >/dev/null 2>&1 && ok "WxToIMG idiegtas" || warn "WxToIMG neprieinamas (sistema veiks ir be jo)"
fi

# ---- Default config ----
[ -f "$HOME/.noaa.conf" ]     || { [ -f "$REPO_DIR/templates/noaa.conf" ] && cp "$REPO_DIR/templates/noaa.conf" "$HOME/.noaa.conf"; }
[ -d "$HOME/.predict" ]       || mkdir -p "$HOME/.predict"
[ -f "$HOME/.predict/predict.qth" ] || { [ -f "$REPO_DIR/templates/predict.qth" ] && cp "$REPO_DIR/templates/predict.qth" "$HOME/.predict/predict.qth"; }
[ -f "$HOME/.wxtoimgrc" ]     || { [ -f "$REPO_DIR/templates/wxtoimgrc" ] && cp "$REPO_DIR/templates/wxtoimgrc" "$HOME/.wxtoimgrc"; }
[ -f "$HOME/.tweepy.conf" ]   || { [ -f "$REPO_DIR/templates/tweepy.conf" ] && cp "$REPO_DIR/templates/tweepy.conf" "$HOME/.tweepy.conf"; }
ok "Numatyti konfigai ideti"

# ---- TLE ----
run "Atsisiunciami TLE i ~/predict..."
mkdir -p "$HOME/predict"
wget -q -O "$HOME/predict/weather.txt"  "$TLE_SRC" || true
[ -s "$HOME/predict/weather.txt" ] && cp -f "$HOME/predict/weather.txt" "$HOME/predict/weather.tle" || true
wget -q -O "$HOME/predict/amateur.txt"  "$TLE_SRC" || true
ok "TLE paruosti (jei saltinis pasiekiamas)"

# ---- meteor_demod ----
if ! command -v meteor_demod >/dev/null 2>&1; then
  run "Diegiam meteor_demod..."
  (
    set -e
    cd /tmp
    rm -rf meteor_demod
    git clone https://github.com/dbdexter-dev/meteor_demod.git
    cd meteor_demod
    make -j"$(nproc)"
    sudo make install
  )
  ok "meteor_demod idiegtas"
else
  ok "meteor_demod jau idiegtas"
fi

# ---- medet_arm ----
if ! command -v medet_arm >/dev/null 2>&1 && [ -f "$REPO_DIR/software/medet_arm" ]; then
  sudo cp "$REPO_DIR/software/medet_arm" /usr/bin/medet_arm
  sudo chmod +x /usr/bin/medet_arm
  ok "medet_arm idiegtas"
fi

# ---- CRON ----
sudo mkdir -p "$LOG_DIR"
sudo chown "$USER_NAME":"$USER_NAME" "$LOG_DIR" || true
CRON_LINE="1 0 * * * $REPO_DIR/schedule.sh >> $LOG_DIR/schedule.log 2>&1"
( crontab -l 2>/dev/null | grep -Fv "$REPO_DIR/schedule.sh" || true; echo "$CRON_LINE" ) | crontab -
ok "Cron nustatytas: $CRON_LINE"

# ---- WEB diegimas ----
run "Nustatomas Nginx ir web root..."
sudo mkdir -p "$WEB_ROOT/images"
if [ -d "$REPO_DIR/templates/webpanel" ]; then
  sudo rsync -a "$REPO_DIR/templates/webpanel/" "$WEB_ROOT/"
elif [ -d "$REPO_DIR/www" ]; then
  sudo rsync -a "$REPO_DIR/www/" "$WEB_ROOT/"
fi
[ -z "$(ls -A "$WEB_ROOT" 2>/dev/null)" ] && echo '<?php echo "OK";' | sudo tee "$WEB_ROOT/index.php" >/dev/null
sudo chown -R "$USER_NAME":www-data "$WEB_ROOT"
sudo find "$WEB_ROOT" -type d -exec chmod 2775 {} \;
sudo find "$WEB_ROOT" -type f -exec chmod 664 {} \;

# Pasalinam konfliktinius default_server site’us
sudo rm -f /etc/nginx/sites-enabled/rasp-noaa 2>/dev/null || true
for f in /etc/nginx/sites-enabled/*; do
  [ -e "$f" ] || continue
  if grep -q "default_server" "$f" && [ "$f" != "/etc/nginx/sites-enabled/default" ]; then
    sudo rm -f "$f"
  fi
done

# PHP-FPM sock
PHP_SOCK="/run/php/php-fpm.sock"
test -S /run/php/php8.2-fpm.sock && PHP_SOCK="/run/php/php8.2-fpm.sock"

sudo tee /etc/nginx/sites-enabled/default >/dev/null <<NG
server {
    listen 80 default_server;
    server_name _;
    root $WEB_ROOT;
    index index.php index.html index.htm;

    location / { try_files \$uri \$uri/ =404; }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${PHP_SOCK};
    }
}
NG

sudo nginx -t && sudo systemctl restart nginx
ok "Nginx sukonfiguruotas"

# ---- Pataisom Conn.php > absoliutus DB kelias ----
if [ -f "$CONN_PHP" ]; then
  sudo cp "$CONN_PHP" "$CONN_PHP.bak"
  sudo sed -i -E "s#new SQLite3\((\"|').*(\"|')\)#new SQLite3('/home/pi/raspberry-noaa/panel.db')#g" "$CONN_PHP"
  ok "Conn.php > /home/pi/raspberry-noaa/panel.db"
fi

# ---- Ijungiam short_open_tag, jei sablonuose rastos trumpos zymes ----
if grep -RIl --exclude-dir=.git -e '<?[^p?=]' "$WEB_ROOT" >/dev/null 2>&1; then
  for INI in /etc/php/*/fpm/php.ini; do
    [ -f "$INI" ] || continue
    sudo sed -i 's/^;*short_open_tag\s*=.*/short_open_tag = On/' "$INI"
  done
  sudo systemctl restart php*-fpm || true
  ok "short_open_tag ijungtas"
fi

# ===========================
#  INTERAKTYVUS NUSTATYMAI
# ===========================
echo
echo "Dabar sukonfiguruosim: kalba, laiko zona, koordinates."

# Kalba
if [ -d "$LANG_DIR" ] && [ -f "$WEB_ROOT/Config.php" ]; then
  mapfile -t langs < <(find "$LANG_DIR" -type f -printf "%f\n" | cut -d'.' -f1 | xargs)
  if [ "${#langs[@]}" -gt 0 ]; then
    while : ; do
      read -rp "Pasirink kalba (${langs[*]}): " lang
      [[ " ${langs[*]} " == *" ${lang} "* ]] && break
      echo "Neteisinga reiksme. Bandyk dar."
    done
    sudo sed -i -e "s/'lang' => '.*'$/'lang' => '${lang}'/" "$WEB_ROOT/Config.php"
    ok "Kalba nustatyta: $lang"
  fi
else
  warn "Nerasti kalbu failai arba Config.php – praleidziu kalbos nustatyma"
fi

# Laiko zona
if [ -f "$WEB_ROOT/header.php" ]; then
  echo "Laiko zonu sarasas: https://www.php.net/manual/en/timezones.php"
  read -rp "Ivesk laiko zona (pvz., Europe/Vilnius): " timezone
  tz_escaped=$(echo "${timezone:-Europe/Vilnius}" | sed 's/\//\\\//g')
  sudo sed -i -e "s/date_default_timezone_set('.*');/date_default_timezone_set('${tz_escaped}');/" "$WEB_ROOT/header.php"
  ok "Laiko zona: ${timezone:-Europe/Vilnius}"
else
  warn "Nerastas $WEB_ROOT/header.php – praleidziu"
fi

# Koordinates + TZ offset
read -rp "Platuma (pvz., 55.57): " lat
read -rp "Ilguma (pvz., 24.25): " lon
read -rp "Laiko zonos offset (Vasara 3, Ziema 2): " tzoffset
[ -f "$HOME/.noaa.conf" ]           && sed -i -e "s/change_latitude/${lat}/g;s/change_longitude/${lon}/g" "$HOME/.noaa.conf" || true
[ -f "$HOME/.wxtoimgrc" ]           && sed -i -e "s/change_latitude/${lat}/g;s/change_longitude/${lon}/g" "$HOME/.wxtoimgrc" || true
[ -f "$HOME/.predict/predict.qth" ] && sed -i -e "s/change_latitude/${lat}/g;s/change_longitude/$(echo "$lon * -1" | bc)/g" "$HOME/.predict/predict.qth" || true
[ -f "$REPO_DIR/sun.py" ]           && sed -i -e "s/change_latitude/${lat}/g;s/change_longitude/${lon}/g;s/change_tz/$(echo "$tzoffset * -1" | bc)/g" "$REPO_DIR/sun.py" || true
ok "Koordinates/TZ pritaikyta"

# Reload PHP-FPM/nginx
sudo systemctl reload php*-fpm 2>/dev/null || sudo systemctl restart php*-fpm
sudo systemctl reload nginx

# ---- ramFS (jei naudojamas) ----
if [ -f "$REPO_DIR/templates/fstab" ]; then
  MEM=$(free -m | awk '/^Mem:/{print $2}')
  [ "$MEM" -lt 2000 ] && sed -i -e "s/1000M/200M/g" "$REPO_DIR/templates/fstab"
  if ! grep -q "ramfs" /etc/fstab 2>/dev/null; then
    sudo mkdir -p /var/ramfs
    cat "$REPO_DIR/templates/fstab" | sudo tee -a /etc/fstab >/dev/null
    sudo mount -a || true
    sudo chmod 777 /var/ramfs || true
    ok "ramfs sukonfiguruotas"
  else
    ok "ramfs jau sukonfiguruotas"
  fi
fi

# ---- Vykdomos teises, /common.sh ----
chmod +x "$REPO_DIR"/schedule*.sh "$REPO_DIR"/receive*.sh "$REPO_DIR"/*.sh 2>/dev/null || true
[ -f "$REPO_DIR/common.sh" ] && sudo ln -sf "$REPO_DIR/common.sh" /common.sh || true

echo
ok "Diegimas baigtas!"
echo "Atverk:   http://<tavo_PI_IP>/"
echo "WEB root: $WEB_ROOT"
echo "DB:       $DB_FILE (REPO kataloge)"
echo "Logai:    $LOG_DIR/schedule.log"
