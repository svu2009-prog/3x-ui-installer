# 3X-UI Installer

Автоматическая установка и настройка панели [3X-UI](https://github.com/mhsanaei/3x-ui) на Ubuntu/Debian.

## Возможности

- **Идемпотентность** — повторный запуск не ломает систему
- **Подробный лог** — `/var/log/3x-ui-installer/install.log`
- **Обработка ошибок** — trap на ERR/EXIT/INT, восстановление из бекапов
- **Bash Strict Mode** — `set -Eeuo pipefail`
- **Цветной вывод** — информативные сообщения в консоль
- **Бекапы** — все изменяемые конфиги сохраняются с timestamp
- **Совместимость** — Ubuntu 20.04+, Debian 11+

## Состав установки

| Компонент | Описание |
|-----------|----------|
| 3X-UI Panel | Веб-интерфейс управления |
| VLESS TCP TLS (443) | С Nginx fallback на 8080 |
| Trojan gRPC Reality | С External Proxy |
| Trojan gRPC TLS | С сертификатом Let's Encrypt |
| Nginx + Certbot | SSL терминация, редирект 80→443 |
| UFW | Firewall с минимальными правилами |

## Использование

```bash
sudo bash install.sh
```

При первом запуске скрипт запросит:
1. Доменное имя
2. Email для Let's Encrypt
3. External Proxy Address

При повторном запуске скрипт:
- прочитает сохранённую конфигурацию (`/etc/3x-ui-installer/config.conf`)
- обновит только изменившиеся компоненты
- не создаст дубликаты inbound'ов
- не перевыпустит сертификат без необходимости

## Удаление

```bash
sudo bash uninstall.sh
```

## Структура проекта

```
3x-ui-installer/
├── install.sh              # Главный скрипт
├── uninstall.sh            # Удаление
├── lib/
│   ├── common.sh           # strict mode, цвета, логи, trap, backup
│   ├── checks.sh           # Проверки idempotency
│   ├── firewall.sh         # UFW
│   ├── nginx.sh            # Nginx + SSL
│   ├── panel.sh            # Установка панели
│   └── xray.sh             # Ключи + inbounds
├── AGENTS.md
└── README.md
```

## Где что сохраняется

| Файл | Назначение |
|------|------------|
| `/etc/3x-ui-installer/config.conf` | Конфигурация (авто) |
| `/var/log/3x-ui-installer/install.log` | Лог установки |
| `/root/x-ui-setup-credentials.txt` | Учётные данные |
| `/etc/letsencrypt/live/{domain}/` | SSL сертификаты |
