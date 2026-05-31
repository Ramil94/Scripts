#!/bin/bash
set -e

echo "================================================="
echo "       Установка iWiSi Portal Mini               "
echo "================================================="

# 1. Проверка прав суперпользователя
if [ "$EUID" -ne 0 ]; then
  echo "Ошибка: Пожалуйста, запустите скрипт от имени root (sudo ./install.sh)"
  exit 1
fi

PROJECT_DIR="/opt/iwisi-portal-mini"
cd "$PROJECT_DIR"

echo "[+] Установка системных зависимостей (Docker, Dnsmasq, Netplan, uuid)..."
apt-get update
apt-get install -y docker.io docker-compose-plugin openssl netplan.io dnsmasq uuid-runtime curl

# Убедимся, что dnsmasq остановлен, так как им будет управлять наша админка
systemctl stop dnsmasq || true
systemctl disable dnsmasq || true

echo "[+] Освобождаем 53 порт (отключение systemd-resolved)..."
systemctl stop systemd-resolved || true
systemctl disable systemd-resolved || true
rm -f /etc/resolv.conf
echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" > /etc/resolv.conf

echo "[+] Подготовка системных файлов..."
# Защита от бага Docker: создаем файл заранее, чтобы Docker не примонтировал папку
if [ ! -f /etc/dnsmasq.conf ]; then
    touch /etc/dnsmasq.conf
fi

echo "[+] Настройка среды окружения (.env)..."
if [ ! -f .env ]; then
    echo "    Создаем файл .env с безопасными паролями..."
    DB_PASSWORD=$(uuidgen | sed 's/-//g' | head -c 16)
    JWT_SECRET=$(uuidgen | sed 's/-//g')
    AGENT_API_TOKEN=$(uuidgen | sed 's/-//g')
    
    cat <<EOF > .env
DB_PASSWORD=$DB_PASSWORD
JWT_SECRET=$JWT_SECRET
AGENT_API_TOKEN=$AGENT_API_TOKEN
EOF
else
    echo "    Файл .env уже существует. Пропускаем..."
fi

echo "[+] Генерация SSL-сертификата..."
chmod +x generate-ssl.sh
./generate-ssl.sh

echo "[+] Запуск и сборка контейнеров..."
docker compose up -d --build

echo "================================================="
echo " Установка успешно завершена!                    "
echo " Админка: https://admin.iwisi.ru                 "
echo " Корневой пользователь: iwisiadministrator       "
echo " Пароль по умолчанию: iWiSiAdminiStrator         "
echo "================================================="
