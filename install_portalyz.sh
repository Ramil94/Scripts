#!/bin/bash
set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

INSTALL_DIR="/opt/cportal-ams"

echo -e "${BLUE}=================================================${NC}"
echo -e "${GREEN}   Универсальный установщик Portal AMS (Prod)    ${NC}"
echo -e "${BLUE}=================================================${NC}"

if ! command -v docker &> /dev/null; then
    echo -e "${YELLOW}Устанавливаем Docker...${NC}"
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    rm get-docker.sh
fi

echo -e "\n${YELLOW}Проект приватный. Потребуется GitHub Personal Access Token.${NC}"
read -s -p "Введите ваш GitHub Token: " GIT_TOKEN
echo ""

echo -e "\n${BLUE}Скачиваем проект с GitHub в ${INSTALL_DIR}...${NC}"
# Жестко удаляем старую папку, включая старую базу данных, для чистой установки
sudo rm -rf "$INSTALL_DIR"
git clone https://${GIT_TOKEN}@github.com/Ramil94/portalyz.git "$INSTALL_DIR"
cd "$INSTALL_DIR"

echo -e "\n${GREEN}--- Брендирование системы ---${NC}"
read -p "Введите название системы (нажмите Enter для PortalAMS): " APP_NAME
APP_NAME=${APP_NAME:-PortalAMS}

read -p "Введите URL для панели управления (нажмите Enter для /admin-portal): " ADMIN_PREFIX
ADMIN_PREFIX=${ADMIN_PREFIX:-/admin-portal}

echo -e "\n${GREEN}--- Базовые сетевые настройки ---${NC}"
read -p "Введите IP-адрес этого сервера (например, 10.89.0.4): " SERVER_IP

while true; do
    read -p "Придумайте пароль для Базы Данных Postgres (Только буквы и цифры): " DB_PASS
    if [[ "$DB_PASS" =~ ^[a-zA-Z0-9]+$ ]]; then
        break
    else
        echo -e "${RED}Ошибка: Спецсимволы запрещены!${NC}"
    fi
done

echo -e "\n${GREEN}--- Доступ в панель управления ---${NC}"
read -p "Придумайте пароль для суперадмина (логин: amsadmin): " ADMIN_UI_PASS

RADIUS_SECRET=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16 ; echo '')

echo -e "\n${BLUE}Настраиваем конфигурации...${NC}"
cat <<EOF > .env
APP_NAME=${APP_NAME}
ADMIN_PREFIX=${ADMIN_PREFIX}
DOMAIN=${SERVER_IP}
BIND_IP=0.0.0.0

POSTGRES_USER=portaladmin
POSTGRES_PASSWORD=${DB_PASS}
POSTGRES_DB=cportal_db

DB_USER=portaladmin
DB_PASSWORD=${DB_PASS}
DB_NAME=cportal_db
DB_HOST=ams_db

ADMIN_EMAIL=admin@your-domain.com
HETZNER_Token=your_hetzner_dns_token_here
EOF

# ВАЖНО: В твоем GitHub репозитории в файлах freeradius должны быть дефолтные значения: Pass208945Vb и YzPortalSecret2026!
sed -i "s/Pass208945Vb/${DB_PASS}/g" freeradius/mods-enabled/sql
sed -i "s/secret = YzPortalSecret2026!/secret = ${RADIUS_SECRET}/g" freeradius/clients.conf

echo -e "\n${YELLOW}--- Настройка Базы Данных ---${NC}"
echo "1) Чистая установка (Структура + 3 базовых пользователя)"
echo "2) Тестовая установка (Структура + Пользователи + Ваучеры)"
read -p "Выберите вариант (1 или 2): " DB_CHOICE

# Готовим папку инициализации
rm -rf sql-init && mkdir -p sql-init
cp 01_schema.sql sql-init/
cp 02_default_settings.sql sql-init/

# Магия пользователей: Postgres сам хэширует пароли при запуске
cat <<EOF > sql-init/02_core_users.sql
CREATE EXTENSION IF NOT EXISTS pgcrypto;

INSERT INTO users_admin (login, password_hash, role, full_name) VALUES
('amsadmin', crypt('${ADMIN_UI_PASS}', gen_salt('bf', 12)), 'sysadmin', 'Portal Admin'),
('amsmanager', crypt('amsmanager', gen_salt('bf', 12)), 'manager', 'Portal Manager'),
('amsdirektor', crypt('amsdirektor', gen_salt('bf', 12)), 'director', 'Portal Direktor')
ON CONFLICT (login) DO NOTHING;
EOF

if [ "$DB_CHOICE" == "2" ]; then
    cp 03_dummy_data.sql sql-init/
fi

echo -e "\n${YELLOW}--- Инициализация локального SSL ---${NC}"
mkdir -p ssl
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout ssl/server.key -out ssl/server.crt \
  -subj "/C=US/ST=State/L=City/O=${APP_NAME}/CN=${SERVER_IP}" 2>/dev/null

mkdir -p freeradius/certs
cd freeradius/certs
openssl req -new -x509 -nodes -out server.pem -keyout server.pem -days 3650 -subj "/C=US/O=Radius/CN=radius" 2>/dev/null
openssl req -new -x509 -nodes -out ca.pem -keyout ca.pem -days 3650 -subj "/C=US/O=Radius/CN=ca" 2>/dev/null
openssl dhparam -out dh 1024 2>/dev/null
cd ../..
chmod -R 755 freeradius

echo -e "\n${BLUE}Запускаем сборку и старт контейнеров ams_...${NC}"
docker compose up -d --build

echo -e "\n${YELLOW}Ожидание инициализации базы данных (20 секунд)...${NC}"
sleep 20

if [ "$DB_CHOICE" == "2" ]; then
    echo -e "\n${BLUE}Генерируем статистику ваучеров...${NC}"
    docker exec -it ams_backend python -m scripts.generate_history_v2 || true
fi

# ==========================================
# БЛОК SSL И ДОМЕНА (ВОЗВРАЩЕН НА МЕСТО)
# ==========================================
echo -e "\n${YELLOW}=================================================${NC}"
read -p "Хотите сейчас привязать доменное имя и настроить чистый SSL? (y/n): " SETUP_SSL

if [[ "$SETUP_SSL" =~ ^[Yy]$ ]]; then
    read -p "Введите ваше доменное имя (например, portal.example.com): " DOMAIN_NAME
    sed -i "s/DOMAIN=.*/DOMAIN=${DOMAIN_NAME}/g" .env

    echo -e "\n${YELLOW}Выберите метод получения SSL сертификата:${NC}"
    echo "1) Let's Encrypt: HTTP-01 (белый IP, 80 порт открыт)"
    echo "2) Let's Encrypt: DNS API Hetzner (Серый IP / Hetzner)"
    echo "3) Использовать свои файлы сертификата (.crt и .key)"
    read -p "Ваш выбор (1, 2 или 3): " SSL_METHOD

    if [ "$SSL_METHOD" == "3" ]; then
        echo -e "\n${YELLOW}Установка ваших файлов...${NC}"
        read -p "Путь к файлу .crt: " CRT_PATH
        read -p "Путь к файлу .key: " KEY_PATH
        cp "$CRT_PATH" ssl/server.crt
        cp "$KEY_PATH" ssl/server.key
        docker compose restart nginx
    else
        if [ ! -d "$HOME/.acme.sh" ]; then
            echo -e "\n${BLUE}Устанавливаем acme.sh...${NC}"
            read -p "Введите Email для регистрации: " ADMIN_EMAIL
            curl https://get.acme.sh | sh -s email=$ADMIN_EMAIL
        fi
        ACME="$HOME/.acme.sh/acme.sh"

        if [ "$SSL_METHOD" == "1" ]; then
            docker compose stop nginx
            $ACME --issue --standalone -d "$DOMAIN_NAME" || true
            docker compose start nginx
        elif [ "$SSL_METHOD" == "2" ]; then
            read -p "Введите Hetzner API Token: " HETZNER_API
            export HETZNER_Token="$HETZNER_API"
            $ACME --issue --dns dns_hetzner -d "$DOMAIN_NAME" --dnssleep 120 || true
        fi

        echo -e "\n${BLUE}Устанавливаем сертификат в Nginx...${NC}"
        $ACME --install-cert -d "$DOMAIN_NAME" \
          --key-file "$INSTALL_DIR/ssl/server.key" \
          --fullchain-file "$INSTALL_DIR/ssl/server.crt" \
          --reloadcmd "cd $INSTALL_DIR && docker compose restart nginx"
    fi
    FINAL_URL="https://${DOMAIN_NAME}${ADMIN_PREFIX}"
else
    FINAL_URL="https://${SERVER_IP}${ADMIN_PREFIX}"
fi

echo -e "\n${GREEN}=================================================${NC}"
echo -e "${GREEN} Установка ${APP_NAME} успешно завершена!        ${NC}"
echo -e "${GREEN}=================================================${NC}"
echo -e "Панель управления: ${BLUE}${FINAL_URL}${NC}"
echo -e "Директория:        ${BLUE}${INSTALL_DIR}${NC}"
echo -e "Суперадмин:        ${BLUE}amsadmin${NC} / (Ваш пароль)"
echo -e "Директор:          ${BLUE}amsdirektor${NC} / amsdirektor"
echo -e "Менеджер:          ${BLUE}amsmanager${NC} / amsmanager"
echo -e "\n${YELLOW}Доступы для оборудования (pfSense / MikroTik):${NC}"
echo -e "IP адрес RADIUS:   ${BLUE}${SERVER_IP}${NC}"
echo -e "Порты RADIUS:      ${BLUE}1812 (Auth), 1813 (Acct)${NC}"
echo -e "RADIUS Secret:     ${RED}${RADIUS_SECRET}${NC}  <-- ВПИШИТЕ ЭТО В PFSENSE!"
echo -e "${GREEN}=================================================${NC}"
