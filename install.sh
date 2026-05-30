#!/bin/bash
# Универсальный установщик сервисов v1.0 (исправленный окончательно)
set -euo pipefail

# Цвета
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# === Глобальные ===
STATE_DIR="/root/.server-setup-state"
STATE_FILE="$STATE_DIR/state.cfg"
SELECTED_FILE="$STATE_DIR/selected_services.cfg"
PARAMS_FILE="$STATE_DIR/params.env"
SETUP_DIR="/root/server-setup"
TEMP_FILE=$(mktemp)
REAL_USER="${SUDO_USER:-$USER}"

cleanup() { rm -f "$TEMP_FILE"; }
trap cleanup EXIT INT TERM

save_state() { mkdir -p "$STATE_DIR"; echo "$1" > "$STATE_FILE"; }
get_state() { if [[ -f "$STATE_FILE" ]]; then cat "$STATE_FILE"; else echo "start"; fi; }

save_selected_services() { mkdir -p "$STATE_DIR"; printf "%s\n" "${SELECTED_ARRAY[@]}" > "$SELECTED_FILE"; }
load_selected_services() { SELECTED_ARRAY=(); [[ -f "$SELECTED_FILE" ]] && mapfile -t SELECTED_ARRAY < "$SELECTED_FILE"; }

save_params() {
    mkdir -p "$STATE_DIR"
    cat > "$PARAMS_FILE" <<EOF
PGPASSWORD="$PGPASSWORD"
JWT_SECRET="$JWT_SECRET"
LLM_TYPE="$LLM_TYPE"
LLM_API_KEY="$LLM_API_KEY"
LLM_API_URL="$LLM_API_URL"
DOMAIN="$DOMAIN"
SUPABASE_DOMAIN="$SUPABASE_DOMAIN"
N8N_PORT="$N8N_PORT"
N8N_DB_POSTGRES="$N8N_DB_POSTGRES"
APACHE_WWW_PATH="$APACHE_WWW_PATH"
APACHE_HTTP_PORT="$APACHE_HTTP_PORT"
QDRANT_PORT="$QDRANT_PORT"
OLLAMA_PORT="$OLLAMA_PORT"
EOF
    chmod 600 "$PARAMS_FILE"
}

load_params() {
    if [[ -f "$PARAMS_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$PARAMS_FILE"
    fi
    PGPASSWORD="${PGPASSWORD:-}"
    JWT_SECRET="${JWT_SECRET:-}"
    LLM_TYPE="${LLM_TYPE:-}"
    LLM_API_KEY="${LLM_API_KEY:-}"
    LLM_API_URL="${LLM_API_URL:-}"
    DOMAIN="${DOMAIN:-}"
    SUPABASE_DOMAIN="${SUPABASE_DOMAIN:-}"
    N8N_PORT="${N8N_PORT:-5678}"
    N8N_DB_POSTGRES="${N8N_DB_POSTGRES:-0}"
    APACHE_WWW_PATH="${APACHE_WWW_PATH:-$SETUP_DIR/www}"
    APACHE_HTTP_PORT="${APACHE_HTTP_PORT:-8080}"
    QDRANT_PORT="${QDRANT_PORT:-6333}"
    OLLAMA_PORT="${OLLAMA_PORT:-11434}"
}

check_port() {
    local port=$1
    if ss -tuln | grep -q ":$port "; then
        dialog --title "Ошибка" --msgbox "Порт $port уже занят. Выберите другой." 6 50
        return 1
    fi
    return 0
}

install_docker() {
    if ! command -v docker &> /dev/null; then
        dialog --infobox "Установка Docker..." 5 50
        curl -fsSL https://get.docker.com | sh
        usermod -aG docker "$REAL_USER" || true
        systemctl enable docker --now
        dialog --msgbox "Docker установлен.\nПерезагрузка не требуется." 8 50
    fi
    if ! docker compose version &> /dev/null; then
        apt-get install -y docker-compose-plugin
    fi
}

# === 1. Меню выбора сервисов ===
show_service_menu() {
    local args=(
        "postgres" "PostgreSQL" "off"
        "qdrant" "Qdrant" "off"
        "ollama" "Ollama" "off"
        "apache" "Apache" "off"
        "nginx_proxy" "Nginx Proxy Manager" "off"
        "portainer" "Portainer" "off"
        "supabase" "Supabase" "off"
        "n8n" "n8n" "off"
    )
    if [ ${#SELECTED_ARRAY[@]} -gt 0 ]; then
        for ((i=0; i<${#args[@]}; i+=3)); do
            for sel in "${SELECTED_ARRAY[@]}"; do
                [[ "${args[$i]}" == "$sel" ]] && args[$((i+2))]="on"
            done
        done
    fi

    dialog --clear --title "Выбор сервисов" \
        --checklist "Выберите нужное (пробел)." 22 70 10 \
        "${args[@]}" 2> "$TEMP_FILE" || { echo "Отмена."; exit 1; }

    SELECTED=$(cat "$TEMP_FILE")
    SELECTED_ARRAY=()
    for item in $SELECTED; do
        SELECTED_ARRAY+=("$(echo "$item" | tr -d '"')")
    done
    save_selected_services
}

# === 2. Ввод параметров ===
input_parameters() {
    # PostgreSQL
    while true; do
        dialog --clear --title "PostgreSQL" \
            --inputbox "Введите пароль admin (пусто = сгенерировать)\n(Shift+Insert для вставки)" 10 60 \
            "$PGPASSWORD" 2> "$TEMP_FILE" || { save_state "start"; return 1; }
        PGPASSWORD=$(cat "$TEMP_FILE")
        if [ -z "$PGPASSWORD" ]; then
            PGPASSWORD=$(openssl rand -base64 24 | tr -d "=+/" | cut -c1-20)
            dialog --msgbox "Сгенерирован пароль:\n$PGPASSWORD" 8 60
        fi
        break
    done

    # JWT
    while true; do
        dialog --inputbox "JWT Secret (пусто = сгенерировать)\nShift+Insert" 10 60 \
            "$JWT_SECRET" 2> "$TEMP_FILE" || { save_state "start"; return 1; }
        JWT_SECRET=$(cat "$TEMP_FILE")
        [ -z "$JWT_SECRET" ] && JWT_SECRET=$(openssl rand -hex 32)
        break
    done

    # LLM
    LLM_TYPE=$(dialog --clear --title "LLM" \
        --radiolist "Выберите:" 15 60 4 \
        "ollama" "Ollama" on \
        "openai" "OpenAI" off \
        "anthropic" "Anthropic" off \
        3>&1 1>&2 2>&3) || { save_state "start"; return 1; }

    case "$LLM_TYPE" in
        openai)
            dialog --passwordbox "OpenAI API key (sk-...)" 10 60 2> "$TEMP_FILE" || return 1
            LLM_API_KEY=$(cat "$TEMP_FILE")
            LLM_API_URL="https://api.openai.com/v1"
            ;;
        anthropic)
            dialog --passwordbox "Anthropic API key" 10 60 2> "$TEMP_FILE" || return 1
            LLM_API_KEY=$(cat "$TEMP_FILE")
            LLM_API_URL="https://api.anthropic.com/v1"
            ;;
        ollama)
            LLM_API_URL="http://ollama:11434"
            ;;
    esac

    # Домен
    dialog --inputbox "Ваш домен (оставьте пустым если нет)" 10 60 "$DOMAIN" 2> "$TEMP_FILE" || return 1
    DOMAIN=$(cat "$TEMP_FILE")
    dialog --inputbox "Поддомен Supabase (supabase.example.com)" 10 60 "$SUPABASE_DOMAIN" 2> "$TEMP_FILE" || return 1
    SUPABASE_DOMAIN=$(cat "$TEMP_FILE")

    # n8n порт
    if [[ " ${SELECTED_ARRAY[@]} " =~ "n8n" ]]; then
        while true; do
            dialog --inputbox "Порт n8n:" 10 50 "$N8N_PORT" 2> "$TEMP_FILE" || return 1
            N8N_PORT=$(cat "$TEMP_FILE")
            check_port "$N8N_PORT" && break
        done
        if [[ " ${SELECTED_ARRAY[@]} " =~ "postgres" ]]; then
            dialog --yesno "Использовать PostgreSQL для n8n?" 8 50 && N8N_DB_POSTGRES=1 || N8N_DB_POSTGRES=0
        fi
    fi

    # Apache
    if [[ " ${SELECTED_ARRAY[@]} " =~ "apache" ]]; then
        dialog --inputbox "Путь для сайтов Apache:" 10 60 "$APACHE_WWW_PATH" 2> "$TEMP_FILE" || return 1
        APACHE_WWW_PATH=$(cat "$TEMP_FILE")
        [ -z "$APACHE_WWW_PATH" ] && APACHE_WWW_PATH="$SETUP_DIR/www"
        APACHE_WWW_PATH=$(realpath -m "$APACHE_WWW_PATH")
        mkdir -p "$APACHE_WWW_PATH" "$APACHE_WWW_PATH/conf"
        while true; do
            dialog --inputbox "Порт Apache:" 10 50 "$APACHE_HTTP_PORT" 2> "$TEMP_FILE" || return 1
            APACHE_HTTP_PORT=$(cat "$TEMP_FILE")
            check_port "$APACHE_HTTP_PORT" && break
        done
        [ ! -f "$APACHE_WWW_PATH/index.html" ] && echo "<h1>It works!</h1>" > "$APACHE_WWW_PATH/index.html"
    fi

    # Qdrant порт
    if [[ " ${SELECTED_ARRAY[@]} " =~ "qdrant" ]]; then
        while true; do
            dialog --inputbox "Порт Qdrant:" 10 50 "$QDRANT_PORT" 2> "$TEMP_FILE" || return 1
            QDRANT_PORT=$(cat "$TEMP_FILE")
            check_port "$QDRANT_PORT" && break
        done
    fi

    # Ollama порт
    if [[ " ${SELECTED_ARRAY[@]} " =~ "ollama" ]]; then
        while true; do
            dialog --inputbox "Порт Ollama:" 10 50 "$OLLAMA_PORT" 2> "$TEMP_FILE" || return 1
            OLLAMA_PORT=$(cat "$TEMP_FILE")
            check_port "$OLLAMA_PORT" && break
        done
    fi

    save_params
    return 0
}

# === 3. Сеть ===
setup_network() {
    docker network inspect internal_network &>/dev/null || docker network create internal_network
    mkdir -p "$SETUP_DIR"
    cd "$SETUP_DIR"
    cat > .env <<EOF
POSTGRES_PASSWORD=${PGPASSWORD}
JWT_SECRET=${JWT_SECRET}
LLM_TYPE=${LLM_TYPE}
LLM_API_KEY=${LLM_API_KEY}
LLM_API_URL=${LLM_API_URL}
DOMAIN=${DOMAIN}
SUPABASE_DOMAIN=${SUPABASE_DOMAIN}
N8N_PORT=${N8N_PORT}
N8N_DB_POSTGRES=${N8N_DB_POSTGRES}
APACHE_WWW_PATH=${APACHE_WWW_PATH}
APACHE_HTTP_PORT=${APACHE_HTTP_PORT}
QDRANT_PORT=${QDRANT_PORT}
OLLAMA_PORT=${OLLAMA_PORT}
EOF
    chmod 600 .env
}

# === 4. Supabase (исправлено: PGPASSWORD_ESC генерируется на месте) ===
setup_supabase() {
    [[ ! " ${SELECTED_ARRAY[@]} " =~ "supabase" ]] && return 0
    cd "$SETUP_DIR"
    if [ ! -d "supabase-docker" ]; then
        dialog --infobox "Скачивание Supabase..." 5 60
        git clone --depth 1 --filter=blob:none --sparse https://github.com/supabase/supabase
        cd supabase
        git sparse-checkout set docker
        cd ..
        mv supabase/docker supabase-docker
        rm -rf supabase
    fi
    cd supabase-docker
    cp .env.example .env

    # Генерируем все ключи вручную (без вызова generate-keys.sh)
    ANON_KEY=$(openssl rand -hex 32)
    SERVICE_ROLE_KEY=$(openssl rand -hex 32)
    SECRET_KEY_BASE=$(openssl rand -hex 32)
    VAULT_ENC_KEY=$(openssl rand -hex 32)
    PG_META_CRYPTO_KEY=$(openssl rand -hex 32)
    LOGFILE_PUBLIC_ACCESS_TOKEN=$(openssl rand -hex 32)
    LOGFILE_PRIVATE_ACCESS_TOKEN=$(openssl rand -hex 32)
    S3_PROTOCOL_ACCESS_KEY_ID=$(openssl rand -hex 16)
    S3_PROTOCOL_ACCESS_KEY_SECRET=$(openssl rand -hex 32)
    MINIO_ROOT_PASSWORD=$(openssl rand -hex 16)
    DASHBOARD_PASSWORD=$(openssl rand -hex 12)

    sed -i "s/^ANON_KEY=.*/ANON_KEY=$ANON_KEY/" .env
    sed -i "s/^SERVICE_ROLE_KEY=.*/SERVICE_ROLE_KEY=$SERVICE_ROLE_KEY/" .env
    sed -i "s/^SECRET_KEY_BASE=.*/SECRET_KEY_BASE=$SECRET_KEY_BASE/" .env
    sed -i "s/^VAULT_ENC_KEY=.*/VAULT_ENC_KEY=$VAULT_ENC_KEY/" .env
    sed -i "s/^PG_META_CRYPTO_KEY=.*/PG_META_CRYPTO_KEY=$PG_META_CRYPTO_KEY/" .env
    sed -i "s/^LOGFILE_PUBLIC_ACCESS_TOKEN=.*/LOGFILE_PUBLIC_ACCESS_TOKEN=$LOGFILE_PUBLIC_ACCESS_TOKEN/" .env
    sed -i "s/^LOGFILE_PRIVATE_ACCESS_TOKEN=.*/LOGFILE_PRIVATE_ACCESS_TOKEN=$LOGFILE_PRIVATE_ACCESS_TOKEN/" .env
    sed -i "s/^S3_PROTOCOL_ACCESS_KEY_ID=.*/S3_PROTOCOL_ACCESS_KEY_ID=$S3_PROTOCOL_ACCESS_KEY_ID/" .env
    sed -i "s/^S3_PROTOCOL_ACCESS_KEY_SECRET=.*/S3_PROTOCOL_ACCESS_KEY_SECRET=$S3_PROTOCOL_ACCESS_KEY_SECRET/" .env
    sed -i "s/^MINIO_ROOT_PASSWORD=.*/MINIO_ROOT_PASSWORD=$MINIO_ROOT_PASSWORD/" .env
    sed -i "s/^DASHBOARD_PASSWORD=.*/DASHBOARD_PASSWORD=$DASHBOARD_PASSWORD/" .env

    # ГЛАВНОЕ ИСПРАВЛЕНИЕ: экранируем PGPASSWORD прямо здесь, чтобы не зависеть от PGPASSWORD_ESC
    local PGPASSWORD_ESC=$(printf '%s\n' "$PGPASSWORD" | sed -e 's/[\/&]/\\&/g')
    sed -i "s/POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=${PGPASSWORD_ESC}/" .env
    sed -i "s/JWT_SECRET=.*/JWT_SECRET=${JWT_SECRET}/" .env

    if [ -n "$SUPABASE_DOMAIN" ]; then
        sed -i "s|^PUBLIC_URL=.*|PUBLIC_URL=https://${SUPABASE_DOMAIN}|" .env
        sed -i "s|^API_EXTERNAL_URL=.*|API_EXTERNAL_URL=https://${SUPABASE_DOMAIN}|" .env
        sed -i "s|^SITE_URL=.*|SITE_URL=https://${SUPABASE_DOMAIN}|" .env
    fi

    if ! grep -q "internal_network" docker-compose.yml; then
        cat >> docker-compose.yml <<EOF

networks:
  internal_network:
    external: true
EOF
    fi

    docker compose -p supabase up -d
    sleep 5
    for container in $(docker ps --filter "name=supabase" --format "{{.Names}}"); do
        docker network connect internal_network "$container" 2>/dev/null || true
    done
    cd ..
}

# === 5. Генерация docker-compose.yml ===
generate_compose_file() {
    cd "$SETUP_DIR"
    cat > docker-compose.yml <<EOF
networks:
  internal_network:
    external: true

volumes:
EOF
    [[ " ${SELECTED_ARRAY[@]} " =~ "postgres" ]] && echo "  postgres_data:" >> docker-compose.yml
    [[ " ${SELECTED_ARRAY[@]} " =~ "qdrant" ]] && echo "  qdrant_storage:" >> docker-compose.yml
    [[ " ${SELECTED_ARRAY[@]} " =~ "ollama" ]] && echo "  ollama_data:" >> docker-compose.yml
    [[ " ${SELECTED_ARRAY[@]} " =~ "nginx_proxy" ]] && { echo "  npm_data:" >> docker-compose.yml; echo "  npm_letsencrypt:" >> docker-compose.yml; }
    [[ " ${SELECTED_ARRAY[@]} " =~ "portainer" ]] && echo "  portainer_data:" >> docker-compose.yml
    [[ " ${SELECTED_ARRAY[@]} " =~ "n8n" ]] && echo "  n8n_data:" >> docker-compose.yml

    echo -e "\nservices:" >> docker-compose.yml

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

    if [[ " ${SELECTED_ARRAY[@]} " =~ "qdrant" ]]; then
        cat >> docker-compose.yml <<EOF
  qdrant:
    image: qdrant/qdrant:latest
    container_name: qdrant
    restart: unless-stopped
    ports:
      - "${QDRANT_PORT}:6333"
    volumes:
      - qdrant_storage:/qdrant/storage
    networks:
      - internal_network
EOF
    fi

    if [[ " ${SELECTED_ARRAY[@]} " =~ "ollama" ]]; then
        cat >> docker-compose.yml <<EOF
  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    restart: unless-stopped
    ports:
      - "${OLLAMA_PORT}:11434"
    environment:
      OLLAMA_HOST: 0.0.0.0
    volumes:
      - ollama_data:/root/.ollama
    networks:
      - internal_network
EOF
    fi

    if [[ " ${SELECTED_ARRAY[@]} " =~ "apache" ]]; then
        cat >> docker-compose.yml <<EOF
  apache:
    image: httpd:2.4-alpine
    container_name: apache
    restart: unless-stopped
    ports:
      - "${APACHE_HTTP_PORT}:80"
    volumes:
      - "${APACHE_WWW_PATH}:/usr/local/apache2/htdocs/"
      - "${APACHE_WWW_PATH}/conf:/usr/local/apache2/conf/extra/"
    networks:
      - internal_network
EOF
    fi

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

    if [[ " ${SELECTED_ARRAY[@]} " =~ "n8n" ]]; then
        local n8n_db_env=""
        if [ "${N8N_DB_POSTGRES:-0}" -eq 1 ]; then
            n8n_db_env="
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_PORT: 5432
      DB_POSTGRESDB_USER: admin
      DB_POSTGRESDB_PASSWORD: ${PGPASSWORD}
      DB_POSTGRESDB_DATABASE: n8n"
        fi
        cat >> docker-compose.yml <<EOF
  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: unless-stopped
    ports:
      - "${N8N_PORT}:5678"
    environment:${n8n_db_env}
      N8N_HOST: ${DOMAIN:-localhost}
      N8N_PORT: ${N8N_PORT}
      WEBHOOK_URL: http://${DOMAIN:-localhost}:${N8N_PORT}
    volumes:
      - n8n_data:/home/node/.n8n
    networks:
      - internal_network
EOF
    fi
}

# === 6. Запуск ===
start_containers() {
    cd "$SETUP_DIR"
    dialog --infobox "Запуск контейнеров..." 5 40
    docker compose up -d
    if [[ " ${SELECTED_ARRAY[@]} " =~ "n8n" ]] && [ "${N8N_DB_POSTGRES:-0}" -eq 1 ]; then
        sleep 10
        docker exec postgres psql -U admin -c "CREATE DATABASE n8n;" 2>/dev/null || true
    fi
}

# === 7. SSL инструкция ===
configure_nginx_ssl() {
    [[ ! " ${SELECTED_ARRAY[@]} " =~ "nginx_proxy" ]] || [ -z "$DOMAIN" ] && return 0
    sleep 10
    cat > "$SETUP_DIR/auto_ssl_commands.sh" <<EOF
# NPM: http://$(hostname -I | awk '{print $1}'):81
# login: admin@example.com pass: changeme
EOF
    chmod +x "$SETUP_DIR/auto_ssl_commands.sh"
    dialog --msgbox "Инструкция: $SETUP_DIR/auto_ssl_commands.sh" 6 50
}

# === 8. Переустановка ===
reinstall_service() {
    local svc=$1
    cd "$SETUP_DIR"
    case $svc in
        supabase) docker compose -p supabase down -v; rm -rf supabase-docker; setup_supabase ;;
        *) docker compose stop $svc || true; docker compose rm -f $svc || true; generate_compose_file; docker compose up -d $svc ;;
    esac
    dialog --msgbox "$svc переустановлен." 6 40
}

# === 9. Финальное окно с паролями ===
show_summary() {
    FIRST_IP=$(hostname -I | awk '{print $1}')
    SUMMARY="✅ Установка завершена!\nIP: $FIRST_IP\n"
    [[ -n "$DOMAIN" ]] && SUMMARY+="Домен: $DOMAIN\n"
    SUMMARY+="\nПароль PostgreSQL: $PGPASSWORD\nJWT Secret: $JWT_SECRET\n"
    echo -e "$SUMMARY" > "$STATE_DIR/summary.txt"
    dialog --title "Готово (можно копировать мышкой)" --textbox "$STATE_DIR/summary.txt" 15 60
}

# === 10. Главная ===
main() {
    if ! grep -qi "ubuntu\|debian" /etc/os-release; then echo "Только Ubuntu/Debian"; exit 1; fi
    if [ "$EUID" -ne 0 ]; then echo "Запусти с sudo"; exit 1; fi
    if ! command -v dialog &> /dev/null; then apt-get update && apt-get install -y dialog; fi

    local current_state=$(get_state)
    load_selected_services
    load_params

    if [ $# -eq 2 ] && [ "$1" == "--reinstall" ]; then reinstall_service "$2"; exit 0; fi

    case "$current_state" in
        "start")
            show_service_menu
            input_parameters || { save_state "start"; main; return; }
            install_docker
            save_state "docker_installed"
            setup_network
            setup_supabase
            generate_compose_file
            start_containers
            configure_nginx_ssl
            show_summary
            save_state "completed"
            ;;
        "docker_installed")
            setup_network
            setup_supabase
            generate_compose_file
            start_containers
            configure_nginx_ssl
            show_summary
            save_state "completed"
            ;;
        "completed")
            dialog --menu "Установка завершена. Действие:" 12 60 3 \
                "1" "Добавить/удалить сервисы" \
                "2" "Переустановить сервис" \
                "3" "Выйти" 2> "$TEMP_FILE"
            case $(cat "$TEMP_FILE") in
                1) show_service_menu; generate_compose_file; docker compose up -d; show_summary ;;
                2)
                    local installed=()
                    for svc in postgres qdrant ollama apache nginx_proxy portainer supabase n8n; do
                        docker ps --format '{{.Names}}' | grep -q "^$svc$" && installed+=("$svc" "$svc" off)
                    done
                    [ ${#installed[@]} -eq 0 ] && { dialog --msgbox "Нет установленных сервисов." 6 40; exit 0; }
                    dialog --checklist "Выберите:" 15 50 6 "${installed[@]}" 2> "$TEMP_FILE"
                    for svc in $(cat "$TEMP_FILE" | tr -d '"'); do reinstall_service "$svc"; done
                    ;;
                *) exit 0 ;;
            esac
            ;;
        *) rm -rf "$STATE_DIR"; save_state "start"; main ;;
    esac
}

main "$@"
