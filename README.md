# Server Auto Setup

Одна команда для полной установки Docker, PostgreSQL, Qdrant, Ollama, Apache, Nginx Proxy Manager, Portainer, Supabase и n8n на сервере с Ubuntu.

## Быстрый запуск

Скопируйте и выполните в терминале вашего сервера (Ubuntu) одну строку:

```bash
curl -fsSL https://raw.githubusercontent.com/Pavel-work/server-auto-setup/main/install.sh | sed 's/set -euo pipefail/# set -euo pipefail/' | sudo bash
```
```bash
curl -fsSL "https://raw.githubusercontent.com/Pavel-work/server-auto-setup/main/install.sh" | sudo bash -s
```


Что будет установлено
Docker и Docker Compose (если ещё нет)

PostgreSQL

Qdrant

Ollama

Apache (с монтированием папки для сайтов)

Nginx Proxy Manager

Portainer

Supabase (полноценная версия)

n8n

Интерактивный режим
При запуске скрипт спросит:

Какие сервисы установить (можно выбрать)

Пароль для PostgreSQL

JWT Secret для Supabase

Выбор LLM провайдера (Ollama, OpenAI, Anthropic)

Домен (опционально) для Nginx Proxy Manager и Supabase

Порт для n8n

Путь для сайтов Apache

Всё остальное (ключи, пароли) генерируется автоматически.

После установки
Portainer: http://IP_сервера:9000

Nginx Proxy Manager: http://IP_сервера:81 (логин admin@example.com, пароль changeme)

n8n: http://IP_сервера:5678

Supabase Studio: http://IP_сервера:3000

Apache: http://IP_сервера (ваши сайты в указанной папке)

Примечания
Если Docker не установлен, скрипт попросит перезагрузить сервер. После перезагрузки запустите ту же команду повторно — установка продолжится.

Все пароли и ключи выводятся в конце и сохраняются в папке ~/server-setup/.env.

Для настройки доменов и SSL создаётся файл ~/server-setup/npm_domain_setup.txt.
