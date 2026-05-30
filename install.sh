#!/bin/bash
set -e

# Цвета для сообщений (не для dialog)
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# --- 1. Установка dialog, если отсутствует ---
if ! command -v dialog &> /dev/null; then
    echo -e "${YELLOW}Установка dialog для интерактивного меню...${NC}"
    sudo apt-get update && sudo apt-get install -y dialog
fi

# --- 2. Переменные и файлы состояния ---
STATE_DIR="$HOME/.server-setup-state"
STATE_FILE="$STATE_DIR/state.cfg"
SELECTED_FILE="$STATE_DIR/selected_services.cfg"
SETUP_DIR="$HOME/server-setup"
TEMP_FILE=$(mktemp)

# Функция для сохранения состояния установки
save_state() {
    mkdir -p "$STATE_DIR"
    echo "$1" > "$STATE_FILE"
}
# Функция для чтения состояния установки
get_state() {
    if [ -f "$STATE_FILE" ]; then
        cat "$STATE_FILE"
    else
        echo "start"
    fi
}
# Функция для сохранения выбранных сервисов
save_selected_services() {
    mkdir -p "$STATE_DIR"
    printf "%s\n" "${SELECTED_ARRAY[@]}" > "$SELECTED_FILE"
}
# Функция для загрузки выбранных сервисов
load_selected_services() {
    SELECTED_ARRAY=()
    if [ -f "$SELECTED_FILE" ]; then
        while IFS= read -r line; do
            SELECTED_ARRAY+=("$line")
        done < "$SELECTED_FILE"
    fi
}

# Обработчик выхода для очистки временных файлов
cleanup() {
    rm -f "$TEMP_FILE"
}
trap cleanup EXIT

# --- 3. Меню выбора сервисов (checklist) ---
show_service_menu() {
    local preselect=""
    if [ ${#SELECTED_ARRAY[@]} -gt 0 ]; then
        for service in "${SELECTED_ARRAY[@]}"; do
            case "$service" in
                postgres) preselect="$preselect postgres on" ;;
                qdrant) preselect="$preselect qdrant on" ;;
                ollama) preselect="$preselect ollama on" ;;
                apache) preselect="$preselect apache on" ;;
                nginx_proxy) preselect="$preselect nginx_proxy on" ;;
                portainer) preselect="$preselect portainer on" ;;
                supabase) preselect="$preselect supabase on" ;;
                n8n) preselect="$preselect n8n on" ;;
            esac
        done
        dialog --clear --title "Выбор сервисов для установки" \
            --checklist "Отметьте нужные компоненты (пробел — выбрать/снять):" 20 70 10 \
            postgres "PostgreSQL (база данных)" $([[ "$preselect" == *"postgres"* ]] && echo "on" || echo "off") \
            qdrant "Qdrant (векторная БД)" $([[ "$preselect" == *"qdrant"* ]] && echo "on" || echo "off") \
            ollama "Ollama (локальные LLM)" $([[ "$preselect" == *"ollama"* ]] && echo "on" || echo "off") \
            apache "Apache HTTP сервер" $([[ "$preselect" == *"apache"* ]] && echo "on" || echo "off") \
            nginx_proxy "Nginx Proxy Manager (прокси + SSL)" $([[ "$preselect" == *"nginx_proxy"* ]] && echo "on" || echo "off") \
            portainer "Portainer (веб-управление Docker)" $([[ "$preselect" == *"portainer"* ]] && echo "on" || echo "off") \
            supabase "Supabase (аналог Firebase, self-hosted)" $([[ "$preselect" == *"supabase"* ]] && echo "on" || echo "off") \
            n8n "n8n (автоматизация и workflow)" $([[ "$preselect" == *"n8n"* ]] && echo "on" || echo "off") \
            2> "$TEMP_FILE"
    else
        dialog --clear --title "Выбор сервисов для установки" \
            --checklist "Отметьте нужные компоненты (пробел — выбрать/снять):" 20 70 10 \
            postgres "PostgreSQL (база данных)" on \
            qdrant "Qdrant (векторная БД)" on \
            ollama "Ollama (локальные LLM)" on \
            apache "Apache HTTP сервер" on \
            nginx_proxy "Nginx Proxy Manager (прокси + SSL)" on \
            portainer "Portainer (веб-управление Docker)" on \
            supabase "Supabase (аналог Firebase, self-hosted)" on \
            n8n "n8n (автоматизация и workflow)" on \
            2> "$TEMP_FILE"
    fi

    if [ $? -ne 0 ]; then
        echo "Установка отменена пользователем."
        exit 1
    fi

    SELECTED=$(cat "$TEMP_FILE")
    SELECTED_ARRAY=()
    for item in $SELECTED; do
        item_clean=$(echo "$item" | tr -d '"')
        SELECTED_ARRAY+=("$item_clean")
    done
    save_selected_services
}

# --- 4. Ввод параметров (пароли, API и т.д.) ---
input_parameters() {
    # 4.1 PostgreSQL пароль
    PGPASSWORD=""
    while [ -z "$PGPASSWORD" ]; do
        PGPASSWORD=$(dialog --clear --title "PostgreSQL" \
            --passwordbox "Введите пароль для пользователя admin (оставьте пустым — сгенерирую случайный):" 10 50 \
            3>&1 1>&2 2>&3)
        if [ -z "$PGPASSWORD" ]; then
            PGPASSWORD=$(openssl rand -base64 24 | tr -d "=+/" | cut -c1-20)
            dialog --msgbox "Сгенерирован пароль PostgreSQL:\n$PGPASSWORD" 8 50
        fi
    done

    # 4.2 JWT Secret для Supabase
    JWT_SECRET=""
    while [ -z "$JWT_SECRET" ]; do
        JWT_SECRET=$(dialog --clear --title "JWT Secret для Supabase" \
            --passwordbox "Введите JWT Secret для Supabase (оставьте пустым — сгенерирую случайный):\n\nСлучайный ключ также можно сгенерировать командой:\nopenssl rand -base64 32 | tr -d '=+/' | cut -c1-40" \
            12 70 3>&1 1>&2 2>&3)
        if [ -z "$JWT_SECRET" ]; then
            JWT_SECRET=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-40)
            dialog --msgbox "Сгенерирован JWT Secret:\n$JWT_SECRET" 8 60
        fi
    done

    # 4.3 Выбор LLM провайдера
    LLM_TYPE=$(dialog --clear --title "LLM провайдер" \
        --radiolist "Выберите, какой LLM будет использоваться:" 15 60 4 \
        ollama "Ollama (локальный)" on \
        openai "OpenAI API" off \
        anthropic "Anthropic Claude API" off \
        3>&1 1>&2 2>&3)
    if [ $? -ne 0 ]; then exit 1; fi

    LLM_API_KEY=""
    LLM_API_URL=""

    case "$LLM_TYPE" in
        openai)
            LLM_API_KEY=$(dialog --clear --title "OpenAI API" \
                --passwordbox "Введите ваш API ключ OpenAI (sk-...):" 10 60 \
                3>&1 1>&2 2>&3)
            LLM_API_URL="https://api.openai.com/v1"
            ;;
        anthropic)
            LLM_API_KEY=$(dialog --clear --title "Anthropic API" \
                --passwordbox "Введите ваш API ключ Anthropic:" 10 60 \
                3>&1 1>&2 2>&3)
            LLM_API_URL="https://api.anthropic.com/v1"
            ;;
        ollama)
            LLM_API_URL=$(dialog --clear --title "Ollama URL" \
                --inputbox "URL для Ollama (оставьте по умолчанию для локального внутри Docker сети):" 10 60 \
                "http://ollama:11434" \
                3>&1 1>&2 2>&3)
            ;;
    esac

    # 4.4 Домен для Nginx Proxy Manager
    DOMAIN=$(dialog --clear --title "Домен (опционально)" \
        --inputbox "Введите ваш домен для публичного доступа (например, example.com):\nОставьте пустым, если используете IP-адрес.\n\nВАЖНО: DNS записи должны быть настроены на IP вашего сервера." \
        12 70 3>&1 1>&2 2>&3)

    # 4.5 Домен для Supabase
    SUPABASE_DOMAIN=$(dialog --clear --title "Домен для Supabase (опционально)" \
        --inputbox "Введите поддомен для Supabase (например, supabase.example.com):\nОставьте пустым, если не используете отдельный домен.\n\nSupabase Studio будет доступен по этому домену на порту 443." \
        12 70 3>&1 1>&2 2>&3)

    # 4.6 Параметры n8n
    if [[ " ${SELECTED_ARRAY[@]} " =~ "n8n" ]]; then
        N8N_PORT=$(dialog --clear --title "n8n порт" \
            --inputbox "Введите порт для веб-интерфейса n8n:" 10 50 "5678" \
            3>&1 1>&2 2>&3)
        if [ -z "$N8N_PORT" ]; then N8N_PORT="5678"; fi
        
        if [[ " ${SELECTED_ARRAY[@]} " =~ "postgres" ]]; then
            dialog --title "n8n и PostgreSQL" \
                --yesno "Обнаружен PostgreSQL. Использовать его для хранения данных n8n (рекомендуется)?\n\nЕсли выберите 'Нет', n8n будет использовать SQLite." 10 60
            if [ $? -eq 0 ]; then
                N8N_DB_POSTGRES=1
            else
                N8N_DB_POSTGRES=0
            fi
        else
            N8N_DB_POSTGRES=0
        fi
    fi

    # 4.7 Параметры Apache (если выбран)
    if [[ " ${SELECTED_ARRAY[@]} " =~ "apache" ]]; then
        APACHE_WWW_PATH=$(dialog --clear --title "Apache - папка для сайтов" \
            --inputbox "Укажите путь на сервере, где будут храниться ваши сайты (например, /var/www или ~/sites):\nОставьте пустым для использования ~/server-setup/www" \
            12 70 "" 3>&1 1>&2 2>&3)
        if [ -z "$APACHE_WWW_PATH" ]; then
            APACHE_WWW_PATH="$SETUP_DIR/www"
        fi
        mkdir -p "$APACHE_WWW_PATH"
        if [ ! -f "$APACHE_WWW_PATH/index.html" ]; then
            echo "<h1>It works! Apache + Docker</h1><p>Ваши сайты размещайте в папке: $APACHE_WWW_PATH</p>" > "$APACHE_WWW_PATH/index.html"
        fi
        # Также создаём папку для дополнительных конфигов (например, виртуальные хосты)
        mkdir -p "$APACHE_WWW_PATH/conf"
    fi

    # Ссылка на документацию Supabase
    dialog --title "Информация о ключах Supabase" \
        --msgbox "Официальная документация Supabase по API ключам:\nhttps://supabase.com/docs/guides/api/api-keys\n\nAnon Key и Service Role Key будут сгенерированы автоматически на основе JWT Secret.\nДля использования Supabase обязательно сохраните эти ключи после установки." \
        12 70
}

# --- 5. Основная установка Docker и Docker Compose ---
install_docker() {
    if ! command -v docker &> /dev/null; then
        dialog --infobox "Установка Docker (это может занять минуту)..." 5 50
        sleep 2
        curl -fsSL https://get.docker.com | sh
        sudo usermod -aG docker "$USER"
        save_state "docker_installed"
        dialog --msgbox "Docker установлен.\nПожалуйста, выйдите из системы и зайдите снова (или перезагрузите сервер), затем запустите скрипт повторно." 8 60
        exit 0
    fi

    if ! docker compose version &> /dev/null; then
        dialog --infobox "Установка Docker Compose (плагин)..." 5 50
        sudo apt-get install -y docker-compose-plugin
    fi
    save_state "docker_ready"
}

# --- 6. Функция для отображения прогресс-бара ---
show_progress() {
    local title="$1"
    local command="$2"
    (
        echo "0"
        echo "XXX"
        echo "Начинаем: $title..."
        echo "XXX"
        sleep 1
        
        eval "$command" > /dev/null 2>&1 &
        local pid=$!
        
        local progress=0
        while kill -0 $pid 2>/dev/null; do
            progress=$((progress + 5))
            if [ $progress -gt 100 ]; then
                progress=100
            fi
            echo "$progress"
            echo "XXX"
            echo "Выполняется: $title..."
            echo "XXX"
            sleep 1
        done
        wait $pid
        local exit_code=$?
        
        echo "100"
        echo "XXX"
        if [ $exit_code -eq 0 ]; then
            echo "Завершено: $title"
        else
            echo "Ошибка при выполнении: $title"
        fi
        echo "XXX"
    ) | dialog --gauge "$title" 10 70 0
    return $?
}

# --- 7. Создание структуры каталогов, .env и клонирование Supabase ---
setup_supabase() {
    mkdir -p "$SETUP_DIR"
    cd "$SETUP_DIR"

    # Сохраняем все переменные в .env
    cat > .env <<EOF
# Автоматически создано установщиком
POSTGRES_PASSWORD=${PGPASSWORD}
JWT_SECRET=${JWT_SECRET}

# LLM параметры
LLM_TYPE=${LLM_TYPE}
LLM_API_KEY=${LLM_API_KEY}
LLM_API_URL=${LLM_API_URL}
DOMAIN=${DOMAIN}
SUPABASE_DOMAIN=${SUPABASE_DOMAIN}

# n8n параметры
N8N_PORT=${N8N_PORT}
N8N_DB_POSTGRES=${N8N_DB_POSTGRES}

# Apache параметры
APACHE_WWW_PATH=${APACHE_WWW_PATH}
EOF

    if [[ " ${SELECTED_ARRAY[@]} " =~ "supabase" ]]; then
        if [ ! -d "supabase" ]; then
            git clone --depth 1 https://github.com/supabase/supabase
        fi
        
        mkdir -p supabase-project
        cp -rf supabase/docker/* supabase-project/
        cp supabase/docker/.env.example supabase-project/.env
        
        cd supabase-project
        chmod +x ./utils/generate-keys.sh
        ./utils/generate-keys.sh
        sed -i "s/POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=${PGPASSWORD}/" .env
        sed -i "s/JWT_SECRET=.*/JWT_SECRET=${JWT_SECRET}/" .env
        if [ -n "$SUPABASE_DOMAIN" ]; then
            sed -i "s|SUPABASE_PUBLIC_URL=.*|SUPABASE_PUBLIC_URL=https://${SUPABASE_DOMAIN}|" .env
            sed -i "s|API_EXTERNAL_URL=.*|API_EXTERNAL_URL=https://${SUPABASE_DOMAIN}|" .env
            sed -i "s|SITE_URL=.*|SITE_URL=https://${SUPABASE_DOMAIN}|" .env
        fi
        cd ..
    fi
}

# --- 8. Генерация docker-compose.yml ---
generate_compose_file() {
    cd "$SETUP_DIR"
    
    cat > docker-compose.yml <<EOF
# Автоматически сгенерированный Docker Compose
# Для перегенерации используйте install.sh

networks:
  internal_network:
    driver: bridge

volumes:
EOF

    [[ " ${SELECTED_ARRAY[@]} " =~ "postgres" ]] && echo "  postgres_data:" >> docker-compose.yml
    [[ " ${SELECTED_ARRAY[@]} " =~ "qdrant" ]] && echo "  qdrant_storage:" >> docker-compose.yml
    [[ " ${SELECTED_ARRAY[@]} " =~ "ollama" ]] && echo "  ollama_data:" >> docker-compose.yml
    [[ " ${SELECTED_ARRAY[@]} " =~ "nginx_proxy" ]] && { echo "  npm_data:" >> docker-compose.yml; echo "  npm_letsencrypt:" >> docker-compose.yml; }
    [[ " ${SELECTED_ARRAY[@]} " =~ "portainer" ]] && echo "  portainer_data:" >> docker-compose.yml
    [[ " ${SELECTED_ARRAY[@]} " =~ "supabase" ]] && { echo "  supabase_db_data:" >> docker-compose.yml; echo "  supabase_studio_data:" >> docker-compose.yml; }
    [[ " ${SELECTED_ARRAY[@]} " =~ "n8n" ]] && echo "  n8n_data:" >> docker-compose.yml

    echo "" >> docker-compose.yml
    echo "services:" >> docker-compose.yml

    # PostgreSQL
    if [[ " ${SELECTED_ARRAY[@]} " =~ "postgres" ]]; then
        cat >> docker-compose.yml <<EOF
  postgres:
    image: postgres:16-alpine
    container_name: postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: admin
      POSTGRES_PASSWORD: ${PGPASSWORD}
      POSTGRES_DB: appdb
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - internal_network
EOF
    fi

    # Qdrant
    if [[ " ${SELECTED_ARRAY[@]} " =~ "qdrant" ]]; then
        cat >> docker-compose.yml <<EOF
  qdrant:
    image: qdrant/qdrant:latest
    container_name: qdrant
    restart: unless-stopped
    volumes:
      - qdrant_storage:/qdrant/storage
    networks:
      - internal_network
EOF
    fi

    # Ollama
    if [[ " ${SELECTED_ARRAY[@]} " =~ "ollama" ]]; then
        cat >> docker-compose.yml <<EOF
  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    restart: unless-stopped
    environment:
      OLLAMA_HOST: 0.0.0.0
    volumes:
      - ollama_data:/root/.ollama
    networks:
      - internal_network
EOF
    fi

    # Apache с монтированием внешней папки
    if [[ " ${SELECTED_ARRAY[@]} " =~ "apache" ]]; then
        cat >> docker-compose.yml <<EOF
  apache:
    image: httpd:2.4-alpine
    container_name: apache
    restart: unless-stopped
    volumes:
      - ${APACHE_WWW_PATH}:/usr/local/apache2/htdocs/
      - ${APACHE_WWW_PATH}/conf:/usr/local/apache2/conf/extra/
    networks:
      - internal_network
EOF
    fi

    # Nginx Proxy Manager
    if [[ " ${SELECTED_ARRAY[@]} " =~ "nginx_proxy" ]]; then
        cat >> docker-compose.yml <<EOF
  nginx-proxy-manager:
    image: jc21/nginx-proxy-manager:latest
    container_name: nginx-proxy-manager
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "81:81"
    volumes:
      - npm_data:/data
      - npm_letsencrypt:/etc/letsencrypt
    networks:
      - internal_network
EOF
    fi

    # Portainer
    if [[ " ${SELECTED_ARRAY[@]} " =~ "portainer" ]]; then
        cat >> docker-compose.yml <<EOF
  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: unless-stopped
    command: -H unix:///var/run/docker.sock
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
    ports:
      - "9000:9000"
    networks:
      - internal_network
EOF
    fi

    # n8n
    if [[ " ${SELECTED_ARRAY[@]} " =~ "n8n" ]]; then
        N8N_ENV=""
        if [ "$N8N_DB_POSTGRES" -eq 1 ]; then
            N8N_ENV="
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_PORT: 5432
      DB_POSTGRESDB_USER: admin
      DB_POSTGRESDB_PASSWORD: ${PGPASSWORD}
      DB_POSTGRESDB_DATABASE: n8n"
        else
            N8N_ENV="
      DB_TYPE: sqlite
      DB_SQLITE_DATABASE: /home/node/.n8n/database.sqlite"
        fi
        cat >> docker-compose.yml <<EOF
  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: unless-stopped
    ports:
      - "${N8N_PORT}:5678"
    environment:${N8N_ENV}
      N8N_HOST: ${DOMAIN:-localhost}
      N8N_PORT: ${N8N_PORT}
      WEBHOOK_URL: http://${DOMAIN:-localhost}:${N8N_PORT}
    volumes:
      - n8n_data:/home/node/.n8n
    networks:
      - internal_network
EOF
    fi

    # Supabase: добавляем внешнюю сеть в его docker-compose (чтобы n8n и другие могли общаться)
    if [[ " ${SELECTED_ARRAY[@]} " =~ "supabase" ]] && [ -d "supabase-project" ]; then
        sed -i '/networks:/a\  internal_network:\n    external: true' supabase-project/docker-compose.yml
        # Добавляем каждому сервису supabase сеть internal_network (упрощённо: ищем service: и добавляем networks)
        awk '/^services:/{flag=1} flag && /^  [a-z]/ && !/networks:/{print; print "    networks:\n      - internal_network"; next} 1' supabase-project/docker-compose.yml > tmp && mv tmp supabase-project/docker-compose.yml
    fi
}

# --- 9. Настройка Nginx Proxy Manager для доменов ---
configure_npm_domain() {
    if [[ " ${SELECTED_ARRAY[@]} " =~ "nginx_proxy" ]] && [ -n "$DOMAIN" ]; then
        SERVER_IP=$(hostname -I | awk '{print $1}')
        sleep 10
        cat > "$SETUP_DIR/npm_domain_setup.txt" <<EOF
Для настройки домена $DOMAIN в Nginx Proxy Manager:

1. Откройте веб-интерфейс NPM: http://${SERVER_IP}:81
2. Войдите с логином admin@example.com и паролем changeme
3. Перейдите в раздел "Proxy Hosts" и нажмите "Add Proxy Host"
4. В поле "Domain Names" введите $DOMAIN
5. В разделе "Forward Hostname / IP" укажите: nginx-proxy-manager
6. В поле "Forward Port" укажите: 81
7. Перейдите на вкладку "SSL" и выберите "Request a new SSL Certificate"
8. Нажмите "Save"

Для n8n (если выбран):
1. Создайте ещё один Proxy Host
2. Domain Names: n8n.${DOMAIN}
3. Forward Hostname / IP: n8n
4. Forward Port: ${N8N_PORT}
5. Включите WebSockets
6. Настройте SSL

Для Apache (если выбран, и вы хотите выдать сайты через домен):
1. Создайте Proxy Host для нужного поддомена
2. Forward Hostname / IP: apache
3. Forward Port: 80
4. Настройте SSL

Для Supabase (если указан домен ${SUPABASE_DOMAIN}):
1. Создайте Proxy Host
2. Domain Names: ${SUPABASE_DOMAIN}
3. Forward Hostname / IP: supabase-kong
4. Forward Port: 8000
5. Включите WebSockets
6. Настройте SSL
EOF
        dialog --msgbox "Создан файл с инструкцией по настройке доменов:\n$SETUP_DIR/npm_domain_setup.txt\n\nПожалуйста, следуйте инструкциям после завершения установки." 12 70
    fi
}

# --- 10. Запуск контейнеров с прогресс-баром ---
start_containers() {
    cd "$SETUP_DIR"
    show_progress "Запуск PostgreSQL, Qdrant, Ollama, Apache" "docker compose up -d postgres qdrant ollama apache 2>/dev/null"
    if [[ " ${SELECTED_ARRAY[@]} " =~ "n8n" ]]; then
        show_progress "Запуск n8n" "docker compose up -d n8n 2>/dev/null"
    fi
    show_progress "Запуск Nginx Proxy Manager" "docker compose up -d nginx-proxy-manager 2>/dev/null"
    show_progress "Запуск Portainer" "docker compose up -d portainer 2>/dev/null"
    if [[ " ${SELECTED_ARRAY[@]} " =~ "supabase" ]]; then
        cd supabase-project
        show_progress "Запуск Supabase (все компоненты)" "docker compose up -d"
        cd ..
    fi
}

# --- 11. Финальное окно с результатами ---
show_summary() {
    SERVER_IP=$(hostname -I | awk '{print $1}')
    SUMMARY="✅ Установка завершена!\n\n"
    SUMMARY+="🌐 IP сервера: $SERVER_IP\n\n"
    
    if [[ " ${SELECTED_ARRAY[@]} " =~ "portainer" ]]; then
        SUMMARY+="🔹 Portainer: http://$SERVER_IP:9000\n"
    fi
    if [[ " ${SELECTED_ARRAY[@]} " =~ "nginx_proxy" ]]; then
        SUMMARY+="🔹 Nginx Proxy Manager: http://$SERVER_IP:81\n"
        SUMMARY+="   Логин: admin@example.com | Пароль: changeme\n\n"
    fi
    if [[ " ${SELECTED_ARRAY[@]} " =~ "apache" ]]; then
        SUMMARY+="🔹 Apache: http://$SERVER_IP\n"
        SUMMARY+="   Ваши сайты размещайте в папке: $APACHE_WWW_PATH\n"
    fi
    if [[ " ${SELECTED_ARRAY[@]} " =~ "supabase" ]]; then
        SUMMARY+="🔹 Supabase Studio: http://$SERVER_IP:3000\n"
        if [ -n "$SUPABASE_DOMAIN" ]; then
            SUMMARY+="   Через домен: https://${SUPABASE_DOMAIN}\n"
        fi
        SUMMARY+="   Anon Key и Service Role Key в файле:\n"
        SUMMARY+="   $SETUP_DIR/supabase-project/.env\n"
    fi
    if [[ " ${SELECTED_ARRAY[@]} " =~ "n8n" ]]; then
        SUMMARY+="🔹 n8n: http://$SERVER_IP:${N8N_PORT}\n"
        if [ -n "$DOMAIN" ]; then
            SUMMARY+="   Через домен: http://n8n.${DOMAIN}:${N8N_PORT}\n"
        fi
        SUMMARY+="   При первом входе создайте аккаунт.\n"
    fi
    
    SUMMARY+="\n📌 Пароль PostgreSQL: $PGPASSWORD\n"
    if [ "$LLM_TYPE" != "ollama" ] && [ -n "$LLM_API_KEY" ]; then
        SUMMARY+="📌 LLM API ключ: $LLM_API_KEY\n"
    fi
    
    if [ -n "$DOMAIN" ]; then
        SUMMARY+="\n🌐 Для настройки доменов (включая n8n, Apache и Supabase) следуйте инструкции:\n"
        SUMMARY+="   $SETUP_DIR/npm_domain_setup.txt\n"
    fi
    
    SUMMARY+="\nВсе данные сохранены в папке: $SETUP_DIR\n"
    SUMMARY+="Файлы состояния: $STATE_DIR"
    
    dialog --title "Готово!" --msgbox "$SUMMARY" 20 70
}

# --- 12. Главная функция ---
main() {
    local current_state=$(get_state)
    
    if [ -f "$SELECTED_FILE" ]; then
        load_selected_services
    fi
    
    case "$current_state" in
        "start")
            show_service_menu
            input_parameters
            install_docker
            setup_supabase
            generate_compose_file
            configure_npm_domain
            start_containers
            show_summary
            save_state "completed"
            ;;
        "docker_installed")
            dialog --msgbox "Docker был установлен. Пожалуйста, перезагрузите сервер и запустите скрипт снова." 8 60
            exit 0
            ;;
        "docker_ready")
            dialog --msgbox "Продолжаем установку с того места, где остановились..." 8 60
            setup_supabase
            generate_compose_file
            configure_npm_domain
            start_containers
            show_summary
            save_state "completed"
            ;;
        "completed")
            dialog --msgbox "Установка уже была завершена ранее. Для переустановки удалите папку $STATE_DIR" 8 60
            exit 0
            ;;
        *)
            dialog --msgbox "Неизвестное состояние. Начинаем установку с начала..." 8 60
            save_state "start"
            main
            ;;
    esac
}

main