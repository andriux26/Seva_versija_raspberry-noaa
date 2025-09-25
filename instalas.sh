#!/bin/bash
set -euo pipefail

# ===========================
#  raspberry-noaa installer
#  Raspberry Pi OS (Debian 12 Bookworm)
# ===========================

# ---- UI helpers ----
RED=$(tput setaf 1 || true)
GREEN=$(tput setaf 2 || true)
YELLOW=$(tput setaf 3 || true)
RESET=$(tput sgr0 || true)

die() { >&2 echo "${RED}error: $1${RESET}"; exit 1; }
ok()  { echo " ${GREEN}[OK]${RESET} $1"; }
run() { echo " ${YELLOW}*${RESET} $1"; }
warn(){ echo " ${YELLOW}warn:${RESET} $1"; }
err() { echo " ${RED}error:${RESET} $1"; }

# ---- must NOT run as root ----
if [ "${EUID}" -eq 0 ]; then
  die "Sio skripto NEREIKIA paleisti kaip root. Paleisk kaip 'pi' (ar kita user), skriptas pats naudos sudo kur reikia."
fi

# ---- repo check ----
REPO_DIR="$HOME/raspberry-noaa"
[ -d "$REPO_DIR" ] || die "Nerasta direktorija $REPO_DIR. Atsisiusk: git clone https://github.com/andriux26/Seva_versija_raspberry-noaa.git \"$REPO_DIR\""
cd "$REPO_DIR"

# ---- APT packages ----
run "Instaliuojami paketai (APT)..."
sudo apt-get update -yq
sudo apt-get install -yq \
  wget curl git jq rsync bc at coreutils sed gawk \
  python3 python3-venv python3-pip python3-setuptools \
  build-essential pkg-config cmake unzip \
  rtl-sdr sox imagemagick libusb-1.0-0-dev \
  libncurses5-dev libncursesw5-dev libatlas-base-dev \
  libjpeg-dev zlib1g-dev libtiff5-dev libopenjp2-7-dev \
  libfreetype6-dev liblcms2-dev libwebp-dev \
  libharfbuzz-dev libfribidi-dev libimagequant-dev libxcb1-dev \
  tcl-dev tk-dev \
  nginx sqlite3 ntp ca-certificates socat libxft-dev libxft2 \
  autoconf automake libtool libreadline-dev \
  php-fpm php-sqlite3 libgfortran5 \
  libhamlib4 libhamlib-utils
sudo update-ca-certificates || true

# NTP: jei turim systemd-timesyncd – ijungiame; kitu atveju paliekame ntp
if systemctl list-unit-files | grep -q '^systemd-timesyncd\.service'; then
  sudo systemctl unmask systemd-timesyncd 2>/dev/null || true
  sudo systemctl enable --now systemd-timesyncd 2>/dev/null || true
  timedatectl set-ntp true 2>/dev/null || true
else
  sudo systemctl enable --now ntp 2>/dev/null || true
fi
ok "Paketai idiegti"

# ---- PREDICT from source (APT paketo nera Bookworm'e) ----
if command -v predict >/dev/null 2>&1; then
  ok "PREDICT jau idiegtas"
else
  run "Kompiliuojamas PREDICT is saltinio..."
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
  if command -v predict >/dev/null 2>&1; then
    ok "PREDICT idiegtas"
  else
    warn "PREDICT nepavyko idiegti (tesiam)."
  fi
fi
# Symlink’as, nes projektas kviecia /usr/bin/predict
sudo ln -sf /usr/local/bin/predict /usr/bin/predict

# ---- Python deps in VENV (PEP 668 fix) ----
run "Python priklausomybes (venv)..."
VENV_DIR="$REPO_DIR/.venv"
python3 -m venv "$VENV_DIR" || { sudo apt-get install -y python3-venv && python3 -m venv "$VENV_DIR"; }
# shellcheck disable=SC1090
source "$VENV_DIR/bin/activate"

# pip: naudok TIK PyPI (apeinam piwheels/SSL bedas)
cat > "$VENV_DIR/pip.conf" <<'CONF'
[global]
index-url = https://pypi.org/simple
timeout = 120
retries = 3
CONF
export PIP_CONFIG_FILE="$VENV_DIR/pip.conf"
unset PIP_EXTRA_INDEX_URL PIP_INDEX_URL

# baziniai irankiai
python -m pip install --upgrade pip setuptools wheel packaging

# suderintos versijos Bookworm + Py3.11
python -m pip install --no-cache-dir \
  numpy==1.26.4 \
  Pillow==10.4.0 \
  tweepy==3.8.0 \
  urllib3==1.25.8 \
  requests==2.32.5 \
  idna==3.7 \
  ephem

deactivate
ok "Python priklausomybes idiegtos (venv: $VENV_DIR)"

# ---- DB schema ----
if [ -e "$REPO_DIR/panel.db" ]; then
  ok "DB jau sukurta"
else
  if [ -f "$REPO_DIR/templates/webpanel_schema.sql" ]; then
    sqlite3 "$REPO_DIR/panel.db" < "$REPO_DIR/templates/webpanel_schema.sql"
    ok "DB schema sukurta"
  else
    warn "Nerasta templates/webpanel_schema.sql – praleidziu DB schema"
  fi
fi

# ---- Blacklist DVB ----
if [ -e /etc/modprobe.d/rtlsdr.conf ]; then
  ok "DVB moduliai jau uzblokuoti"
else
  if [ -f "$REPO_DIR/templates/modprobe.d/rtlsdr.conf" ]; then
    sudo cp "$REPO_DIR/templates/modprobe.d/rtlsdr.conf" /etc/modprobe.d/rtlsdr.conf
    ok "DVB moduliai uzblokuoti"
  else
    warn "Nerasta templates/modprobe.d/rtlsdr.conf – praleidziu"
  fi
fi

# ---- RTL-SDR (is osmocom) ----
if command -v rtl_fm >/dev/null 2>&1; then
  ok "rtl-sdr jau idiegtas"
else
  run "Diegiam rtl-sdr is osmocom..."
  (
    set -e
    cd /tmp/
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
fi

# ---- WxToIMG (32-bit armhf; 64-bit OS reikia multiarch) ----
if command -v xwxtoimg >/dev/null 2>&1; then
  ok "WxToIMG jau idiegtas"
else
  if [ -f "$REPO_DIR/software/wxtoimg-armhf-2.11.2-beta.deb" ]; then
    ARCH="$(uname -m || true)"
    if [ "$ARCH" = "aarch64" ]; then
      run "64-bit OS aptikta – ijungiame armhf multiarch WxToIMG'ui..."
      sudo dpkg --add-architecture armhf
      sudo apt-get update
      sudo apt-get install -y \
        libc6:armhf libx11-6:armhf libxext6:armhf \
        libjpeg62-turbo:armhf zlib1g:armhf libtiff5:armhf libgtk2.0-0:armhf
    fi
    run "Diegiame WxToIMG..."
    if ! sudo dpkg -i "$REPO_DIR/software/wxtoimg-armhf-2.11.2-beta.deb"; then
      warn "WxToIMG nepavyko idiegti – praleidziu (sistema veiks be jo)."
    else
      ok "WxToIMG idiegtas"
    fi
  else
    warn "Nerasta software/wxtoimg-armhf-2.11.2-beta.deb – praleidziu"
  fi
fi

# ---- Default config files ----
if [ -e "$HOME/.noaa.conf" ]; then
  ok "$HOME/.noaa.conf jau yra"
else
  if [ -f "$REPO_DIR/templates/noaa.conf" ]; then
    cp "$REPO_DIR/templates/noaa.conf" "$HOME/.noaa.conf"
    ok "$HOME/.noaa.conf idiegtas"
  else
    warn "Nerasta templates/noaa.conf – praleidziu"
  fi
fi

if [ -d "$HOME/.predict" ] && [ -e "$HOME/.predict/predict.qth" ]; then
  ok "$HOME/.predict/predict.qth jau yra"
else
  mkdir -p "$HOME/.predict"
  if [ -f "$REPO_DIR/templates/predict.qth" ]; then
    cp "$REPO_DIR/templates/predict.qth" "$HOME/.predict/predict.qth"
    ok "$HOME/.predict/predict.qth idiegtas"
  else
    warn "Nerasta templates/predict.qth – praleidziu"
  fi
fi

if [ -e "$HOME/.wxtoimgrc" ]; then
  ok "$HOME/.wxtoimgrc jau yra"
else
  if [ -f "$REPO_DIR/templates/wxtoimgrc" ]; then
    cp "$REPO_DIR/templates/wxtoimgrc" "$HOME/.wxtoimgrc"
    ok "$HOME/.wxtoimgrc idiegtas"
  else
    warn "Nerasta templates/wxtoimgrc – praleidziu"
  fi
fi

if [ -e "$HOME/.tweepy.conf" ]; then
  ok "$HOME/.tweepy.conf jau yra"
else
  if [ -f "$REPO_DIR/templates/tweepy.conf" ]; then
    cp "$REPO_DIR/templates/tweepy.conf" "$HOME/.tweepy.conf"
    ok "$HOME/.tweepy.conf idiegtas"
  else
    warn "Nerasta templates/tweepy.conf – praleidziu"
  fi
fi

# ---- (neprivaloma) TLE atsisiuntimas i ~/predict ----
mkdir -p "$HOME/predict"
wget -q -O "$HOME/predict/weather.txt"  http://192.168.1.116:8080/tle.txt || true
[ -s "$HOME/predict/weather.txt" ] && cp -f "$HOME/predict/weather.txt" "$HOME/predict/weather.tle" || true
wget -q -O "$HOME/predict/amateur.txt"  http://192.168.1.116:8080/tle.txt || true

# ---- meteor_demod ----
if command -v meteor_demod >/dev/null 2>&1; then
  ok "meteor_demod jau idiegtas"
else
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
fi

# ---- medet_arm ----
if command -v medet_arm >/dev/null 2>&1; then
  ok "medet_arm jau idiegtas"
else
  if [ -f "$REPO_DIR/software/medet_arm" ]; then
    run "Diegiam medet_arm..."
    sudo cp "$REPO_DIR/software/medet_arm" /usr/bin/medet_arm
    sudo chmod +x /usr/bin/medet_arm
    ok "medet_arm idiegtas"
  else
    warn "Nerastas software/medet_arm – praleidziu"
  fi
fi

# ---- CRON (kasdien 00:01) ----
sudo mkdir -p /var/log/raspberry-noaa
sudo chown "$USER":"$USER" /var/log/raspberry-noaa || true
set +e
crontab -l 2>/dev/null | grep -q "$REPO_DIR/schedule.sh"
if [ $? -eq 0 ]; then
  ok "Crontab jau irasytas"
else
  (
    crontab -l 2>/dev/null
    echo "1 0 * * * $REPO_DIR/schedule.sh >> /var/log/raspberry-noaa/schedule.log 2>&1"
  ) | crontab -
  ok "Crontab irasytas"
fi
set -e

# ---- Nginx /var/www/wx ----
run "Nustatomas Nginx ir web root..."
sudo mkdir -p /var/www/wx/images

# web kopija
if [ -d "$REPO_DIR/templates/webpanel" ]; then
  sudo rsync -a "$REPO_DIR/templates/webpanel/" /var/www/wx/
fi
# testinis index, jei tuscia
if [ -z "$(ls -A /var/www/wx 2>/dev/null)" ]; then
  echo '<?php echo "OK";' | sudo tee /var/www/wx/index.php >/dev/null
fi

sudo chown -R "$USER":www-data /var/www/wx
sudo find /var/www/wx -type d -exec chmod 2775 {} \;
sudo find /var/www/wx -type f -exec chmod 664 {} \;

# PANAIKINAM kitus default_server site'us (paliekam tik musu 'default')
sudo rm -f /etc/nginx/sites-enabled/rasp-noaa 2>/dev/null || true
for f in /etc/nginx/sites-enabled/*; do
  [ -e "$f" ] || continue
  if grep -q "default_server" "$f" && [ "$f" != "/etc/nginx/sites-enabled/default" ]; then
    sudo rm -f "$f"
  fi
done

# Nginx default site su PHP-FPM sock aptikimu
PHP_SOCK="/run/php/php-fpm.sock"
test -S /run/php/php8.2-fpm.sock && PHP_SOCK="/run/php/php8.2-fpm.sock"
sudo tee /etc/nginx/sites-enabled/default >/dev/null <<NG
server {
    listen 80 default_server;
    server_name _;
    root /var/www/wx;
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

# ---- ramFS ----
SYSTEM_MEMORY=$(free -m | awk '/^Mem:/{print $2}')
if [ "$SYSTEM_MEMORY" -lt 2000 ] && [ -f "$REPO_DIR/templates/fstab" ]; then
  sed -i -e "s/1000M/200M/g" "$REPO_DIR/templates/fstab"
fi
if ! grep -q "ramfs" /etc/fstab 2>/dev/null; then
  sudo mkdir -p /var/ramfs
  if [ -f "$REPO_DIR/templates/fstab" ]; then
    cat "$REPO_DIR/templates/fstab" | sudo tee -a /etc/fstab >/dev/null
    ok "ramfs irasytas i fstab"
  else
    warn "Nerasta templates/fstab – praleidziu ramfs irasa"
  fi
else
  ok "ramfs jau sukonfiguruotas"
fi
sudo mount -a || true
sudo chmod 777 /var/ramfs || true

# ---- pd120_decoder (venv) ----
if [ -f "$REPO_DIR/demod.py" ]; then
  ok "pd120_decoder jau yra"
else
  run "Diegiam pd120_decoder..."
  wget -q https://github.com/reynico/pd120_decoder/archive/master.zip -O /tmp/pd120_master.zip
  (
    set -e
    cd /tmp
    rm -rf pd120_decoder-master
    unzip -q pd120_master.zip
    cd pd120_decoder-master/pd120_decoder/
    # naudok venv vietoj --user
    source "$VENV_DIR/bin/activate"
    python -m pip install --no-cache-dir -r requirements.txt
    deactivate
    cp demod.py utils.py "$REPO_DIR/"
  )
  ok "pd120_decoder idiegtas"
fi

# ---- Vykdomos teises, /common.sh symlink jei reikia ---
chmod +x "$REPO_DIR"/schedule*.sh "$REPO_DIR"/receive*.sh "$REPO_DIR"/*.sh 2>/dev/null || true
[ -f "$REPO_DIR/common.sh" ] && sudo ln -sf "$REPO_DIR/common.sh" /common.sh || true

echo
ok "Diegimas baigtas!"

# ---- Bias-tee ----
read -rp "Ijungti stiprintuva bias-tee? (y/N) " REPLY
if [[ "${REPLY:-N}" =~ ^[Yy]$ ]]; then
  [ -f "$HOME/.noaa.conf" ] && sed -i -e "s/enable_bias_tee/-T/g" "$HOME/.noaa.conf" || true
  ok "Bias-tee ijungtas"
else
  [ -f "$HOME/.noaa.conf" ] && sed -i -e "s/enable_bias_tee//g" "$HOME/.noaa.conf" || true
fi

echo
echo "Dabar sukonfiguruosim webpanel kalba ir laiko zona."
echo "Veliau tai galima keisti /var/www/wx/Config.php (lang) ir /var/www/wx/header.php (date_default_timezone_set)."

# ---- webpanel language ----
LANG_DIR="$REPO_DIR/templates/webpanel/language"
if [ -d "$LANG_DIR" ] && [ -f /var/www/wx/Config.php ]; then
  mapfile -t langs < <(find "$LANG_DIR" -type f -printf "%f\n" | cut -d'.' -f1 | xargs)
  if [ "${#langs[@]}" -gt 0 ]; then
    while : ; do
      read -rp "Pasirink kalba (${langs[*]}): " lang
      if [[ " ${langs[*]} " == *" ${lang} "* ]]; then break; fi
      err "Pasirinkimas '$lang' negalimas (${langs[*]})"
    done
    sudo sed -i -e "s/'lang' => '.*'$/'lang' => '${lang}'/" "/var/www/wx/Config.php"
  else
    warn "Kalbu sarasas tuscias – praleidziu"
  fi
else
  warn "Webpanel failai nerasti – praleidziu kalbos nustatyma"
fi

# ---- PHP timezone ----
if [ -f /var/www/wx/header.php ]; then
  echo "Laiko zonu sarasas: https://www.php.net/manual/en/timezones.php"
  read -rp "Ivesk laiko zona (pvz., Europe/Vilnius): " timezone
  tz_escaped=$(echo "${timezone:-Europe/Vilnius}" | sed 's/\//\\\//g')
  sudo sed -i -e "s/date_default_timezone_set('.*');/date_default_timezone_set('${tz_escaped}');/" "/var/www/wx/header.php"
else
  warn "Nerastas /var/www/wx/header.php – praleidziu laiko zonos nustatyma"
fi

# ---- coords/timeoffset ----
read -rp "Platuma (pvz., 55.57): " lat
read -rp "Ilguma (pvz., 24.25): " lon
read -rp "Laiko zonos offset (Vasara 3, Ziema 2): " tzoffset
[ -f "$HOME/.noaa.conf" ]             && sed -i -e "s/change_latitude/${lat}/g;s/change_longitude/${lon}/g" "$HOME/.noaa.conf" || true
[ -f "$HOME/.wxtoimgrc" ]             && sed -i -e "s/change_latitude/${lat}/g;s/change_longitude/${lon}/g" "$HOME/.wxtoimgrc" || true
[ -f "$HOME/.predict/predict.qth" ]   && sed -i -e "s/change_latitude/${lat}/g;s/change_longitude/$(echo "$lon * -1" | bc)/g" "$HOME/.predict/predict.qth" || true
[ -f "$REPO_DIR/sun.py" ]             && sed -i -e "s/change_latitude/${lat}/g;s/change_longitude/${lon}/g;s/change_tz/$(echo "$tzoffset * -1" | bc)/g" "$REPO_DIR/sun.py" || true

ok "Nustatymai pritaikyti. Patikrink $HOME/.noaa.conf"

echo
echo "Twitter nustatymai – faile: $HOME/.tweepy.conf"
echo

# ---- WXTOIMG license acceptance (tik jei idiegtas) ----
set +e
if command -v xwxtoimg >/dev/null 2>&1; then
  echo "WxToIMG idiegtas. Jei reikia, paleisk licencijos langa: xwxtoimg"
else
  warn "WxToIMG neidiegtas – licencijos lango nepraleidinesim."
fi
set -e

echo
echo "Atsiunciami palydovu laikai (testinis grafikas)..."
[ -x "$REPO_DIR/schedule.sh" ] || chmod +x "$REPO_DIR/schedule.sh" 2>/dev/null || true
[ -x "$REPO_DIR/schedule_iss.sh" ] || chmod +x "$REPO_DIR/schedule_iss.sh" 2>/dev/null || true
"$REPO_DIR/schedule.sh" -t -x || true

echo
echo "Sistema bus perkrauta..."
sudo reboot
