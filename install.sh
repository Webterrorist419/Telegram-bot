#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="simple-telegram-bot"
APP_DIR="/opt/simple-telegram-bot"
BACKUP_DIR="/var/backups/simple-telegram-bot"
DATA_DIR="/var/lib/simple-telegram-bot"
BUILD_DIR_FILE="$DATA_DIR/build-dir"
SERVICE="simple-telegram-bot.service"
CONFIG="$APP_DIR/config.env"
ADMIN_BIN="/usr/local/bin/bot-admin"
REPO_URL="${BOT_REPO_URL:-}"
LANGUAGE="ru"

trn() { if [[ "$LANGUAGE" == "ru" ]]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }
pause() { read -r -p "$(trn 'Нажмите Enter для продолжения...' 'Press Enter to continue...')" _ || true; }
need_root() { if [[ "$(id -u)" -ne 0 ]]; then echo "$(trn 'Запустите скрипт через sudo.' 'Run this script with sudo.')"; exit 1; fi; }

choose_language() {
  echo "1) Русский / Russian"
  echo "2) English / Английский"
  read -r -p "Language [1/2]: " choice
  [[ "$choice" == "2" ]] && LANGUAGE="en" || LANGUAGE="ru"
}

install_system_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl git build-essential pkg-config libssl-dev sqlite3
  if ! command -v cargo >/dev/null 2>&1; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
  fi
  export PATH="/root/.cargo/bin:$PATH"
  if ! command -v cargo >/dev/null 2>&1; then
    echo "$(trn 'Не удалось установить Rust/Cargo.' 'Could not install Rust/Cargo.')" >&2; exit 1
  fi
}

ask_repo() {
  if [[ -z "$REPO_URL" ]]; then
    read -r -p "$(trn 'URL GitHub репозитория (HTTPS или SSH): ' 'GitHub repository URL (HTTPS or SSH): ')" REPO_URL
  fi
  [[ -n "$REPO_URL" ]] || { echo "$(trn 'URL репозитория обязателен.' 'Repository URL is required.')"; return 1; }
}

install_bot() {
  need_root
  local self
  self="$(realpath "$0")"
  install -D -m 755 "$self" "$ADMIN_BIN"
  if [[ -f "$APP_DIR/Cargo.toml" && -f "/etc/systemd/system/$SERVICE" ]]; then
    echo "$(trn 'Бот уже установлен. Открываю меню bot-admin.' 'Bot is already installed. Opening the bot-admin menu.')"
    menu
    return
  fi
  if [[ -d "$APP_DIR/.git" ]]; then echo "$(trn 'Каталог установки уже существует. Продолжаю настройку.' 'Installation directory already exists. Continuing setup.')"; fi
  local source_dir source_origin
  source_dir="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
  source_origin=""
  if [[ -f "$source_dir/bot.rs" && -f "$source_dir/Cargo.toml" && -d "$source_dir/.git" ]]; then
    source_origin="$(git -C "$source_dir" remote get-url origin 2>/dev/null || true)"
  fi
  if [[ ! -f "$source_dir/bot.rs" || ! -f "$source_dir/Cargo.toml" ]]; then ask_repo || return; fi
  install_system_packages
  mkdir -p "$(dirname "$APP_DIR")"
  if [[ -n "$source_origin" ]]; then
    git clone "$source_origin" "$APP_DIR"
    BUILD_DIR="$APP_DIR"
  elif [[ -f "$source_dir/bot.rs" && -f "$source_dir/Cargo.toml" ]]; then
    mkdir -p "$APP_DIR"
    tar --exclude='./.git' --exclude='./target' --exclude='./config.env' --exclude='./bot.sqlite3' --exclude='./bot.sqlite3-shm' --exclude='./bot.sqlite3-wal' -C "$source_dir" -cf - . | tar -C "$APP_DIR" -xf -
    BUILD_DIR="$source_dir"
    REPO_URL=""
  else
    git clone "$REPO_URL" "$APP_DIR"
    BUILD_DIR="$APP_DIR"
  fi
  [[ -f "$APP_DIR/bot.rs" && -f "$APP_DIR/Cargo.toml" ]] || { echo "$(trn 'В репозитории нет bot.rs или Cargo.toml.' 'Repository is missing bot.rs or Cargo.toml.')" >&2; return 1; }
  [[ -f "$CONFIG" ]] || cp "$APP_DIR/config.env.example" "$CONFIG"
  getent passwd simplebot >/dev/null || useradd --system --home-dir "$DATA_DIR" --shell /usr/sbin/nologin simplebot
  install -d -o simplebot -g simplebot -m 750 "$DATA_DIR"
  printf '%s\n' "$BUILD_DIR" > "$BUILD_DIR_FILE"
  sed -i "s|^DATABASE_PATH=.*|DATABASE_PATH=$DATA_DIR/bot.sqlite3|" "$CONFIG"
  chown root:simplebot "$CONFIG"
  chmod 640 "$CONFIG"
  build_bot
  write_service
  echo "$(trn 'Сборка завершена. Введите данные бота для запуска.' 'Build complete. Enter the bot credentials to start it.')"
  configure_credentials
  echo "$(trn 'Открываю меню bot-admin.' 'Opening the bot-admin menu.')"
  menu
}

build_bot() {
  export PATH="/root/.cargo/bin:$PATH"
  local build_dir="$APP_DIR"
  if [[ -f "$BUILD_DIR_FILE" ]]; then IFS= read -r build_dir < "$BUILD_DIR_FILE"; fi
  [[ -f "$build_dir/Cargo.toml" ]] || build_dir="$APP_DIR"
  cargo build --release --manifest-path "$build_dir/Cargo.toml" --bin simple-telegram-bot
  if [[ "$build_dir" != "$APP_DIR" ]]; then
    install -D -m 755 "$build_dir/target/release/simple-telegram-bot" "$APP_DIR/target/release/simple-telegram-bot"
  fi
  ensure_executable
}

ensure_executable() {
  local binary="$APP_DIR/target/release/simple-telegram-bot"
  if [[ -f "$binary" ]]; then
    chmod 755 "$APP_DIR" "$APP_DIR/target" "$APP_DIR/target/release" "$binary"
  fi
}

write_service() {
  cat > "/etc/systemd/system/$SERVICE" <<EOF
[Unit]
Description=Simple Telegram bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=simplebot
Group=simplebot
WorkingDirectory=$APP_DIR
EnvironmentFile=$CONFIG
ExecStart=$APP_DIR/target/release/simple-telegram-bot
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$SERVICE" >/dev/null
}

restart_bot() {
  need_root
  ensure_executable
  systemctl restart "$SERVICE"
  systemctl --no-pager --full status "$SERVICE" || true
}

configure_credentials() {
  need_root
  [[ -d "$APP_DIR" ]] || { echo "$(trn 'Сначала установите бота.' 'Install the bot first.')"; return; }
  local token admin
  read -r -p "$(trn 'Токен Telegram бота (ввод отображается): ' 'Telegram bot token (input is visible): ')" token
  read -r -p "$(trn 'Telegram ID администратора: ' 'Administrator Telegram ID: ')" admin
  [[ -n "$token" && "$admin" =~ ^[1-9][0-9]*$ ]] || { echo "$(trn 'Нужны непустой токен и положительный числовой Telegram ID.' 'A non-empty token and positive numeric Telegram ID are required.')"; return 1; }
  umask 077
  cat > "$CONFIG" <<EOF
BOT_TOKEN=$token
ADMIN_ID=$admin
DATABASE_PATH=$DATA_DIR/bot.sqlite3
EOF
  chown root:simplebot "$CONFIG"
  chmod 640 "$CONFIG"
  restart_bot
}

clear_credentials() {
  need_root
  [[ -d "$APP_DIR" ]] || { echo "$(trn 'Бот не установлен.' 'Bot is not installed.')"; return; }
  cat > "$CONFIG" <<'EOF'
BOT_TOKEN=
ADMIN_ID=
DATABASE_PATH=$DATA_DIR/bot.sqlite3
EOF
  chown root:simplebot "$CONFIG"
  chmod 640 "$CONFIG"
  systemctl stop "$SERVICE" 2>/dev/null || true
  echo "$(trn 'Токен и ID очищены. Сервис остановлен до ввода новых данных.' 'Token and ID cleared. Service is stopped until new credentials are entered.')"
}

update_bot() {
  need_root
  [[ -d "$APP_DIR" ]] || { echo "$(trn 'Бот не установлен.' 'Bot is not installed.')"; return; }
  export PATH="/root/.cargo/bin:$PATH"
  if [[ -d "$APP_DIR/.git" ]]; then
    git -C "$APP_DIR" pull --ff-only
    printf '%s\n' "$APP_DIR" > "$BUILD_DIR_FILE"
    build_bot
  else
    ask_repo || return
    local tmp
    tmp="$(mktemp -d /opt/simple-telegram-bot-update.XXXXXX)"
    git clone "$REPO_URL" "$tmp"
    [[ -f "$tmp/bot.rs" && -f "$tmp/Cargo.toml" ]] || { rm -rf -- "$tmp"; echo "$(trn 'В репозитории нет файлов бота.' 'Repository does not contain bot files.')"; return 1; }
    local cache_dir="$APP_DIR"
    if [[ -f "$BUILD_DIR_FILE" ]]; then IFS= read -r cache_dir < "$BUILD_DIR_FILE"; fi
    [[ -d "$cache_dir" ]] || cache_dir="$APP_DIR"
    CARGO_TARGET_DIR="$cache_dir/target" cargo build --release --manifest-path "$tmp/Cargo.toml" --bin simple-telegram-bot
    tar --exclude='./.git' --exclude='./target' --exclude='./config.env' --exclude='./bot.sqlite3' --exclude='./bot.sqlite3-shm' --exclude='./bot.sqlite3-wal' -C "$tmp" -cf - . | tar -C "$APP_DIR" -xf -
    cp -a "$tmp/.git" "$APP_DIR/.git"
    if [[ "$cache_dir" != "$APP_DIR" ]]; then
      mkdir -p "$APP_DIR/target"
      cp -a "$cache_dir/target/." "$APP_DIR/target/"
    fi
    printf '%s\n' "$APP_DIR" > "$BUILD_DIR_FILE"
    rm -rf -- "$tmp"
  fi
  cp "$APP_DIR/install.sh" "$ADMIN_BIN"
  chmod 755 "$ADMIN_BIN"
  write_service
  restart_bot
}

backup_db() {
  need_root
  [[ -f "$DATA_DIR/bot.sqlite3" ]] || { echo "$(trn 'База данных ещё не создана.' 'Database has not been created yet.')"; return; }
  mkdir -p "$BACKUP_DIR"
  local file="$BACKUP_DIR/bot-$(date +%Y%m%d-%H%M%S).sqlite3"
  sqlite3 "$DATA_DIR/bot.sqlite3" ".backup '$file'"
  chmod 600 "$file"
  echo "$(trn 'Резервная копия создана: ' 'Backup created: ')$file"
}

import_db() {
  need_root
  [[ -d "$APP_DIR" ]] || { echo "$(trn 'Сначала установите бота.' 'Install the bot first.')"; return; }
  local file
  read -r -p "$(trn 'Полный путь к файлу SQLite для импорта: ' 'Full path to the SQLite file to import: ')" file
  [[ -f "$file" ]] || { echo "$(trn 'Файл не найден.' 'File not found.')"; return 1; }
  [[ "$file" != "$DATA_DIR/bot.sqlite3" ]] || { echo "$(trn 'Выбран текущий файл базы.' 'The current database file was selected.')"; return 1; }
  sqlite3 "$file" 'PRAGMA integrity_check;' | grep -qx 'ok' || { echo "$(trn 'Проверка SQLite не пройдена.' 'SQLite integrity check failed.')"; return 1; }
  sqlite3 "$file" "SELECT name FROM sqlite_master WHERE type='table' AND name='users';" | grep -qx 'users' || { echo "$(trn 'В файле нет таблицы users.' 'The file does not contain the users table.')"; return 1; }
  mkdir -p "$BACKUP_DIR"
  systemctl stop "$SERVICE" 2>/dev/null || true
  if [[ -f "$DATA_DIR/bot.sqlite3" ]]; then sqlite3 "$DATA_DIR/bot.sqlite3" ".backup '$BACKUP_DIR/pre-import-$(date +%Y%m%d-%H%M%S).sqlite3'"; fi
  cp "$file" "$DATA_DIR/bot.sqlite3"
  chown simplebot:simplebot "$DATA_DIR/bot.sqlite3"
  chmod 600 "$DATA_DIR/bot.sqlite3"
  restart_bot
}

uninstall_bot() {
  need_root
  echo "$(trn 'Это удалит сервис, исходный код, базу данных, настройки и все резервные копии.' 'This removes the service, source code, database, settings, and all backups.')"
  read -r -p "$(trn 'Для подтверждения введите DELETE: ' 'Type DELETE to confirm: ')" confirm
  [[ "$confirm" == "DELETE" ]] || { echo "$(trn 'Удаление отменено.' 'Uninstall cancelled.')"; return; }
  systemctl disable --now "$SERVICE" 2>/dev/null || true
  rm -f "/etc/systemd/system/$SERVICE" "$ADMIN_BIN"
  systemctl daemon-reload
  rm -rf -- "$APP_DIR" "$BACKUP_DIR"
  userdel simplebot 2>/dev/null || true
  rm -rf -- "$DATA_DIR"
  echo "$(trn 'Бот полностью удалён.' 'Bot fully removed.')"
}

menu() {
  while true; do
    echo
    echo "=== bot-admin ==="
    echo "1) $(trn 'Установить бота' 'Install bot')"
    echo "2) $(trn 'Настроить токен и ID (токен виден при вводе)' 'Set token and ID (token visible while typing)')"
    echo "3) $(trn 'Очистить токен и ID' 'Clear token and ID')"
    echo "4) $(trn 'Обновить бота' 'Update bot')"
    echo "5) $(trn 'Экспорт базы данных / бэкап' 'Export database / backup')"
    echo "6) $(trn 'Импорт базы данных' 'Import database')"
    echo "7) $(trn 'Удалить бота начисто' 'Completely uninstall bot')"
    echo "0) $(trn 'Выход' 'Exit')"
    read -r -p "$(trn 'Выберите пункт: ' 'Choose an option: ')" action
    case "$action" in
      1) install_bot; pause;; 2) configure_credentials; pause;; 3) clear_credentials; pause;;
      4) update_bot; pause;; 5) backup_db; pause;; 6) import_db; pause;; 7) uninstall_bot; pause;;
      0) exit 0;; *) echo "$(trn 'Неверный пункт.' 'Invalid option.')";;
    esac
  done
}

choose_language
if [[ "${1:-}" == "--install" ]]; then install_bot; exit; fi
if [[ "${1:-}" == "--update" ]]; then update_bot; exit; fi

# Running this file directly from a checkout installs the project immediately.
# The installed bot-admin command opens the management menu on later runs.
SCRIPT_PATH="$(realpath "$0")"
INSTALLED_SCRIPT="$(realpath "$ADMIN_BIN" 2>/dev/null || true)"
CHECKOUT_SCRIPT="$(realpath "$APP_DIR/install.sh" 2>/dev/null || true)"
if [[ "$SCRIPT_PATH" == "$INSTALLED_SCRIPT" || "$SCRIPT_PATH" == "$CHECKOUT_SCRIPT" ]]; then
  menu
else
  install_bot
fi
