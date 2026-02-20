#!/bin/bash

# Проверка root
if [[ $EUID -ne 0 ]]; then
  echo "Ошибка: скрипт нужно запускать от root" >&2
  exit 1
fi

INSTALL_WARP=false
EXTENDED_SETUP=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --warp)
            INSTALL_WARP=true
            shift
            ;;
        --extend)
            EXTENDED_SETUP=true
            shift
            ;;
        *)
            echo "Неизвестный аргумент: $1" >&2
            exit 1
            ;;
    esac
done

# Проверяем наличие команды x-ui
if command -v x-ui &> /dev/null; then
    echo "Обнаружена установленная панель x-ui."

    # Запрос у пользователя на переустановку
    read -p "Вы хотите переустановить x-ui? [y/N]: " confirm
    confirm=${confirm,,}  # перевод в нижний регистр

    if [[ "$confirm" != "y" && "$confirm" != "yes" ]]; then
        echo "Отмена. Скрипт завершает работу."
        exit 1
    fi

    echo "Удаление x-ui..."
    # Тихое удаление x-ui (если установлен через официальный скрипт)
    /usr/local/x-ui/x-ui uninstall -y &>/dev/null || true
    rm -rf /usr/local/x-ui /etc/x-ui /usr/bin/x-ui /etc/systemd/system/x-ui.service
    systemctl daemon-reexec
    systemctl daemon-reload
    rm /root/3x-ui.txt
    echo "x-ui успешно удалена. Продолжаем выполнение скрипта..."
fi

# Вывод всех команд кроме диалога — в лог
exec 3>&1  # Сохраняем stdout для сообщений пользователю
LOG_FILE="/var/log/3x-ui_install_log.txt"
exec > >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2)

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

# === Порт панели: по умолчанию 8080, а при аргументе extend — ручной выбор ===
if [[ "$EXTENDED_SETUP" == true ]]; then
    read -rp $'\033[0;33mВведите порт для панели (Enter для 8080): \033[0m' USER_PORT
    PORT=${USER_PORT:-8080}

    # === Вопрос о SelfSNI ===
    echo -e "\n${yellow}Хотите установить SelfSNI (поддельный сайт для маскировки)?${plain}"
    read -rp $'\033[0;36mВведите y для установки или нажмите Enter для пропуска: \033[0m' INSTALL_SELFSNI
    if [[ "$INSTALL_SELFSNI" == "y" || "$INSTALL_SELFSNI" == "Y" ]]; then
        echo -e "${green}Устанавливается SelfSNI...${plain}" >&3
        bash <(curl -Ls https://raw.githubusercontent.com/YukiKras/vless-scripts/refs/heads/main/fakesite.sh)
    else
        echo -e "${yellow}Установка SelfSNI пропущена.${plain}" >&3
    fi
else
    PORT=8080
    echo -e "${yellow}Порт панели не указан, используется по умолчанию: ${PORT}${plain}" >&3
fi

echo -e "Весь процесс установки будет сохранён в файле: \033[0;36m${LOG_FILE}\033[0m" >&3
echo -e "\n\033[1;34mИдёт установка... Пожалуйста, не закрывайте терминал.\033[0m"

# Генерация
gen_random_string() {
    local length="$1"
    LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w "$length" | head -n 1
}
USERNAME=$(gen_random_string 10)
PASSWORD=$(gen_random_string 10)
WEBPATH=$(gen_random_string 18)

# Определение ОС
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    release=$ID
else
    echo "Не удалось определить ОС" >&3
    exit 1
fi

arch() {
    case "$(uname -m)" in
        x86_64 | x64 | amd64) echo 'amd64' ;;
        i*86 | x86) echo '386' ;;
        armv8* | arm64 | aarch64) echo 'arm64' ;;
        armv7* | arm) echo 'armv7' ;;
        armv6*) echo 'armv6' ;;
        armv5*) echo 'armv5' ;;
        s390x) echo 's390x' ;;
        *) echo "unknown" ;;
    esac
}
ARCH=$(arch)

# Установка зависимостей
case "${release}" in
    ubuntu | debian | armbian)
        apt-get update > /dev/null 2>&1
        apt-get install -y -q wget curl tar tzdata jq xxd qrencode > /dev/null 2>&1
        ;;
    centos | rhel | almalinux | rocky | ol)
        yum -y update > /dev/null 2>&1
        yum install -y -q wget curl tar tzdata jq xxd qrencode > /dev/null 2>&1
        ;;
    fedora | amzn | virtuozzo)
        dnf -y update > /dev/null 2>&1
        dnf install -y -q wget curl tar tzdata jq xxd qrencode > /dev/null 2>&1
        ;;
    arch | manjaro | parch)
        pacman -Syu --noconfirm > /dev/null 2>&1
        pacman -S --noconfirm wget curl tar tzdata jq xxd qrencode > /dev/null 2>&1
        ;;
    opensuse-tumbleweed)
        zypper refresh > /dev/null 2>&1
        zypper install -y wget curl tar timezone jq xxd qrencode > /dev/null 2>&1
        ;;
    *)
        apt-get update > /dev/null 2>&1
        apt-get install -y wget curl tar tzdata jq xxd qrencode > /dev/null 2>&1
        ;;
esac

# Установка x-ui
cd /usr/local/ || exit 1

# tag_version=$(curl -Ls "https://api.github.com/repos/cryptowergo/4x-ui/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
# use fixed tag version
tag_version="v1.0.1"

ZIP_FILE="x-ui-linux-${ARCH}.tar.gz"
TAR_FILE="x-ui-linux-${ARCH}.tar.gz"

URL="https://github.com/cryptowergo/4x-ui/releases/download/${tag_version}/${ZIP_FILE}"

echo "Скачиваем ${URL}..."

if wget -q -O "${ZIP_FILE}" "${URL}"; then
    echo "Успешно скачали ${ZIP_FILE}"
else
    echo "Ошибка скачивания"
    exit 1
fi

systemctl stop x-ui 2>/dev/null
rm -rf /usr/local/x-ui/

# Распаковываем zip вместо tar.gz
# unzip x-ui-linux-${ARCH}.zip
# rm -f x-ui-linux-${ARCH}.zip

tar -xzf x-ui-linux-${ARCH}.tar.gz
rm -f x-ui-linux-${ARCH}.tar.gz

cd x-ui || exit 1
chmod +x x-ui
[[ "$ARCH" == armv* ]] && mv bin/xray-linux-${ARCH} bin/xray-linux-arm && chmod +x bin/xray-linux-arm
chmod +x x-ui bin/xray-linux-${ARCH}
cp -f x-ui.service.debian /etc/systemd/system/x-ui.service

URL1="https://raw.githubusercontent.com/cryptowergo/4x-ui/main/x-ui.sh"
FILE="/usr/bin/x-ui"

if ! wget -q -O "$FILE" "$URL1"; then
    echo "Не удалось скачать с GitHub, пробую зеркало..."
fi

chmod +x /usr/local/x-ui/x-ui.sh /usr/bin/x-ui

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "[!] Missing: $1"; exit 1; }; }
need_cmd install
need_cmd id

XRAY_USER="xray"

# ============================================================
# 0) ENSURE XRAY USER EXISTS
# ============================================================
if ! id -u "$XRAY_USER" >/dev/null 2>&1; then
  echo "[*] Creating system user: $XRAY_USER"
  useradd --system --no-create-home --shell /usr/sbin/nologin "$XRAY_USER"
fi

XRAY_UID="$(id -u "$XRAY_USER")"
echo "[*] $XRAY_USER uid: $XRAY_UID"

fix_xray_permissions() {
  local u="$1"

  # 1) /usr/local/x-ui/bin must be writable for generated config
  install -d -m 0750 -o "$u" -g "$u" /usr/local/x-ui/bin

  # config.json is generated/overwritten by root during install/update -> force owner every time
  touch /usr/local/x-ui/bin/config.json
  chown "$u:$u" /usr/local/x-ui/bin/config.json
  chmod 0640 /usr/local/x-ui/bin/config.json

  # xray binary must be executable
  chmod +x /usr/local/x-ui/x-ui 2>/dev/null || true
  chmod +x /usr/local/x-ui/bin/xray-linux-* 2>/dev/null || true

  # 2) /etc/x-ui should be accessible (db/env)
  install -d -m 0750 -o root -g "$u" /etc/x-ui

  # db.env readable by xray, writable only by root
  if [[ -f /etc/x-ui/db.env ]]; then
    chown root:"$u" /etc/x-ui/db.env
    chmod 0640 /etc/x-ui/db.env
  fi

  # sqlite/db files must be writable by xray if panel uses them
  for f in /etc/x-ui/*.db /etc/x-ui/*.sqlite; do
    [[ -f "$f" ]] || continue
    chown "$u:$u" "$f"
    chmod 0640 "$f"
  done

  # 3) logs: xray wants /var/log/xray/access.log etc
  install -d -m 0750 -o "$u" -g "$u" /var/log/xray
  touch /var/log/xray/access.log /var/log/xray/error.log
  chown "$u:$u" /var/log/xray/access.log /var/log/xray/error.log
  chmod 0640 /var/log/xray/access.log /var/log/xray/error.log
}

fix_xray_permissions "$XRAY_USER"

# -----------------------------
# 1️⃣ Устанавливаем PostgreSQL
# -----------------------------
echo "Устанавливаем PostgreSQL..."
apt update
apt install -y postgresql postgresql-contrib

# -----------------------------
# 2️⃣ Генерация пользователя и пароля для DB
# -----------------------------
DB_TYPE="postgres"
DB_USER="xui_$(openssl rand -hex 4)"
DB_PASSWORD="$(openssl rand -base64 16)"
DB_NAME="xui"
DB_HOST="127.0.0.1"
DB_PORT="5432"
DB_SSLMODE="disable"

# Сохраняем данные в приватный файл
echo "DB_USER=$DB_USER" > /root/3x-db.txt
echo "DB_PASSWORD=$DB_PASSWORD" >> /root/3x-db.txt
chmod 600 /root/3x-db.txt
echo "Данные для доступа к БД сохранены в /root/3x-db.txt"

ensure_postgres_running() {
  echo "[*] Ensuring PostgreSQL is installed & running..."

  # install (idempotent)
  if ! command -v psql >/dev/null 2>&1; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql postgresql-contrib
  fi

  # enable/start the real cluster unit (Ubuntu way)
  # 1) if cluster exists: start it
  if command -v pg_lsclusters >/dev/null 2>&1; then
    # start all clusters that are down (safe)
    while read -r ver name port status owner datadir log; do
      [[ "$ver" == "Ver" ]] && continue
      if [[ "$status" != "online" ]]; then
        echo "[*] Starting cluster: ${ver} ${name}"
        pg_ctlcluster "$ver" "$name" start || true
      fi
    done < <(pg_lsclusters | awk '{print $1, $2, $3, $4, $5, $6, $7}')
  fi

  # 2) enable systemd units (idempotent)
  systemctl enable --now postgresql >/dev/null 2>&1 || true
  # prefer конкретный юнит 16-main если существует
  if systemctl list-unit-files | grep -q '^postgresql@16-main\.service'; then
    systemctl enable --now postgresql@16-main >/dev/null 2>&1 || true
  fi

  # 3) wait until ready
  # pg_isready is best; fallback to socket existence / ss
  if command -v pg_isready >/dev/null 2>&1; then
    for i in {1..30}; do
      if pg_isready -h 127.0.0.1 -p 5432 >/dev/null 2>&1; then
        echo "[*] PostgreSQL is ready on 127.0.0.1:5432"
        return 0
      fi
      sleep 1
    done
    echo "[!] PostgreSQL not ready after 30s" >&2
    systemctl status postgresql --no-pager || true
    systemctl status postgresql@16-main --no-pager || true
    exit 1
  else
    # fallback
    for i in {1..30}; do
      ss -lntp 2>/dev/null | grep -q ':5432' && return 0
      sleep 1
    done
    echo "[!] PostgreSQL not listening on 5432 after 30s" >&2
    exit 1
  fi
}

ensure_postgres_running

# -----------------------------
# 3️⃣ Удаляем старые базы и пользователей с таким именем
# -----------------------------
echo "[*] Recreating DB/user..."

sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  -- terminate connections if DB exists
  PERFORM pg_terminate_backend(pid)
  FROM pg_stat_activity
  WHERE datname = '${DB_NAME}' AND pid <> pg_backend_pid();
EXCEPTION WHEN undefined_table THEN
  NULL;
END
\$\$;

DROP DATABASE IF EXISTS "${DB_NAME}";
DROP ROLE IF EXISTS "${DB_USER}";

CREATE ROLE "${DB_USER}" LOGIN PASSWORD '${DB_PASSWORD}';
CREATE DATABASE "${DB_NAME}" OWNER "${DB_USER}";

\c "${DB_NAME}"

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_stat_statements";

ALTER SCHEMA public OWNER TO "${DB_USER}";
GRANT ALL PRIVILEGES ON SCHEMA public TO "${DB_USER}";

-- Grant additional permissions to the user
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO "${DB_USER}";
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO "${DB_USER}";
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO "${DB_USER}";

-- Set default privileges for future objects
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO "${DB_USER}";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO "${DB_USER}";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO "${DB_USER}";
SQL

echo "[*] Creating schema objects..."

sudo -u postgres psql -v ON_ERROR_STOP=1 -d "${DB_NAME}" <<SQL
CREATE TABLE IF NOT EXISTS public.v2ray_clients
(
    id                bigserial PRIMARY KEY,
    device_id         varchar(255)                            NOT NULL,
    server_ip         inet                                    NOT NULL,
    inbound_id        integer                                 NOT NULL,
    uuid              uuid                                    NOT NULL,
    email             varchar(255)                            NOT NULL,
    enabled           boolean                   DEFAULT true   NOT NULL,
    created_at        timestamp with time zone  DEFAULT now()  NOT NULL,
    updated_at        timestamp with time zone  DEFAULT now()  NOT NULL,
    revoked_at        timestamp,
    expires_at        timestamp with time zone  DEFAULT now()  NOT NULL,
    cleanup_failed_at timestamp with time zone,
    expiry_time       bigint                                  NOT NULL
);

-- owner (если хочешь держать владельца = DB_USER)
ALTER TABLE public.v2ray_clients OWNER TO "${DB_USER}";

-- Индексы / уникальности
CREATE UNIQUE INDEX IF NOT EXISTS uq_v2ray_clients_active_device_server
    ON public.v2ray_clients (device_id, server_ip)
    WHERE (enabled = true AND revoked_at IS NULL);

CREATE UNIQUE INDEX IF NOT EXISTS uq_v2ray_clients_server_inbound_uuid
    ON public.v2ray_clients (server_ip, inbound_id, uuid);

CREATE INDEX IF NOT EXISTS idx_v2ray_clients_device_id
    ON public.v2ray_clients (device_id);

CREATE INDEX IF NOT EXISTS idx_v2ray_clients_server_ip
    ON public.v2ray_clients (server_ip);

CREATE INDEX IF NOT EXISTS idx_v2ray_clients_enabled
    ON public.v2ray_clients (enabled);

CREATE INDEX IF NOT EXISTS idx_v2ray_clients_revoked_at
    ON public.v2ray_clients (revoked_at);

CREATE INDEX IF NOT EXISTS idx_v2ray_clients_expires_at
    ON public.v2ray_clients (expires_at);

CREATE INDEX IF NOT EXISTS idx_v2ray_clients_cleanup_failed_at
    ON public.v2ray_clients (cleanup_failed_at)
    WHERE (cleanup_failed_at IS NOT NULL);

CREATE INDEX IF NOT EXISTS idx_v2ray_clients_expiry_time_active
    ON public.v2ray_clients (expiry_time)
    WHERE (revoked_at IS NULL);
SQL

echo "База пересоздана, таблица v2ray_clients и индексы созданы."

# -----------------------------
# 4️⃣ Создаём env для x-ui
# -----------------------------
mkdir -p /etc/x-ui

cat > /etc/x-ui/db.env <<EOF
DB_TYPE=$DB_TYPE
DB_HOST=$DB_HOST
DB_PORT=$DB_PORT
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASSWORD=$DB_PASSWORD
DB_SSLMODE=$DB_SSLMODE
EOF

chmod 600 /etc/x-ui/db.env
echo "Env-файл для x-ui создан: /etc/x-ui/db.env"

fix_xray_permissions "$XRAY_USER"

# Настройка
echo "USERNAME=$USERNAME"
echo "PASSWORD=$PASSWORD"
echo "PORT=$PORT"
echo "WEBPATH=$WEBPATH"

/usr/local/x-ui/x-ui setting -username "$USERNAME" -password "$PASSWORD" -port "$PORT" -webBasePath "$WEBPATH" >>"$LOG_FILE" 2>&1

echo "EXIT: $?"

echo "[*] Running x-ui migrate..."
/usr/local/x-ui/x-ui migrate >>"$LOG_FILE" 2>&1 || { echo "[!] x-ui migrate failed" >&3; exit 1; }

echo "[*] Waiting for public.inbounds..."
for i in {1..30}; do
  if sudo -u postgres psql -d "$DB_NAME" -tAc "select to_regclass('public.inbounds')" | grep -q inbounds; then
    break
  fi
  sleep 1
done
sudo -u postgres psql -d "$DB_NAME" -tAc "select to_regclass('public.inbounds')" | grep -q inbounds \
  || { echo "[!] table public.inbounds not found after migrate" >&3; exit 1; }
  
# -----------------------------
# 5️⃣ Изменяем тип полей с text на jsonb после миграции
# -----------------------------
echo "Изменяем тип полей settings и stream_settings с text на jsonb..."

# Подключаемся к базе и изменяем типы полей
sudo -u postgres psql -v ON_ERROR_STOP=1 -d "$DB_NAME" <<SQL
-- 0) helper: safe text->jsonb
CREATE OR REPLACE FUNCTION public.try_jsonb(t text)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS \$\$
BEGIN
  RETURN t::jsonb;
EXCEPTION WHEN others THEN
  RETURN '{}'::jsonb;
END;
\$\$;

-- 1) settings -> jsonb (safe)
ALTER TABLE public.inbounds
  ALTER COLUMN settings TYPE jsonb
  USING public.try_jsonb(NULLIF(btrim(settings), ''));

-- 2) stream_settings -> jsonb (safe)
ALTER TABLE public.inbounds
  ALTER COLUMN stream_settings TYPE jsonb
  USING public.try_jsonb(NULLIF(btrim(stream_settings), ''));

-- 3) sniffing -> jsonb (safe)
ALTER TABLE public.inbounds
  ALTER COLUMN sniffing TYPE jsonb
  USING public.try_jsonb(NULLIF(btrim(sniffing), ''));

-- индексы
CREATE INDEX IF NOT EXISTS idx_inbounds_settings_clients
  ON public.inbounds USING gin ((settings->'clients'));

CREATE INDEX IF NOT EXISTS idx_inbounds_stream_settings_security
  ON public.inbounds ((stream_settings->>'security'))
  WHERE stream_settings->>'security' IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_inbounds_protocol
  ON public.inbounds(protocol);

-- проверка
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name = 'inbounds'
  AND column_name IN ('settings','stream_settings','sniffing');
SQL

echo "Миграция и оптимизация базы данных завершены"

systemctl daemon-reload >>"$LOG_FILE" 2>&1
systemctl enable x-ui >>"$LOG_FILE" 2>&1
systemctl start x-ui >>"$LOG_FILE" 2>&1

fix_xray_permissions "$XRAY_USER"

# Генерация Reality ключей
KEYS=$(/usr/local/x-ui/bin/xray-linux-${ARCH} x25519)
PRIVATE_KEY=$(echo "$KEYS" | grep -i "Private" | sed -E 's/.*Key:\s*//')
PUBLIC_KEY=$(echo "$KEYS" | grep -i "Password" | sed -E 's/.*Password:\s*//')
SHORT_ID=$(head -c 8 /dev/urandom | xxd -p)
UUID=$(cat /proc/sys/kernel/random/uuid)
EMAIL=$(tr -dc 'a-z0-9' </dev/urandom | head -c 8)

# === Выбор SNI и DEST с наименьшим пингом ===
DOMAINS=("sso.kinopoisk.ru")
BEST_DOMAIN=""
BEST_PING=9999

echo -e "${green}Оцениваем пинг до рекомендуемых SNI...${plain}" >&3

for domain in "${DOMAINS[@]}"; do
    PING_RESULT=$(ping -c 4 -W 1 "$domain" 2>/dev/null | awk -F'time=' '/time=/{sum+=$2} END{if(NR>0) printf "%.2f", sum/NR}')
    if [[ -n "$PING_RESULT" ]]; then
        echo -e "  $domain: ${PING_RESULT} ms" >&3
        PING_MS=$(printf "%.0f" "$PING_RESULT")
        if [[ "$PING_MS" -lt "$BEST_PING" ]]; then
            BEST_PING=$PING_MS
            BEST_DOMAIN=$domain
        fi
    else
        echo -e "  $domain: \033[0;31mнедоступен\033[0m" >&3
    fi
done

if [[ -z "$BEST_DOMAIN" ]]; then
    echo -e "${red}Не удалось определить доступный домен. Используем vk.mail.ru по умолчанию.${plain}" >&3
    BEST_DOMAIN="vk.mail.ru"
fi

echo -e "${green}Выбран домен с наименьшим пингом: ${BEST_DOMAIN}${plain}" >&3

# === Аутентификация в x-ui API ===
COOKIE_JAR=$(mktemp)

# === Авторизация через cookie ===
LOGIN_RESPONSE=$(curl -s -c "$COOKIE_JAR" -X POST "http://127.0.0.1:${PORT}/${WEBPATH}/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\": \"${USERNAME}\", \"password\": \"${PASSWORD}\"}")

if ! echo "$LOGIN_RESPONSE" | grep -q '"success":true'; then
    echo -e "${red}Ошибка авторизации через cookie.${plain}" >&3
    echo "$LOGIN_RESPONSE" >&3
    exit 1
fi

# === Формирование JSON ===
SETTINGS_JSON=$(jq -nc --arg uuid "$UUID" --arg email "$EMAIL" '{
  clients: [
    {
      id: $uuid,
      flow: "xtls-rprx-vision",
      email: $email,
      enable: true
    }
  ],
  decryption: "none"
}')

STREAM_SETTINGS_JSON=$(jq -nc --arg pbk "$PUBLIC_KEY" --arg prk "$PRIVATE_KEY" --arg sid "$SHORT_ID" --arg dest "${BEST_DOMAIN}:443" --arg sni "$BEST_DOMAIN" '{
  network: "tcp",
  security: "reality",
  realitySettings: {
    show: false,
    dest: $dest,
    xver: 0,
    serverNames: [$sni],
    privateKey: $prk,
    settings: {publicKey: $pbk},
    shortIds: [$sid]
  }
}')

SNIFFING_JSON=$(jq -nc '{
  enabled: true,
  destOverride: ["http", "tls"]
}')

# === Отправка инбаунда через API с cookie ===
ADD_RESULT=$(curl -s -b "$COOKIE_JAR" -X POST "http://127.0.0.1:${PORT}/${WEBPATH}/panel/api/inbounds/add" \
  -H "Content-Type: application/json" \
  -d "$(jq -nc \
    --argjson settings "$SETTINGS_JSON" \
    --argjson stream "$STREAM_SETTINGS_JSON" \
    --argjson sniffing "$SNIFFING_JSON" \
    '{
      enable: true,
      remark: "reality443-auto",
      listen: "",
      port: 443,
      protocol: "vless",
      settings: ($settings | tostring),
      streamSettings: ($stream | tostring),
      sniffing: ($sniffing | tostring)
    }')"
)

# Проверка
if echo "$ADD_RESULT" | grep -q '"success":true'; then
    echo -e "${green}Инбаунд успешно добавлен через API.${plain}" >&3

    # Перезапуск x-ui
    systemctl restart x-ui >>"$LOG_FILE" 2>&1

    if [[ "$INSTALL_WARP" == true ]]; then
        echo -e "${yellow}Установка WARP...${plain}" >&3
        wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh -O /tmp/warp_menu.sh >/dev/null 2>&1
        if [[ $? -eq 0 ]]; then
            echo -e "${green}Скрипт WARP загружен, начинаем установку...${plain}" >&3
            echo -e "1\n" | bash /tmp/warp_menu.sh c >/dev/null 2>&1
            if [[ $? -eq 0 ]]; then
                echo -e "${green}WARP успешно установлен${plain}" >&3
                
                echo -e "${yellow}Настройка WARP в 3x-ui панели...${plain}" >&3
                
                XRAY_CONFIG='{
      "log": {
        "access": "none",
        "dnsLog": false,
        "error": "",
        "loglevel": "warning",
        "maskAddress": ""
      },
      "api": {
        "tag": "api",
        "services": [
          "HandlerService",
          "LoggerService",
          "StatsService"
        ]
      },
      "inbounds": [
        {
          "tag": "api",
          "listen": "127.0.0.1",
          "port": 62789,
          "protocol": "dokodemo-door",
          "settings": {
            "address": "127.0.0.1"
          }
        }
      ],
      "outbounds": [
        {
          "tag": "direct",
          "protocol": "freedom",
          "settings": {
            "domainStrategy": "AsIs",
            "redirect": "",
            "noises": []
          }
        },
        {
          "tag": "blocked",
          "protocol": "blackhole",
          "settings": {}
        },
        {
          "tag": "WARP",
          "protocol": "socks",
          "settings": {
            "servers": [
              {
                "address": "127.0.0.1",
                "port": 40000,
                "users": []
              }
            ]
          }
        }
      ],
      "policy": {
        "levels": {
          "0": {
            "statsUserDownlink": true,
            "statsUserUplink": true
          }
        },
        "system": {
          "statsInboundDownlink": true,
          "statsInboundUplink": true,
          "statsOutboundDownlink": false,
          "statsOutboundUplink": false
        }
      },
      "routing": {
        "domainStrategy": "AsIs",
        "rules": [
          {
            "type": "field",
            "inboundTag": [
              "api"
            ],
            "outboundTag": "api"
          },
          {
            "type": "field",
            "outboundTag": "blocked",
            "ip": [
              "geoip:private"
            ]
          },
          {
            "type": "field",
            "outboundTag": "blocked",
            "protocol": [
              "bittorrent"
            ]
          },
          {
            "type": "field",
            "inboundTag": [
              "inbound-443"
            ],
            "outboundTag": "WARP"
          }
        ]
      },
      "stats": {},
      "metrics": {
        "tag": "metrics_out",
        "listen": "127.0.0.1:11111"
      }
    }'
                
                XRAY_CONFIG_ENCODED=$(echo "$XRAY_CONFIG" | jq -sRr @uri)
                
                echo -e "${yellow}Отправка конфигурации Xray...${plain}" >&3
                UPDATE_RESPONSE=$(curl -s -b "$COOKIE_JAR" -X POST "http://127.0.0.1:${PORT}/${WEBPATH}/panel/xray/update" \
                  -H "Content-Type: application/x-www-form-urlencoded" \
                  --data-raw "xraySetting=${XRAY_CONFIG_ENCODED}")
                
                if echo "$UPDATE_RESPONSE" | grep -q '"success":true'; then
                    echo -e "${green}Конфигурация Xray успешно обновлена${plain}" >&3
                    
                    echo -e "${yellow}Перезапуск Xray...${plain}" >&3
                    RESTART_RESPONSE=$(curl -s -b "$COOKIE_JAR" -X POST "http://127.0.0.1:${PORT}/${WEBPATH}/server/restartXrayService")
                    
                    if echo "$RESTART_RESPONSE" | grep -q '"success":true'; then
                        echo -e "${green}Xray успешно перезапущен с настройками WARP${plain}" >&3
                        
                        echo -e "\n${green}VLESS Reality с поддержкой WARP успешно настроен!${plain}" >&3
                        echo -e "${yellow}Примечание: Весь трафик через Reality инбаунд теперь будет идти через WARP${plain}" >&3
                    else
                        echo -e "${red}Ошибка при перезапуске Xray:${plain}" >&3
                        echo "$RESTART_RESPONSE" >&3
                    fi
                else
                    echo -e "${red}Ошибка при обновлении конфигурации Xray:${plain}" >&3
                    echo "$UPDATE_RESPONSE" >&3
                fi
            else
                echo -e "${red}Ошибка при установке WARP${plain}" >&3
            fi
            rm -f /tmp/warp_menu.sh
        else
            echo -e "${red}Не удалось загрузить скрипт WARP${plain}" >&3
        fi
    fi
    
    rm -f "$COOKIE_JAR"

    SERVER_IP=$(curl -s --max-time 3 https://api.ipify.org || curl -s --max-time 3 https://4.ident.me)
    VLESS_LINK="vless://${UUID}@${SERVER_IP}:443?type=tcp&security=reality&encryption=none&flow=xtls-rprx-vision&sni=${BEST_DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&spx=%2F#${EMAIL}"

    echo -e ""
    echo -e "\n\033[0;32mVLESS Reality успешно создан!\033[0m" >&3
    echo -e "\033[1;36mВаш VPN ключ, его можно использовать сразу на нескольких устройствах:\033[0m" >&3
    echo -e ""
    echo -e "${VLESS_LINK}" >&3
    echo -e ""
    echo -e "QR код с Vless ключом, вы сможете отсканировать его с телефона в Happ"
    echo -e ""
    qrencode -t ANSIUTF8 "$VLESS_LINK"
    echo -e ""

    {
    echo "Ваш VPN ключ, его можно использовать сразу на нескольких устройствах:"
    echo ""
    echo "$VLESS_LINK"
    echo ""
    echo "QR код с Vless ключом, вы сможете отсканировать его с телефона в Happ"
    echo ""
    qrencode -t ANSIUTF8 "$VLESS_LINK"
    echo ""
    } >> /root/3x-ui.txt
else
    echo -e "${red}Ошибка при добавлении инбаунда через API:${plain}" >&3
    echo "$ADD_RESULT" >&3
fi

# === Общая финальная информация (всегда выводится) ===
SERVER_IP=${SERVER_IP:-$(curl -s --max-time 3 https://api.ipify.org || curl -s --max-time 3 https://4.ident.me)}

echo -e "\n\033[1;32mПанель управления 3X-UI доступна по следующим данным:\033[0m" >&3
echo -e "Адрес панели: \033[1;36mhttp://${SERVER_IP}:${PORT}/${WEBPATH}\033[0m" >&3
echo -e "Логин:        \033[1;33m${USERNAME}\033[0m" >&3
echo -e "Пароль:       \033[1;33m${PASSWORD}\033[0m" >&3

echo -e "\nВсе данные сохранены в файл: \033[1;36m/root/3x-ui.txt\033[0m" >&3
echo -e "Для повторного просмотра информации используйте команду:" >&3
echo -e "" >&3
echo -e "\033[0;36mcat /root/3x-ui.txt\033[0m" >&3
echo -e "" >&3

{
  echo "Панель управления 3X-UI доступна по следующим данным:"
  echo "Адрес панели - http://${SERVER_IP}:${PORT}/${WEBPATH}"
  echo "Логин:         ${USERNAME}"
  echo "Пароль:        ${PASSWORD}"
  echo ""
} >> /root/3x-ui.txt

fix_xray_permissions "$XRAY_USER"
