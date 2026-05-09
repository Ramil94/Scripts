#!/bin/bash
set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}=================================================${NC}"
echo -e "${GREEN}   Универсальный установщик PortalYZ (Prod)      ${NC}"
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

echo -e "\n${BLUE}Скачиваем проект с GitHub...${NC}"
rm -rf /opt/portalyz
git clone https://${GIT_TOKEN}@github.com/Ramil94/portalyz.git /opt/portalyz
cd /opt/portalyz

echo -e "\n${GREEN}--- Базовые сетевые настройки ---${NC}"
read -p "Введите IP-адрес этого сервера (например, 10.89.0.4): " SERVER_IP

# Безопасный ввод пароля (видимый, только буквы и цифры)
while true; do
    read -p "Придумайте пароль для Базы Данных (ТОЛЬКО английские буквы и цифры): " DB_PASS
    if [[ "$DB_PASS" =~ ^[a-zA-Z0-9]+$ ]]; then
        break
    else
        echo -e "${RED}Ошибка: Пароль может содержать только латинские буквы (A-Z, a-z) и цифры (0-9). Спецсимволы запрещены!${NC}"
    fi
done

# Генерируем мощный случайный пароль для pfSense (RADIUS Secret)
RADIUS_SECRET=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16 ; echo '')

echo -e "\n${BLUE}Настраиваем конфигурации...${NC}"
cp .env.example .env
sed -i "s/SuperSecretPassword123/${DB_PASS}/g" .env
sed -i "s/portalyz.your-domain.com/${SERVER_IP}/g" .env
sed -i "s/Pass208945Vb/${DB_PASS}/g" freeradius/mods-enabled/sql
sed -i "s/secret = YzPortalSecret2026!/secret = ${RADIUS_SECRET}/g" freeradius/clients.conf

echo -e "\n${YELLOW}--- Настройка Базы Данных ---${NC}"
echo "1) Чистая установка (Только структура + Базовые пользователи)"
echo "2) Тестовая установка (Структура + Пользователи + 6000 ваучеров)"
read -p "Выберите вариант (1 или 2): " DB_CHOICE

mkdir -p sql-init
cp 01_schema.sql sql-init/
cp 02_default_settings.sql sql-init/
if [ "$DB_CHOICE" == "2" ]; then
    cp 03_dummy_data.sql sql-init/
fi

echo -e "\n${YELLOW}--- Инициализация локального SSL и прав доступа ---${NC}"
mkdir -p ssl
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout ssl/portalyz.key -out ssl/portalyz.crt \
  -subj "/C=US/ST=State/L=City/O=PortalYZ/CN=${SERVER_IP}" 2>/dev/null

mkdir -p freeradius/certs
cd freeradius/certs
openssl req -new -x509 -nodes -out server.pem -keyout server.pem -days 3650 -subj "/C=US/O=Radius/CN=radius" 2>/dev/null
openssl req -new -x509 -nodes -out ca.pem -keyout ca.pem -days 3650 -subj "/C=US/O=Radius/CN=ca" 2>/dev/null
openssl dhparam -out dh 1024 2>/dev/null
cd ../..
chmod -R 755 freeradius

echo -e "\n${BLUE}Запускаем сборку и старт контейнеров...${NC}"
docker compose up -d --build

echo -e "\n${YELLOW}Ожидание инициализации базы данных (20 секунд)...${NC}"
sleep 20

if [ "$DB_CHOICE" == "2" ]; then
    echo -e "\n${BLUE}Генерируем статистику ваучеров за 2.5 года...${NC}"
    docker exec -it yz_backend python -m scripts.generate_history_v2 || true
fi

# ==========================================
# БЛОК SSL И ДОМЕНА
# ==========================================
echo -e "\n${YELLOW}=================================================${NC}"
read -p "Хотите сейчас привязать доменное имя и настроить чистый SSL? (y/n): " SETUP_SSL

if [[ "$SETUP_SSL" =~ ^[Yy]$ ]]; then
    read -p "Введите ваше доменное имя (например, portalyz.ascend-itc.de): " DOMAIN_NAME
    sed -i "s/DOMAIN=.*/DOMAIN=${DOMAIN_NAME}/g" /opt/portalyz/.env

    echo -e "\n${YELLOW}Выберите метод получения SSL сертификата:${NC}"
    echo "1) Let's Encrypt: HTTP-01 (Сервер имеет белый IP и порт 80 открыт миру)"
    echo "2) Let's Encrypt: DNS API Hetzner (Серый IP / NAT)"
    echo "3) Использовать свои готовые файлы сертификата (.crt и .key)"
    read -p "Ваш выбор (1, 2 или 3): " SSL_METHOD

    if [ "$SSL_METHOD" == "3" ]; then
        echo -e "\n${YELLOW}Установка пользовательского сертификата${NC}"
        read -p "Укажите полный путь к файлу сертификата (.crt): " CRT_PATH
        read -p "Укажите полный путь к файлу приватного ключа (.key): " KEY_PATH
        cp "$CRT_PATH" /opt/portalyz/ssl/portalyz.crt
        cp "$KEY_PATH" /opt/portalyz/ssl/portalyz.key
        docker compose restart nginx
        echo -e "${GREEN}Сертификаты скопированы. Nginx перезапущен.${NC}"
    else
        if [ ! -d "$HOME/.acme.sh" ]; then
            echo -e "\n${BLUE}Устанавливаем acme.sh...${NC}"
            read -p "Введите Email для регистрации в Let's Encrypt: " ADMIN_EMAIL
            curl https://get.acme.sh | sh -s email=$ADMIN_EMAIL
        fi
        ACME="$HOME/.acme.sh/acme.sh"

        if [ "$SSL_METHOD" == "1" ]; then
            docker compose stop nginx
            $ACME --issue --standalone -d "$DOMAIN_NAME" || true
            docker compose start nginx
        elif [ "$SSL_METHOD" == "2" ]; then
            read -p "Введите Hetzner API Token: " HETZNER_TOKEN
            export HETZNER_Token="$HETZNER_TOKEN"
            $ACME --issue --dns dns_hetzner -d "$DOMAIN_NAME" --dnssleep 120 || true
        fi

        echo -e "\n${BLUE}Устанавливаем сертификат в Nginx...${NC}"
        $ACME --install-cert -d "$DOMAIN_NAME" \
          --key-file /opt/portalyz/ssl/portalyz.key \
          --fullchain-file /opt/portalyz/ssl/portalyz.crt \
          --reloadcmd "cd /opt/portalyz && docker compose restart nginx"
    fi
    FINAL_URL="https://${DOMAIN_NAME}/portalyzadmin"
else
    FINAL_URL="https://${SERVER_IP}/portalyzadmin (Самоподписанный SSL)"
fi

echo -e "\n${GREEN}=================================================${NC}"
echo -e "${GREEN} Установка PortalYZ успешно завершена!           ${NC}"
echo -e "${GREEN}=================================================${NC}"
echo -e "Панель управления: ${BLUE}${FINAL_URL}${NC}"
echo -e "Логин - portalyzadmin     Пароль - portalyzadmin1"
echo -e "\n${YELLOW}Доступы для оборудования (pfSense / MikroTik):${NC}"
echo -e "IP адрес RADIUS:        ${BLUE}${SERVER_IP}${NC}"
echo -e "Порты RADIUS:           ${BLUE}1812 (Auth), 1813 (Acct)${NC}"
echo -e "RADIUS Shared Secret:   ${RED}${RADIUS_SECRET}${NC}  <-- ВПИШИТЕ ЭТО В PFSENSE!"
echo -e "${GREEN}=================================================${NC}"
