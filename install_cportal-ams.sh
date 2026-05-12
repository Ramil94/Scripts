#!/bin/bash
set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

INSTALL_DIR="/opt/cportal-ams"

echo -e "${BLUE}=================================================${NC}"
echo -e "${GREEN}   Универсальный менеджер Portal AMS (Prod)      ${NC}"
echo -e "${BLUE}=================================================${NC}"

echo -e "Выберите действие:"
echo -e "  ${GREEN}1) Установить / Обновить систему${NC}"
echo -e "  ${RED}2) Полностью УДАЛИТЬ систему (Деинсталляция)${NC}"
read -p "Ваш выбор (1 или 2): " MAIN_ACTION

# ==========================================
# БЛОК ДЕИНСТАЛЛЯЦИИ
# ==========================================
if [ "$MAIN_ACTION" == "2" ]; then
    echo -e "\n${RED}ВНИМАНИЕ! Вы собираетесь безвозвратно удалить:${NC}"
    echo "- Все Docker контейнеры AMS"
    echo "- Базу данных и всех пользователей"
    echo "- Всю историю и выданные ваучеры"
    echo "- Все файлы сертификатов и исходный код"
    read -p "Вы АБСОЛЮТНО уверены? Напишите 'YES' для подтверждения: " CONFIRM_DELETE
    
    if [ "$CONFIRM_DELETE" == "YES" ]; then
        echo -e "\n${YELLOW}Останавливаем и удаляем контейнеры...${NC}"
        if [ -d "$INSTALL_DIR" ]; then
            cd "$INSTALL_DIR"
            docker compose down -v || true
        fi
        echo -e "${YELLOW}Удаляем директорию проекта...${NC}"
        cd /
        sudo rm -rf "$INSTALL_DIR"
        echo -e "${GREEN}Система Portal AMS полностью удалена с сервера!${NC}"
        exit 0
    else
        echo -e "${BLUE}Удаление отменено.${NC}"
        exit 0
    fi
fi

# ==========================================
# БЛОК УСТАНОВКИ
# ==========================================
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
sudo rm -rf "$INSTALL_DIR"
git clone https://${GIT_TOKEN}@github.com/Ramil94/CPortal-AMS.git "$INSTALL_DIR"
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

RADIUS_SECRET=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16 ; echo '')

echo -e "\n${YELLOW}--- Режим Установки ---${NC}"
echo "1) Чистая (Боевая) установка (Суперадмин + Директор + Менеджер)"
echo "2) Тестовая установка (Админ + Директор + 5 тестовых менеджеров + Ваучеры)"
read -p "Выберите вариант (1 или 2): " DB_CHOICE

# Если ставим чистую базу, нам нужен пароль. Если тестовую - пароли стандартизированы.
if [ "$DB_CHOICE" == "1" ]; then
    echo -e "\n${GREEN}--- Доступ в панель управления ---${NC}"
    read -p "Придумайте пароль для суперадмина (логин: amsadmin): " ADMIN_UI_PASS
fi

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

sed -i "s/Pass208945Vb/${DB_PASS}/g" freeradius/mods-enabled/sql
sed -i "s/secret = YzPortalSecret2026!/secret = ${RADIUS_SECRET}/g" freeradius/clients.conf

# Готовим папку инициализации
rm -rf sql-init && mkdir -p sql-init
cp 01_schema.sql sql-init/
cp 02_default_settings.sql sql-init/

# === МАГИЯ ПОЛЬЗОВАТЕЛЕЙ (ДИНАМИЧЕСКАЯ ГЕНЕРАЦИЯ) ===
echo "CREATE EXTENSION IF NOT EXISTS pgcrypto;" > sql-init/02_core_users.sql

if [ "$DB_CHOICE" == "1" ]; then
cat <<EOF >> sql-init/02_core_users.sql
INSERT INTO users_admin (login, password_hash, role, full_name) VALUES
('amsadmin', crypt('${ADMIN_UI_PASS}', gen_salt('bf', 12)), 'sysadmin', 'Portal Admin'),
('amsmanager', crypt('amsmanager', gen_salt('bf', 12)), 'manager', 'Portal Manager'),
('amsdirektor', crypt('amsdirektor', gen_salt('bf', 12)), 'director', 'Portal Direktor')
ON CONFLICT (login) DO NOTHING;
EOF
else
cat <<EOF >> sql-init/02_core_users.sql
INSERT INTO users_admin (login, password_hash, role, full_name) VALUES
('admin', crypt('passwordAMS12', gen_salt('bf', 12)), 'sysadmin', 'Test Admin'),
('direktor', crypt('passwordAMS22', gen_salt('bf', 12)), 'director', 'Чары Гурбанов'),
('userm1', crypt('passwordAMS32', gen_salt('bf', 12)), 'manager', 'Анна Соколова'),
('userm2', crypt('passwordAMS32', gen_salt('bf', 12)), 'manager', 'Анастасия Волк'),
('userm3', crypt('passwordAMS32', gen_salt('bf', 12)), 'manager', 'Айгуль Аманова'),
('userm4', crypt('passwordAMS32', gen_salt('bf', 12)), 'manager', 'Дмитрий Иванов'),
('userm5', crypt('passwordAMS32', gen_salt('bf', 12)), 'manager', 'Мердан Сапаров')
ON CONFLICT (login) DO NOTHING;
EOF
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
# БЛОК SSL И ДОМЕНА
# ==========================================
echo -e "\n${YELLOW}=================================================${NC}"
read -p "Хотите сейчас привязать доменное имя и настроить чистый SSL? (y/n): " SETUP_SSL

# По умолчанию финальный URL будет по IP
FINAL_URL="https://${SERVER_IP}${ADMIN_PREFIX}"

if [[ "$SETUP_SSL" =~ ^[Yy]$ ]]; then
    read -p "Введите ваше доменное имя (например, portal.example.com): " DOMAIN_NAME
    sed -i "s/DOMAIN=.*/DOMAIN=${DOMAIN_NAME}/g" .env
    FINAL_URL="https://${DOMAIN_NAME}${ADMIN_PREFIX}"

    echo -e "\n${YELLOW}Выберите метод получения SSL сертификата:${NC}"
    echo "1) Let's Encrypt: HTTP-01 (белый IP, 80 порт открыт)"
    echo "2) Let's Encrypt: DNS API Hetzner (Hetzner Cloud Console / Новый API)"
    echo "3) Использовать свои файлы сертификата (.crt и .key)"
    read -p "Ваш выбор (1, 2 или 3): " SSL_METHOD

    if [ "$SSL_METHOD" == "3" ]; then
        echo -e "\n${YELLOW}Установка ваших файлов...${NC}"
        read -p "Путь к файлу .crt: " CRT_PATH
        read -p "Путь к файлу .key: " KEY_PATH
        if [ -f "$CRT_PATH" ] && [ -f "$KEY_PATH" ]; then
            cp "$CRT_PATH" ssl/server.crt
            cp "$KEY_PATH" ssl/server.key
            docker compose restart nginx
            echo -e "${GREEN}Ваши сертификаты успешно установлены!${NC}"
        else
            echo -e "${RED}Ошибка: Файлы сертификатов не найдены! Портал будет работать с самоподписанным сертификатом.${NC}"
        fi
    else
        if [ ! -d "$HOME/.acme.sh" ]; then
            echo -e "\n${BLUE}Устанавливаем acme.sh...${NC}"
            read -p "Введите Email для регистрации в Let's Encrypt: " ADMIN_EMAIL
            curl https://get.acme.sh | sh -s email=$ADMIN_EMAIL
        fi
        
        # Устанавливаем Let's Encrypt как сервер по умолчанию
        $HOME/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1
        ACME="$HOME/.acme.sh/acme.sh"
        
        CERT_SUCCESS=false

        if [ "$SSL_METHOD" == "1" ]; then
            echo -e "\n${BLUE}Выпускаем сертификат через HTTP-01...${NC}"
            docker compose stop nginx
            if $ACME --issue --standalone -d "$DOMAIN_NAME" --force; then
                CERT_SUCCESS=true
            else
                echo -e "${RED}Ошибка выпуска сертификата (HTTP-01). Проверьте, открыт ли 80 порт и привязан ли домен к IP.${NC}"
            fi
            docker compose start nginx

        elif [ "$SSL_METHOD" == "2" ]; then
            echo -e "\n${BLUE}Внимание: Используется новый Hetzner Cloud DNS API.${NC}"
            read -p "Введите Hetzner API Token (из Cloud Console): " HETZNER_API
            export HETZNER_TOKEN="$HETZNER_API"
            
            echo -e "${YELLOW}Выпускаем сертификат через DNS API (потребуется около 2 минут)...${NC}"
            if $ACME --issue --dns dns_hetznercloud -d "$DOMAIN_NAME" --force --dnssleep 120; then
                CERT_SUCCESS=true
            else
                echo -e "${RED}Ошибка выпуска сертификата (DNS Hetzner). Проверьте токен и наличие DNS зоны.${NC}"
            fi
        fi

        # Пытаемся установить сертификат только если он был успешно выпущен
        if [ "$CERT_SUCCESS" = true ]; then
            echo -e "\n${BLUE}Устанавливаем сертификат в Nginx...${NC}"
            if $ACME --install-cert -d "$DOMAIN_NAME" \
              --key-file "$INSTALL_DIR/ssl/server.key" \
              --fullchain-file "$INSTALL_DIR/ssl/server.crt" \
              --reloadcmd "cd $INSTALL_DIR && docker compose restart nginx"; then
                echo -e "${GREEN}Сертификат успешно установлен!${NC}"
            else
                echo -e "${RED}Ошибка установки сертификата в Nginx. Портал будет работать с самоподписанным.${NC}"
            fi
        else
            echo -e "${YELLOW}Пропускаем установку в Nginx из-за ошибки выпуска. Система продолжит работу с локальным сертификатом.${NC}"
        fi
    fi
fi

# ==========================================
# ФИНАЛЬНЫЙ ЭКРАН (ОТРАБАТЫВАЕТ ВСЕГДА)
# ==========================================
echo -e "\n${GREEN}=================================================${NC}"
echo -e "${GREEN} Установка ${APP_NAME} успешно завершена!        ${NC}"
echo -e "${GREEN}=================================================${NC}"
echo -e "Панель управления: ${BLUE}${FINAL_URL}${NC}"
echo -e "Директория:        ${BLUE}${INSTALL_DIR}${NC}"

if [ "$DB_CHOICE" == "2" ]; then
    echo -e "\n${YELLOW}--- ТЕСТОВЫЕ УЧЕТНЫЕ ЗАПИСИ ---${NC}"
    echo -e "Суперадмин:        ${BLUE}admin${NC} / passwordAMS12"
    echo -e "Директор:          ${BLUE}direktor${NC} / passwordAMS22"
    echo -e "Менеджеры:         ${BLUE}userm1 ... userm5${NC} / passwordAMS32"
else
    echo -e "\n${YELLOW}--- БОЕВЫЕ УЧЕТНЫЕ ЗАПИСИ ---${NC}"
    echo -e "Суперадмин:        ${BLUE}amsadmin${NC} / ${ADMIN_UI_PASS}"
    echo -e "Директор:          ${BLUE}amsdirektor${NC} / amsdirektor"
    echo -e "Менеджер:          ${BLUE}amsmanager${NC} / amsmanager"
fi

echo -e "\n${YELLOW}Доступы для оборудования (pfSense / MikroTik):${NC}"
echo -e "IP адрес RADIUS:   ${BLUE}${SERVER_IP}${NC}"
echo -e "Порты RADIUS:      ${BLUE}1812 (Auth), 1813 (Acct)${NC}"
echo -e "RADIUS Secret:     ${RED}${RADIUS_SECRET}${NC}  <-- ВПИШИТЕ ЭТО В PFSENSE!"
echo -e "${GREEN}=================================================${NC}"
