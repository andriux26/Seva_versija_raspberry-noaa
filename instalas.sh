#!/usr/bin/env bash
set -euo pipefail

# ---------- KONFIGAS ----------
REPO_URL="https://github.com/andriux26/Seva_versija_raspberry-noaa.git"

APP_USER="${SUDO_USER:-${USER}}"
APP_HOME="/home/${APP_USER}"
APP_DIR="${APP_HOME}/Seva_versija_raspberry-noaa"
VENV_DIR="${APP_DIR}/.venv"

WEB_ROOT="${APP_HOME}/raspberry-noaa/www"
LOG_DIR="${APP_HOME}/raspberry-noaa"
NGINX_SITE="/etc/nginx/sites-available/rasp-noaa"
NGINX_LINK="/etc/nginx/sites-enabled/rasp-noaa"

CRON_LINE="*/15 * * * * ${APP_DIR}/schedule.sh >> ${LOG_DIR}/schedule.log 2>&1"

# ---------- VĖLIAVOS ----------
DO_INSTALL=false
FORCE_REINSTALL=false
for a in "$@"; do
  case "$a" in
    --install) DO_INSTALL=true ;;
    --force) FORCE_REINSTALL=true ;;
    *) echo "Naudojimas: sudo $0 --install [--force]"; exit 1 ;;
  esac
done
if ! $DO_INSTALL; then echo "Naudojimas: sudo $0 --install [--force]"; exit 1; fi

# ---------- FUNKCIJOS ----------
need_root() { [[ "$(id -u)" -eq 0 ]] || { echo "Paleisk su sudo"; exit 1; }; }

apt_install() {
  echo "[1/7] Atnaujinu OS ir diegiu paketus..."
  apt-get update -y

  # Nustatom OS versiją
  OS_CODENAME=$(lsb_release -sc || echo "unknown")
  echo "→ OS versija: $OS_CODENAME"

  # Bendri paketai
  PKGS="git python3 python3-venv python3-pip \
    rtl-sdr sox imagemagick bc jq curl coreutils sed gawk \
    ntp cron nginx"

  # Hamlib pagal OS
  case "$OS_CODENAME" in
    bookworm|trixie|sid)
      PKGS="$PKGS libhamlib-utils libhamlib4"
      ;;
    bullseye|buster)
      PKGS="$PKGS hamlib"
      ;;
    *)
      echo "⚠️  Neatpažinta OS ($OS_CODENAME) — bandau su libhamlib-utils libhamlib4"
      PKGS="$PKGS libhamlib-utils libhamlib4"
      ;;
  esac

  DEBIAN_FRONTEND=noninteractive apt-get install -y $PKGS
  systemctl enable --now cron || true
  systemctl enable --now nginx || true
}

fresh_clone() {
  echo "[2/7] Paruošiu katalogus..."
  mkdir -p "${APP_HOME}" "${WEB_ROOT}" "${LOG_DIR}"
  chown -R "${APP_USER}:${APP_USER}" "${APP_HOME}"

  if [[ -d "${APP_DIR}" ]]; then
    if $FORCE_REINSTALL; then
      echo "  --force: trinamas senas ${APP_DIR}"
      rm -rf "${APP_DIR}"
    else
      echo "Katalogas ${APP_DIR} jau yra. Jei nori švariai perrašyti – paleisk su --force."
      exit 2
    fi
  fi

  echo "[3/7] Klonuoju repo..."
  sudo -u "${APP_USER}" bash -lc "cd '${APP_HOME}' && git clone '${REPO_URL}'"
  sudo -u "${APP_USER}" bash -lc "cd '${APP_DIR}' && git submodule update --init --recursive || true"
}

setup_venv() {
  echo "[4/7] Python venv + priklausomybės..."
  sudo -u "${APP_USER}" bash -lc "
    cd '${APP_DIR}' && \
    python3 -m venv '${VENV_DIR}' && \
    source '${VENV_DIR}/bin/activate' && \
    python -m pip install --upgrade pip wheel setuptools && \
    if [ -f requirements.txt ]; then pip install -r requirements.txt; fi
  "
}

run_project_install() {
  echo "[5/7] Projekto install.sh (jei yra)..."
  if [[ -x "${APP_DIR}/install.sh" ]]; then
    bash "${APP_DIR}/install.sh" || true
  else
    echo "  install.sh nerastas arba ne vykdomas — tęsiu be jo."
  fi
}

setup_nginx() {
  echo "[6/7] Nginx konfigūracija..."
  cat >"${NGINX_SITE}" <<NG
server {
    listen 80 default_server;
    server_name _;
    root ${WEB_ROOT};
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
NG
  ln -sf "${NGINX_SITE}" "${NGINX_LINK}"
  nginx -t
  systemctl reload nginx || systemctl restart nginx
  chown -R "${APP_USER}:${APP_USER}" "${WEB_ROOT}" "${LOG_DIR}"
}

setup_cron() {
  echo "[7/7] Cron įrašas planuotojui..."
  crontab -u "${APP_USER}" -l 2>/dev/null | grep -F "${CRON_LINE}" >/dev/null || \
    ( crontab -u "${APP_USER}" -l 2>/dev/null; echo "${CRON_LINE}" ) | crontab -u "${APP_USER}" -
  echo "Dabartinis ${APP_USER} crontab:"
  crontab -u "${APP_USER}" -l
}

smoke_test() {
  echo
  echo "[TEST] Paleidžiu schedule.sh vieną kartą (sausai)..."
  if [[ -x "${APP_DIR}/schedule.sh" ]]; then
    sudo -u "${APP_USER}" bash -lc "cd '${APP_DIR}' && bash schedule.sh || true"
  else
    echo "  Įspėjimas: ${APP_DIR}/schedule.sh nerastas."
  fi
  echo
  echo "⇒ Web turinys: ${WEB_ROOT}"
  echo "⇒ Žurnalai   : ${LOG_DIR}/schedule.log (po pirmų paleidimų)"
  echo "⇒ Atverk naršyklėje: http://<tavo_PI_IP>/"
}

# ---------- VYKDYMAS ----------
need_root
apt_install
fresh_clone
setup_venv
run_project_install
setup_nginx
setup_cron
smoke_test

echo
echo "✅ Diegimas baigtas."
echo "Repo: ${APP_DIR}"
echo "Venv: source ${VENV_DIR}/bin/activate"
