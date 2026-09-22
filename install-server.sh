#!/usr/bin/env bash
# Установка сторожа торгов на Linux-сервер (Debian/Ubuntu).
# Запускать на СЕРВЕРЕ под root:   sudo bash install-server.sh
set -euo pipefail

APP=/opt/torgi-bot
DATA=/var/lib/torgi
SRC="$(cd "$(dirname "$0")" && pwd)"

echo "==> зависимости"
if command -v apt-get >/dev/null; then
  apt-get update -qq
  apt-get install -y -qq ruby curl ca-certificates tzdata
else
  echo "не Debian/Ubuntu — установите ruby и curl сами, затем запустите снова"
  command -v ruby >/dev/null || exit 1
fi

echo "==> пользователь torgi"
id -u torgi >/dev/null 2>&1 || useradd --system --home-dir "$DATA" --create-home --shell /usr/sbin/nologin torgi

echo "==> файлы"
install -d -m 755 "$APP"
install -m 755 "$SRC/tgbot.rb" "$APP/tgbot.rb"
install -d -m 700 -o torgi -g torgi "$DATA"

echo "==> systemd"
install -m 644 "$SRC/torgi-watcher.service" /etc/systemd/system/torgi-watcher.service
install -m 644 "$SRC/torgi-watcher.timer"   /etc/systemd/system/torgi-watcher.timer
systemctl daemon-reload

cat <<'TXT'

==> Готово. Осталось три шага, которые может сделать только владелец бота:

 1. Создайте бота у @BotFather (/newbot) и положите токен:

      sudo -u torgi tee /var/lib/torgi/token >/dev/null   <-- вставьте токен, затем Ctrl-D
      sudo chmod 600 /var/lib/torgi/token

 2. Напишите своему боту в Telegram любое сообщение (/start), затем проверьте связь:

      sudo -u torgi TORGI_HOME=/var/lib/torgi ruby /opt/torgi-bot/tgbot.rb --test

 3. Запомните текущие лоты, чтобы не получить лавину, и включите таймер:

      sudo -u torgi TORGI_HOME=/var/lib/torgi ruby /opt/torgi-bot/tgbot.rb --init
      sudo systemctl enable --now torgi-watcher.timer

 Проверка работы:
      systemctl list-timers torgi-watcher.timer
      journalctl -u torgi-watcher.service -n 50 --no-pager
      sudo tail -n 30 /var/lib/torgi/bot.log

TXT
