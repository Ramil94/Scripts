#!/bin/bash
set -e

# Цвета для оформления
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Новая системная директория
INSTALL_DIR="/opt/cportal-ams"

echo -e "${BLUE}=================================================${NC}"
echo -e "${GREEN}   Универсальный установщик Portal AMS (Prod)    ${NC}"
echo -e "${BLUE}=================================================${NC}"

# 1. Установка Docker (если нет)
if ! command -v docker &> /dev/null; then
    echo -e "${YELLOW}Устанавливаем Docker...${NC}"
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    rm get-docker.sh
fi

# 2. Клонирование проекта
echo -e "\n${YELLOW}Проект приватный. Потребуется GitHub Personal Access Token.${NC}"
read -s -p "Введите ваш GitHub Token: " GIT_TOKEN
echo ""

echo -e "\n${BLUE}Скачиваем проект с GitHub в ${INSTALL_DIR}...${NC}"
rm -rf "$INSTALL_DIR"
git clone https://${GIT_TOKEN}@github.com/Ramil94/portalyz.git "$INSTALL_DIR"
cd "$INSTALL_DIR"

# 3. Брендирование и настройки White-label
echo -e "\n${GREEN}--- Брендирование системы ---${NC}"
read -p "Введите название системы (нажмите Enter для PortalAMS): " APP_NAME
APP_NAME=${APP_NAME:-PortalAMS}

read -p "Введите URL для панели управления (нажмите Enter для /admin-portal): " ADMIN_PREFIX
ADMIN_PREFIX=${ADMIN_PREFIX:-/admin-portal}

# 4. Базовые сетевые настройки
echo -e "\n${GREEN}--- Базовые сетевые настройки ---${NC}"
read -p "Введите IP-адрес этого сервера (например, 10.89.0.4): " SERVER_IP

# Безопасный ввод пароля БД
while true; do
    read -p "Придумайте пароль для Базы Данных (ТОЛЬКО английские буквы и цифры): " DB_PASS
    if [[ "$DB_PASS" =~ ^[a-zA-Z0-9]+$ ]]; then
        break
    else
        echo -e "${RED}Ошибка: Пароль может содержать только латинские буквы и цифры. Спецсимволы запрещены!${NC}"
    fi
done

# Генерируем RADIUS Secret
RADIUS_SECRET=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16 ; echo '')

# 5. Генерация файла .env (Золотой стандарт)
echo -e "\n${BLUE}Создаем конфигурационный файл .env...${NC}"
cat <<EOF > .env
# Настройки приложения
APP_NAME=${APP_NAME}
ADMIN_PREFIX=${ADMIN_PREFIX}
DOMAIN=${SERVER_IP}
BIND_IP=0.0.0.0

# Параметры БД для Docker Postgres
POSTGRES_USER=portaladmin
POSTGRES_PASSWORD=${DB_PASS}
POSTGRES_DB=cportal_db

# Параметры БД для Python и Radius
DB_USER=portaladmin
DB_PASSWORD=${DB_PASS}
DB_NAME=cportal_db
DB_HOST=ams_db
EOF

# Исправляем пароли в конфигах Radius
sed -i "s/Pass208945Vb/${DB_PASS}/g" freeradius/mods-enabled/sql
sed -i "s/secret = YzPortalSecret2026!/secret = ${RADIUS_SECRET}/g" freeradius/clients.conf

# 6. Настройка Базы Данных
echo -e "\n${YELLOW}--- Настройка Базы Данных ---${NC}"
echo "1) Чистая установка (Только структура + Ваши пользователи из 02_default_settings.sql)"
echo "2) Тестовая установка (Структура + Настройки + 6000 ваучеров)"
read -p "Выберите вариант (1 или 2): " DB_CHOICE

mkdir -p sql-init
cp 01_schema.sql sql-init/
cp 02_default_settings.sql sql-init/
if [ "$DB_CHOICE" == "2" ]; then
    cp 03_dummy_data.sql sql-init/
fi

# 7. Инициализация SSL и прав доступа
echo -e "\n${YELLOW}--- Инициализация SSL и прав доступа ---${NC}"
mkdir -p ssl
# Генерируем локальный самоподписанный сертификат (имена теперь server.crt/key)
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

# 8. Сборка и запуск
echo -e "\n${BLUE}Запускаем сборку и старт контейнеров ams_...${NC}"
docker compose up -d --build

echo -e "\n${YELLOW}Ожидание инициализации базы данных (20 секунд)...${NC}"
sleep 20

if [ "$DB_CHOICE" == "2" ]; then
    echo -e "\n${BLUE}Генерируем статистику ваучеров за 2.5 года...${NC}"
    docker exec -it ams_backend python -m scripts.generate_history_v2 || true
fi

# 9. Блок настройки реального домена и SSL
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

# 10. Финальный отчет
echo -e "\n${GREEN}=================================================${NC}"
echo -e "${GREEN} Установка ${APP_NAME} успешно завершена!        ${NC}"
echo -e "${GREEN}=================================================${NC}"
echo -e "Панель управления: ${BLUE}${FINAL_URL}${NC}"
echo -e "Директория проекта: ${BLUE}${INSTALL_DIR}${NC}"
echo -e "\n${YELLOW}Доступы для оборудования (pfSense / MikroTik):${NC}"
echo -e "IP адрес RADIUS:        ${BLUE}${SERVER_IP}${NC}"
echo -e "Порты RADIUS:           ${BLUE}1812 (Auth), 1813 (Acct)${NC}"
echo -e "RADIUS Shared Secret:   ${RED}${RADIUS_SECRET}${NC}  <-- ВПИШИТЕ ЭТО В PFSENSE!"
echo -e "${GREEN}=================================================${NC}"
