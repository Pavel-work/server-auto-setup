#!/bin/bash
set -uo pipefail

###############################################################################
#  Универсальный установщик сервисов v4.0
###############################################################################
#  Изменения:
#    • Убраны \Zb\Z1\Zn — чистый текст
#    • Параметры ТОЛЬКО для выбранных сервисов
#    • Причинно-следственная логика зависимостей
#    • Каждый шаг привязан к конкретному сервису
#    • Лог действий в /var/log/install.log
#    • Проверка свободного диска
###############################################################################

# ─── Глобальные пути ────────────────────────────────────────────────────────
STATE_DIR="/root/.server-setup-state"
STATE_FILE="$STATE_DIR/state.cfg"
SELECTED_FILE="$STATE_DIR/selected_services.cfg"
PARAMS_FILE="$STATE_DIR/params.env"
SETUP_DIR="/root/server-setup"
LOG_FILE="/var/log/install.log"
TMP=$(mktemp)
TMP2=$(mktemp)
REAL_USER="${SUDO_USER:-${USER:-root}}"

cleanup() { rm -f "$TMP" "$TMP2"; }
trap cleanup EXIT INT TERM

declare -a SELECTED_ARRAY=()

# ─── Логирование ────────────────────────────────────────────────────────────
log() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    printf '%s  %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE" 2>/dev/null || true
}

# ─── Утилиты кодирования ────────────────────────────────────────────────────
env_esc() {
    local v="${1:-}"
    v="${v//\\/\\\\}"
    v="${v//\"/\\\"}"
    v="${v//\$/\\\$}"
    printf '"%s"' "$v"
}

# Escape for docker-compose.yml volumes — без кавычек, просто экранирование спецсимволов
compose_esc() {
    local v="${1:-}"
    # Двойные кавычки экранируем
    v="${v//\"/\\\"}"
    printf '%s' "$v"
}

inject_env() {
    local file="$1" key="$2" value="$3" tmp
    tmp=$(mktemp)
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            "${key}="*)
                printf '%s=%s\n' "$key" "$value"
                continue
                ;;
        esac
        printf '%s\n' "$line"
    done < "$file" > "$tmp"
    mv "$tmp" "$file"
}

b64enc() {
    [[ -z "${1:-}" ]] && printf '' || printf '%s' "$1" | base64 -w0
}
b64dec() {
    [[ -z "${1:-}" ]] && printf '' || printf '%s' "$1" | base64 -d
}

load_param_b64() {
    local line val
    line=$(grep "^${2}=" "$1" 2>/dev/null | head -n1) || line=""
    [[ -z "$line" ]] && return 1
    val="${line#*=}"
    val="${val#\"}"
    val="${val%\"}"
    val="${val#\'}"
    val="${val%\'}"
    printf '%s' "$val"
}

# ─── Проверка порта ─────────────────────────────────────────────────────────
check_port() {
    local port="$1"
    local in_use=0
    if command -v ss &>/dev/null; then
        { ss -tuln 2>/dev/null | grep -qE ":${port}[^0-9]"; } && in_use=1
    elif command -v netstat &>/dev/null; then
        { netstat -tuln 2>/dev/null | grep -qE ":${port}[^0-9]"; } && in_use=1
    else
        { bash -c "echo >/dev/tcp/localhost/$port" 2>/dev/null; } && in_use=1
    fi
    if [[ $in_use -eq 1 ]]; then
        if dialog --title "Порт занят" --yesno "Порт $port уже используется.\nПопробовать другой?" 8 55; then
            return 1
        else
            exit 1
        fi
    fi
    return 0
}

# ─── is_selected ───────────────────────────────────────────────────────────
is_selected() {
    [[ ${#SELECTED_ARRAY[@]} -gt 0 ]] || return 1
    local s
    for s in "${SELECTED_ARRAY[@]}"; do
        [[ "$s" == "$1" ]] && return 0
    done
    return 1
}

# ─── State helpers ──────────────────────────────────────────────────────────
save_state() { mkdir -p "$STATE_DIR"; printf '%s' "$1" >"$STATE_FILE"; }
get_state() { [[ -f "$STATE_FILE" ]] && cat "$STATE_FILE" || echo "start"; }

save_selected_services() {
    mkdir -p "$STATE_DIR"
    if [[ ${#SELECTED_ARRAY[@]} -gt 0 ]]; then
        printf '%s\n' "${SELECTED_ARRAY[@]}" >"$SELECTED_FILE"
    else
        : >"$SELECTED_FILE"
    fi
}

load_selected_services() {
    SELECTED_ARRAY=()
    if [[ ! -f "$SELECTED_FILE" || ! -s "$SELECTED_FILE" ]]; then
        return 0
    fi
    mapfile -t SELECTED_ARRAY < "$SELECTED_FILE"
    local c=() i
    for i in "${SELECTED_ARRAY[@]}"; do
        i="${i//\"/}"
        i="${i// /}"
        i="${i//$'\r'/}"
        [[ -n "$i" ]] && c+=("$i")
    done
    SELECTED_ARRAY=("${c[@]+"${c[@]}"}")
}

# ─── save_params / load_params ──────────────────────────────────────────────
save_params() {
    mkdir -p "$STATE_DIR"
    cat >"$PARAMS_FILE" <<EOF
PGPASSWORD_B64="$(b64enc "${PGPASSWORD:-}")"
JWT_SECRET_B64="$(b64enc "${JWT_SECRET:-}")"
LLM_TYPE_B64="$(b64enc "${LLM_TYPE:-}")"
LLM_API_KEY_B64="$(b64enc "${LLM_API_KEY:-}")"
LLM_API_URL_B64="$(b64enc "${LLM_API_URL:-}")"
DOMAIN_B64="$(b64enc "${DOMAIN:-}")"
SUPABASE_DOMAIN_B64="$(b64enc "${SUPABASE_DOMAIN:-}")"
N8N_PORT_B64="$(b64enc "${N8N_PORT:-}")"
N8N_DB_POSTGRES_B64="$(b64enc "${N8N_DB_POSTGRES:-0}")"
APACHE_WWW_PATH_B64="$(b64enc "${APACHE_WWW_PATH:-}")"
APACHE_HTTP_PORT_B64="$(b64enc "${APACHE_HTTP_PORT:-}")"
QDRANT_PORT_B64="$(b64enc "${QDRANT_PORT:-}")"
OLLAMA_PORT_B64="$(b64enc "${OLLAMA_PORT:-}")"
EOF
    chmod 600 "$PARAMS_FILE"
}

declare -A _PM=(
    [PGPASSWORD]="PGPASSWORD_B64"
    [JWT_SECRET]="JWT_SECRET_B64"
    [LLM_TYPE]="LLM_TYPE_B64"
    [LLM_API_KEY]="LLM_API_KEY_B64"
    [LLM_API_URL]="LLM_API_URL_B64"
    [DOMAIN]="DOMAIN_B64"
    [SUPABASE_DOMAIN]="SUPABASE_DOMAIN_B64"
    [N8N_PORT]="N8N_PORT_B64"
    [N8N_DB_POSTGRES]="N8N_DB_POSTGRES_B64"
    [APACHE_WWW_PATH]="APACHE_WWW_PATH_B64"
    [APACHE_HTTP_PORT]="APACHE_HTTP_PORT_B64"
    [QDRANT_PORT]="QDRANT_PORT_B64"
    [OLLAMA_PORT]="OLLAMA_PORT_B64"
)

load_params() {
    PGPASSWORD="" JWT_SECRET=""
    LLM_TYPE="ollama" LLM_API_KEY="" LLM_API_URL="http://ollama:11434"
    DOMAIN="" SUPABASE_DOMAIN=""
    N8N_PORT=5678 N8N_DB_POSTGRES=0
    APACHE_WWW_PATH="$SETUP_DIR/www" APACHE_HTTP_PORT=8080
    QDRANT_PORT=6333 OLLAMA_PORT=11434

    if [[ -f "$PARAMS_FILE" ]]; then
        local k b t
        for k in "${!_PM[@]}"; do
            if b=$(load_param_b64 "$PARAMS_FILE" "${_PM[$k]}"); then
                t=$(b64dec "$b")
                printf -v "$k" "%s" "$t"
            fi
        done
    fi
    [[ "$N8N_PORT" =~ ^[0-9]+$ ]] || N8N_PORT=5678
    [[ "$APACHE_HTTP_PORT" =~ ^[0-9]+$ ]] || APACHE_HTTP_PORT=8080
    [[ "$QDRANT_PORT" =~ ^[0-9]+$ ]] || QDRANT_PORT=6333
    [[ "$OLLAMA_PORT" =~ ^[0-9]+$ ]] || OLLAMA_PORT=11434
    [[ "$N8N_DB_POSTGRES" =~ ^[01]$ ]] || N8N_DB_POSTGRES=0
}

###############################################################################
#  ДИНАМИЧЕСКАЯ НАВИГАЦИЯ
###############################################################################
_STEP=0 _STEP_MAX=0
_STEP_LABELS=() _STEP_FUNC=()
_nav_action="next"

step_reg() { _STEP_LABELS+=("$1"); _STEP_FUNC+=("$2"); }

input_port() {
    local label="$1" varname="$2" default_port="$3"
    local default_val="${!varname:-$default_port}"
    while true; do
        dialog --title "Порт $label" --inputbox "Укажите порт для $label:" 8 60 "$default_val" 2>"$TMP" \
            || { _nav_action="cancel"; return 1; }
        local val; val=$(<"$TMP")
        if [[ "$val" =~ ^[0-9]+$ ]]; then
            printf -v "$varname" "%s" "$val"
        else
            printf -v "$varname" "%s" "$default_port"
        fi
        if check_port "${!varname}"; then
            return 0
        fi
    done
}

# Строим шаги ТОЛЬКО для выбранных сервисов
build_steps() {
    _STEP_LABELS=()
    _STEP_FUNC=()
    _STEP=0

    # PostgreSQL — только если выбран postgres
    if is_selected "postgres"; then
        step_reg "PostgreSQL пароль" "s_pg"
    fi

    # LLM — только если выбран ollama
    if is_selected "ollama"; then
        step_reg "LLM Provider" "s_llm"
    fi

    # Домен — если нужен любому сервису
    if is_selected "apache" || is_selected "n8n" || is_selected "nginx_proxy" || is_selected "supabase"; then
        step_reg "Домен" "s_domain"
    fi

    # n8n порт — только если выбран n8n
    if is_selected "n8n"; then
        step_reg "n8n порт" "s_n8n_port"
    fi

    # n8n → Postgres? — только если выбраны оба
    if is_selected "n8n" && is_selected "postgres"; then
        step_reg "n8n: Postgres или SQLite?" "s_n8n_db"
    fi

    # Supabase домен — только если выбран supabase
    if is_selected "supabase"; then
        step_reg "Supabase поддомен" "s_supabase_domain"
    fi

    # JWT — только если выбран supabase
    if is_selected "supabase"; then
        step_reg "JWT Secret (Supabase)" "s_jwt"
    fi

    # Apache путь — только если выбран apache
    if is_selected "apache"; then
        step_reg "Apache путь для сайтов" "s_ap_path"
    fi

    # Apache порт — только если выбран apache
    if is_selected "apache"; then
        step_reg "Apache порт" "s_ap_port"
    fi

    # Qdrant порт — то��ько если выбран qdrant
    if is_selected "qdrant"; then
        step_reg "Qdrant порт" "s_qdrant_port"
    fi

    # Ollama порт — только если выбран ollama
    if is_selected "ollama"; then
        step_reg "Ollama порт" "s_ollama_port"
    fi

    # Финальное подтверждение — всегда
    step_reg "Подтверждение" "s_confirm"
    _STEP_MAX=${#_STEP_LABELS[@]}
}

###############################################################################
#  ОТДЕЛЬНЫЕ ШАГИ
###############################################################################

s_pg() {
    dialog --title "[$((_STEP+1))/${_STEP_MAX}] PostgreSQL" \
        --inputbox "Пароль пользователя admin (пусто = сгенерировать)\n\nShift+Insert для вставки" 10 65 \
        "${PGPASSWORD:-}" 2>"$TMP" || { _nav_action="cancel"; return 1; }
    PGPASSWORD=$(<"$TMP")
    [[ -z "$PGPASSWORD" ]] && PGPASSWORD=$(openssl rand -base64 24 | tr -d '+=/' | cut -c1-20)
    dialog --title "Готово" --msgbox "Пароль PostgreSQL:\n\n${PGPASSWORD}" 8 60
    log "PGPASSWORD set"
}

s_llm() {
    LLM_TYPE=$(dialog --title "[$((_STEP+1))/${_STEP_MAX}] LLM Provider" \
        --radiolist "Выберите LLM провайдер:" 15 60 5 \
        "ollama" "Ollama (локально)" on \
        "openai" "OpenAI (GPT)" off \
        "anthropic" "Anthropic (Claude)" off \
        "deepseek" "DeepSeek" off \
        "custom" "Custom URL" off \
        3>&1 1>&2 2>&3) || { _nav_action="cancel"; return 1; }
    case "$LLM_TYPE" in
        openai)    LLM_API_URL="https://api.openai.com/v1";;
        anthropic) LLM_API_URL="https://api.anthropic.com/v1";;
        ollama)    LLM_API_URL="http://ollama:11434"; LLM_API_KEY="";;
        deepseek)  LLM_API_URL="https://api.deepseek.com/v1";;
        custom)
            dialog --inputbox "Введите URL API:" 9 60 "${LLM_API_URL:-}" 2>"$TMP" \
                || { _nav_action="cancel"; return 1; }
            LLM_API_URL=$(<"$TMP")
            ;;
    esac
    if [[ "$LLM_TYPE" != "ollama" ]]; then
        dialog --inputbox "API ключ для ${LLM_TYPE} (пусто если нет):" 9 60 "${LLM_API_KEY:-}" 2>"$TMP" \
            || { _nav_action="cancel"; return 1; }
        LLM_API_KEY=$(<"$TMP")
    fi
    log "LLM: $LLM_TYPE -> $LLM_API_URL"
}

s_domain() {
    dialog --inputbox "Основной домен (пусто если нет):\n\nПример: example.com" 9 60 \
        "${DOMAIN:-}" 2>"$TMP" || { _nav_action="cancel"; return 1; }
    DOMAIN=$(<"$TMP")
    log "Domain: $DOMAIN"
}

s_n8n_port() { input_port "n8n" N8N_PORT 5678; }

s_n8n_db() {
    if dialog --title "[$((_STEP+1))/${_STEP_MAX}] n8n Database" \
        --yesno "Использовать PostgreSQL для n8n?\n\nНет — SQLite (файл)" 8 60; then
        N8N_DB_POSTGRES=1
    else
        N8N_DB_POSTGRES=0
    fi
    log "n8n DB: $N8N_DB_POSTGRES"
}

s_supabase_domain() {
    dialog --inputbox "Поддомен Supabase (пусто если нет):\n\nПример: sup.example.com" 9 60 \
        "${SUPABASE_DOMAIN:-}" 2>"$TMP" || { _nav_action="cancel"; return 1; }
    SUPABASE_DOMAIN=$(<"$TMP")
    log "Supabase domain: $SUPABASE_DOMAIN"
}

s_jwt() {
    dialog --title "[$((_STEP+1))/${_STEP_MAX}] JWT Secret" \
        --inputbox "Секрет для Supabase JWT (пусто = сгенерировать)" 9 60 \
        "${JWT_SECRET:-}" 2>"$TMP" || { _nav_action="cancel"; return 1; }
    JWT_SECRET=$(<"$TMP")
    [[ -z "$JWT_SECRET" ]] && JWT_SECRET=$(openssl rand -hex 32)
    log "JWT_SECRET set"
}

s_ap_path() {
    dialog --inputbox "Путь для сайтов Apache:" 9 60 \
        "${APACHE_WWW_PATH:-$SETUP_DIR/www}" 2>"$TMP" || { _nav_action="cancel"; return 1; }
    APACHE_WWW_PATH=$(<"$TMP")
    [[ -z "$APACHE_WWW_PATH" ]] && APACHE_WWW_PATH="$SETUP_DIR/www"
    APACHE_WWW_PATH=$(realpath -m "$APACHE_WWW_PATH")
    mkdir -p "$APACHE_WWW_PATH" "$APACHE_WWW_PATH/conf"
    [[ ! -f "$APACHE_WWW_PATH/index.html" ]] && echo '<h1>It works!</h1>' >"$APACHE_WWW_PATH/index.html"
    log "Apache path: $APACHE_WWW_PATH"
}

s_ap_port() { input_port "Apache" APACHE_HTTP_PORT 8080; }
s_qdrant_port() { input_port "Qdrant" QDRANT_PORT 6333; }
s_ollama_port() { input_port "Ollama" OLLAMA_PORT 11434; }

s_confirm() {
    local sf="$TMP2"
    : >"$sf"
    printf 'Выбранные сервисы:\n\n' >>"$sf"
    for s in "${SELECTED_ARRAY[@]}"; do
        printf '  - %s\n' "$s" >>"$sf"
    done
    printf '\nПараметры:\n' >>"$sf"

    if is_selected "postgres"; then
        printf '  PostgreSQL пароль: ' >>"$sf"
        if [[ -n "${PGPASSWORD:-}" ]]; then
            printf '**** (установлен)\n' >>"$sf"
        else
            printf '(не установлен)\n' >>"$sf"
        fi
    fi

    if is_selected "supabase"; then
        printf '  JWT Secret: ' >>"$sf"
        if [[ -n "${JWT_SECRET:-}" ]]; then
            printf '**** (установлен)\n' >>"$sf"
        else
            printf '(не установлен)\n' >>"$sf"
        fi
    fi

    if is_selected "ollama"; then
        printf '  LLM: %s -> %s\n' "${LLM_TYPE:-none}" "${LLM_API_URL:-}" >>"$sf"
    fi

    printf '  Домен: ' >>"$sf"
    if [[ -n "${DOMAIN:-}" ]]; then
        printf '%s\n' "${DOMAIN}" >>"$sf"
    else
        printf '(нет)\n' >>"$sf"
    fi

    if is_selected "supabase"; then
        printf '  Supabase поддомен: ' >>"$sf"
        if [[ -n "${SUPABASE_DOMAIN:-}" ]]; then
            printf '%s\n' "${SUPABASE_DOMAIN}" >>"$sf"
        else
            printf '(нет)\n' >>"$sf"
        fi
    fi

    if is_selected "n8n"; then
        if [[ "${N8N_DB_POSTGRES}" == "1" ]]; then
            printf '  n8n порт: %s (DB: Postgres)\n' "${N8N_PORT}" >>"$sf"
        else
            printf '  n8n порт: %s (DB: SQLite)\n' "${N8N_PORT}" >>"$sf"
        fi
    fi

    if is_selected "apache"; then
        printf '  Apache: порт %s, путь %s\n' "${APACHE_HTTP_PORT}" "${APACHE_WWW_PATH}" >>"$sf"
    fi

    if is_selected "qdrant"; then
        printf '  Qdrant порт: %s\n' "${QDRANT_PORT}" >>"$sf"
    fi

    if is_selected "ollama"; then
        printf '  Ollama порт: %s\n' "${OLLAMA_PORT}" >>"$sf"
    fi

    printf '\nНазад  -- изменить параметры\nДалее  -- начать установку\n' >>"$sf"

    if dialog --title "[$((_STEP+1))/${_STEP_MAX}] Подтверждение" \
        --yes-label "Далее " --no-label "Назад " \
        --yesno "$(cat "$sf")" 24 65; then
        _nav_action="next"
    else
        _nav_action="back"
    fi
}

# ─── Главный цикл навигации ────────────────────────────────────────────────
run_steps() {
    build_steps
    _STEP=0
    while true; do
        "${_STEP_FUNC[$_STEP]}"
        case "$_nav_action" in
            next)
                _STEP=$((_STEP + 1))
                [[ $_STEP -ge $_STEP_MAX ]] && return 0
                ;;
            back)
                _STEP=$((_STEP - 1))
                if [[ $_STEP -lt 0 ]]; then
                    _STEP=0
                    _nav_action="cancel"
                    return 1
                fi
                ;;
            cancel)
                return 1
                ;;
        esac
    done
}

###############################################################################
#  ПРИВЕТСТВИЕ
###############################################################################
show_welcome() {
    if dialog --title "Добро пожаловать!" \
        --yes-label "Начать " --no-label "Выйти " \
        --yesno "
Универсальный установщик сервисов v4.0

Это приложение автоматизирует установку серверных сервисов:

  - PostgreSQL       -- реляционная БД
  - Qdrant           -- векторная БД
  - Ollama           -- локальные LLM
  - Apache           -- веб-сервер
  - Nginx Proxy Mgr  -- реверс-прокси + SSL
  - Portainer        -- управление Docker
  - Supabase         -- Firebase-альтернатива
  - n8n              -- no-code автоматизация

Возможности:
  - Все параметры сохраняются -- можно продолжить
  - Навигация Назад/Далее между шагами
  - Параметры ТОЛЬКО для выбранных сервисов
  - Автоматическая проверка портов
  - Лог действий

Требования:
  - Ubuntu / Debian
  - root или sudo
  - Интернет-соединение

Внимание: установка займёт от 5 до 30 минут.
" 26 70; then
        log "Welcome screen displayed"
    else
        exit 0
    fi
}

###############################################################################
#  ВЫБОР СЕРВИСОВ
###############################################################################
show_service_menu() {
    local args=(
        "postgres" "PostgreSQL" off
        "qdrant" "Qdrant" off
        "ollama" "Ollama" off
        "apache" "Apache" off
        "nginx_proxy" "Nginx Proxy Manager" off
        "portainer" "Portainer" off
        "supabase" "Supabase" off
        "n8n" "n8n" off
    )
    if [[ ${#SELECTED_ARRAY[@]} -gt 0 ]]; then
        local i s
        for ((i=0; i<${#args[@]}; i+=3)); do
            for s in "${SELECTED_ARRAY[@]}"; do
                [[ "${args[$i]}" == "$s" ]] && args[$((i+2))]="on"
            done
        done
    fi

    dialog --title "Выбор сервисов" \
        --checklist "Выберите нужное (Пробел). Esc -- выход." 22 65 10 \
        "${args[@]}" 2>"$TMP" || { echo "Отмена."; exit 1; }

    if [[ ! -s "$TMP" ]]; then
        SELECTED_ARRAY=()
    else
        readarray -t SELECTED_ARRAY < <(tr -d '"\r' <"$TMP" | tr ' ' '\n' | grep -v '^$' || true)
        local c=() i
        for i in "${SELECTED_ARRAY[@]}"; do
            [[ -n "$i" ]] && c+=("$i")
        done
        SELECTED_ARRAY=("${c[@]+"${c[@]}"}")
    fi
    save_selected_services
    log "Services selected: ${SELECTED_ARRAY[*]:-none}"
}

###############################################################################
#  ПАРАМЕТРЫ — динамическая настройка ТОЛЬКО для выбранных сервисов
###############################################################################
input_parameters() {
    run_steps
    save_params
}

###############################################################################
#  DOCKER
###############################################################################
install_docker() {
    if ! command -v docker &>/dev/null; then
        log "Installing Docker..."
        dialog --gauge "Обновление пакетов..." 8 60 0 &
        local gauge_pid=$!

        apt-get update >/dev/null 2>&1
        kill "$gauge_pid" 2>/dev/null || true

        dialog --gauge "Скачивание установки..." 8 60 33 &
        gauge_pid=$!

        curl -fsSL https://get.docker.com -o "$TMP" >/dev/null 2>&1
        kill "$gauge_pid" 2>/dev/null || true

        dialog --gauge "Установка Docker..." 8 60 66 &
        gauge_pid=$!

        bash "$TMP" >/dev/null 2>&1
        kill "$gauge_pid" 2>/dev/null || true

        usermod -aG docker "$REAL_USER" 2>/dev/null || true
        systemctl enable docker --now >/dev/null 2>&1

        if command -v docker &>/dev/null; then
            dialog --msgbox "Docker установлен" 6 50
            log "Docker installed successfully"
        else
            log "ERROR: Docker installation failed"
            dialog --msgbox "Docker НЕ установлен. Проверьте логи." 8 55
            return 1
        fi
    fi

    if ! docker compose version &>/dev/null; then
        log "Installing docker-compose-plugin..."
        apt-get update >/dev/null 2>&1 || true
        apt-get install -y docker-compose-plugin >/dev/null 2>&1
    fi
    log "Docker ready"
    verify_docker
}

# Проверяем что Docker реально работает (pull + create)
# Если containerd повреждён — чиним автоматически
verify_docker() {
    local tmp_verify="$TMP"
    if docker pull hello-world >"$tmp_verify" 2>&1; then
        docker rm hello-world >/dev/null 2>&1 || true
        log "Docker verified OK"
        return 0
    fi

    log "Docker verification FAILED — attempting auto-repair"

    # Если ошибка "failed to lease content" — это баг containerd
    if grep -qi "failed to lease" "$tmp_verify" 2>/dev/null; then

        dialog --title "Ремонт Docker" --msgbox "Найдена проблема containerd.\nСейчас будет автоматически исправлена." 8 60

        systemctl stop docker 2>/dev/null || true
        systemctl stop containerd 2>/dev/null || true

        # Удаляем повреждённые состояния containerd
        rm -rf /var/lib/containerd/io.containerd.metadata.v1.bolt/* 2>/dev/null || true
        rm -rf /var/lib/containerd/state/* 2>/dev/null || true
        rm -rf /var/lib/containerd/tmpmounts/* 2>/dev/null || true

        systemctl start containerd 2>/dev/null || true
        sleep 2
        systemctl start docker 2>/dev/null || true
        sleep 3
        dockerd --version &>/dev/null || true

        # Повторная проверка
        if docker pull hello-world >"$tmp_verify" 2>&1; then
            docker rm hello-world >/dev/null 2>&1 || true
            log "Docker repaired and verified OK"
            dialog --msgbox "Docker успешно починен и работает." 6 50
            return 0
        fi
    fi

    # Если всё ещё не работает — показываем ошибку
    log "ERROR: Docker still broken after auto-repair"
    cat "$tmp_verify" >> "$LOG_FILE" 2>/dev/null || true
    dialog --title "Ошибка Docker" --textbox "$tmp_verify" 20 80
    exit 1

###############################################################################
#  СЕТЬ + .env
###############################################################################
setup_network() {
    docker network inspect internal_network &>/dev/null || docker network create internal_network
    mkdir -p "$SETUP_DIR"
    cd "$SETUP_DIR"

    # Динамический .env — только нужные ключи
    : >.env
    if is_selected "postgres"; then
        printf 'POSTGRES_PASSWORD=%s\n' "$(env_esc "${PGPASSWORD:-}")" >>.env
    fi
    if is_selected "supabase"; then
        printf 'JWT_SECRET=%s\n' "$(env_esc "${JWT_SECRET:-}")" >>.env
    fi
    printf 'LLM_TYPE=%s\n' "$(env_esc "${LLM_TYPE:-}")" >>.env
    printf 'LLM_API_KEY=%s\n' "$(env_esc "${LLM_API_KEY:-}")" >>.env
    printf 'LLM_API_URL=%s\n' "$(env_esc "${LLM_API_URL:-}")" >>.env
    printf 'DOMAIN=%s\n' "$(env_esc "${DOMAIN:-}")" >>.env
    if is_selected "supabase"; then
        printf 'SUPABASE_DOMAIN=%s\n' "$(env_esc "${SUPABASE_DOMAIN:-}")" >>.env
    fi
    if is_selected "n8n"; then
        printf 'N8N_PORT=%s\n' "${N8N_PORT}" >>.env
        printf 'N8N_DB_POSTGRES=%s\n' "${N8N_DB_POSTGRES}" >>.env
    fi
    if is_selected "apache"; then
        printf 'APACHE_WWW_PATH=%s\n' "$(env_esc "${APACHE_WWW_PATH:-}")" >>.env
        printf 'APACHE_HTTP_PORT=%s\n' "${APACHE_HTTP_PORT}" >>.env
    fi
    if is_selected "qdrant"; then
        printf 'QDRANT_PORT=%s\n' "${QDRANT_PORT}" >>.env
    fi
    if is_selected "ollama"; then
        printf 'OLLAMA_PORT=%s\n' "${OLLAMA_PORT}" >>.env
    fi
    chmod 600 .env
    log "Network and .env created"
}

###############################################################################
#  SUPABASE
###############################################################################
setup_supabase() {
    if ! is_selected "supabase"; then
        return 0
    fi

    cd "$SETUP_DIR"
    log "Supabase setup started"

    if [[ ! -d "supabase-docker" ]]; then
        dialog --title "Supabase (1/2)" --gauge "Клонирование репозитория..." 8 60 20 &
        local gp1=$!

        git clone --depth 1 --filter=blob:none --sparse https://github.com/supabase/supabase >/dev/null 2>&1
        (cd supabase && git sparse-checkout set docker >/dev/null 2>&1)
        mv supabase/docker supabase-docker
        rm -rf supabase
        kill "$gp1" 2>/dev/null || true

        dialog --title "Supabase" --msgbox "Repositoriy supabase скачан" 6 50
    fi

    cd supabase-docker

    # Если уже установлен — НЕ перегенерировать ключи
    if [[ -f ".env" ]] && grep -q "^ANON_KEY=" .env 2>/dev/null; then
        log "Supabase already installed, preserving keys"
        dialog --msgbox "Supabase уже установлен. Ключи сохранены." 6 55
        if [[ -n "${PGPASSWORD:-}" ]]; then
            inject_env .env POSTGRES_PASSWORD "${PGPASSWORD}"
        fi
        if [[ -n "${JWT_SECRET:-}" ]]; then
            inject_env .env JWT_SECRET "${JWT_SECRET}"
        fi
        if [[ -n "${SUPABASE_DOMAIN:-}" ]]; then
            inject_env .env PUBLIC_URL "https://${SUPABASE_DOMAIN}"
            inject_env .env API_EXTERNAL_URL "https://${SUPABASE_DOMAIN}"
            inject_env .env SITE_URL "https://${SUPABASE_DOMAIN}"
        fi
        if ! grep -q "internal_network" docker-compose.yml; then
            printf '\nnetworks:\n  internal_network:\n    external: true\n' >> docker-compose.yml
        fi
        docker compose -p supabase up -d >/dev/null 2>&1
        sleep 5
        docker ps --filter "name=supabase" --format "{{.Names}}" 2>/dev/null \
            | while IFS= read -r c; do
                docker network connect internal_network "$c" 2>/dev/null || true
              done
        cd "$SETUP_DIR"
        return 0
    fi

    cp .env.example .env
    local keys=("ANON_KEY" "SERVICE_ROLE_KEY" "SECRET_KEY_BASE" "VAULT_ENC_KEY"
                "PG_META_CRYPTO_KEY" "LOGFILE_PUBLIC_ACCESS_TOKEN"
                "LOGFILE_PRIVATE_ACCESS_TOKEN" "S3_PROTOCOL_ACCESS_KEY_SECRET")
    for key in "${keys[@]}"; do
        declare "$key=$(openssl rand -hex 32)"
    done
    S3_PROTOCOL_ACCESS_KEY_ID=$(openssl rand -hex 16)
    MINIO_ROOT_PASSWORD=$(openssl rand -hex 16)
    DASHBOARD_PASSWORD=$(openssl rand -hex 12)

    for var in ANON_KEY SERVICE_ROLE_KEY SECRET_KEY_BASE VAULT_ENC_KEY PG_META_CRYPTO_KEY \
               LOGFILE_PUBLIC_ACCESS_TOKEN LOGFILE_PRIVATE_ACCESS_TOKEN \
               S3_PROTOCOL_ACCESS_KEY_ID S3_PROTOCOL_ACCESS_KEY_SECRET \
               MINIO_ROOT_PASSWORD DASHBOARD_PASSWORD; do
        inject_env .env "$var" "${!var}"
    done
    if [[ -n "${JWT_SECRET:-}" ]]; then
        inject_env .env JWT_SECRET "${JWT_SECRET}"
    fi
    if [[ -n "${SUPABASE_DOMAIN:-}" ]]; then
        inject_env .env PUBLIC_URL "https://${SUPABASE_DOMAIN}"
        inject_env .env API_EXTERNAL_URL "https://${SUPABASE_DOMAIN}"
        inject_env .env SITE_URL "https://${SUPABASE_DOMAIN}"
    fi
    if ! grep -q "internal_network" docker-compose.yml; then
        printf '\nnetworks:\n  internal_network:\n    external: true\n' >> docker-compose.yml
    fi

    dialog --title "Supabase (2/2)" --gauge "Запуск контейнеров..." 8 60 50 &
    local gp2=$!
    docker compose -p supabase up -d >/dev/null 2>&1
    kill "$gp2" 2>/dev/null || true
    sleep 10

    docker ps --filter "name=supabase" --format "{{.Names}}" 2>/dev/null \
        | while IFS= read -r c; do
            docker network connect internal_network "$c" 2>/dev/null || true
          done
    cd "$SETUP_DIR"
    log "Supabase setup completed"
}

###############################################################################
#  ГЕНЕРАЦИЯ docker-compose.yml
###############################################################################
generate_compose_file() {
    cd "$SETUP_DIR"
    local _pg=""
    if is_selected "postgres"; then
        _pg=$(env_esc "${PGPASSWORD:-}")
    fi
    local _www
    _www=$(compose_esc "${APACHE_WWW_PATH:-}")

    # Определяем есть ли именованные тома
    local has_volumes=0
    if is_selected "postgres" || is_selected "qdrant" || is_selected "ollama" || is_selected "nginx_proxy" || is_selected "portainer" || is_selected "n8n"; then
        has_volumes=1
    fi

    {
        echo 'networks:'
        echo '  internal_network:'
        echo '    external: true'
        if [[ $has_volumes -eq 1 ]]; then
            echo 'volumes:'
            is_selected "postgres"  && echo '  postgres_data:'
            is_selected "qdrant"    && echo '  qdrant_storage:'
            is_selected "ollama"    && echo '  ollama_data:'
            if is_selected "nginx_proxy"; then
                echo '  npm_data:'
                echo '  npm_letsencrypt:'
            fi
            is_selected "portainer" && echo '  portainer_data:'
            is_selected "n8n"       && echo '  n8n_data:'
        else
            echo 'volumes: {}'
        fi
        echo 'services:'
    } >docker-compose.yml

    # --- PostgreSQL ---
    if is_selected "postgres"; then
        cat >>docker-compose.yml <<YEOF
  postgres:
    image: postgres:16-alpine
    container_name: postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: admin
      POSTGRES_PASSWORD: ${_pg}
      POSTGRES_DB: appdb
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - internal_network
YEOF
    fi

    # --- Qdrant ---
    if is_selected "qdrant"; then
        cat >>docker-compose.yml <<YEOF
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
YEOF
    fi

    # --- Ollama ---
    if is_selected "ollama"; then
        cat >>docker-compose.yml <<YEOF
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
YEOF
    fi

    # --- Apache ---
    if is_selected "apache"; then
        cat >>docker-compose.yml <<YEOF
  apache:
    image: httpd:2.4-alpine
    container_name: apache
    restart: unless-stopped
    ports:
      - "${APACHE_HTTP_PORT}:80"
    volumes:
      - "${_www}:/usr/local/apache2/htdocs/"
      - "${_www}/conf:/usr/local/apache2/conf/extra/"
    networks:
      - internal_network
YEOF
    fi

    # --- Nginx Proxy Manager ---
    if is_selected "nginx_proxy"; then
        cat >>docker-compose.yml <<'YEOF'
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
YEOF
    fi

    # --- Portainer ---
    if is_selected "portainer"; then
        cat >>docker-compose.yml <<'YEOF'
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
YEOF
    fi

    # --- n8n ---
    if is_selected "n8n"; then
        local n8n_db=""
        if [[ "${N8N_DB_POSTGRES:-0}" -eq 1 ]] && is_selected "postgres"; then
            n8n_db="$(printf '
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_PORT: 5432
      DB_POSTGRESDB_USER: admin
      DB_POSTGRESDB_PASSWORD: %s
      DB_POSTGRESDB_DATABASE: n8n' "${_pg}")"
        fi
        cat >>docker-compose.yml <<YEOF
  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: unless-stopped
    ports:
      - "${N8N_PORT}:5678"
    environment:${n8n_db}
      N8N_HOST: 0.0.0.0
      N8N_PORT: 5678
      WEBHOOK_URL: http://${DOMAIN:-localhost}:${N8N_PORT}
    volumes:
      - n8n_data:/home/node/.n8n
    networks:
      - internal_network
YEOF
    fi

    log "docker-compose.yml generated"
}

###############################################################################
#  ЗАПУСК КОНТЕЙНЕРОВ
###############################################################################
start_containers() {
    cd "$SETUP_DIR"
    dialog --gauge "Запуск контейнеров..." 8 60 10 &
    local gp=$!
    local compose_err="$TMP2"

    # Запускаем и сохраняем вывод — без заглушек!
    if ! docker compose up -d >"$compose_err" 2>&1; then
        kill "$gp" 2>/dev/null || true
        log "ERROR: docker compose up failed"
        cat "$compose_err" >> "$LOG_FILE" 2>/dev/null || true
        dialog --title "Ошибка при запуске" --textbox "$compose_err" 20 80
        exit 1
    fi
    kill "$gp" 2>/dev/null || true

    # Проверяем что контейнеры действительно запустились
    dialog --gauge "Проверка контейнеров..." 8 60 80 &
    gp=$!
    sleep 3
    kill "$gp" 2>/dev/null || true

    local running_count
    running_count=$(docker ps --filter "label=com.docker.compose.project" --format '{{.Names}}' 2>/dev/null | wc -l)
    if [[ "$running_count" -eq 0 ]]; then
        log "ERROR: No containers started"
        cat "$compose_err" >> "$LOG_FILE" 2>/dev/null || true
        dialog --title "Ошибка" --msgbox "Контейнеры не запустились. Лог: $compose_err" 8 60
        exit 1
    fi
    log "Containers started: $running_count running"

    # n8n database
    if is_selected "n8n" && [[ "${N8N_DB_POSTGRES:-0}" -eq 1 ]] && is_selected "postgres"; then
        sleep 15
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^postgres$'; then
            docker exec -e PGPASSWORD="${PGPASSWORD}" postgres \
                psql -U admin -c "CREATE DATABASE n8n;" >/dev/null 2>&1 || true
        fi
    fi
    log "Containers started successfully"
}

###############################################################################
#  NPM INFO
###############################################################################
print_npm_info() {
    if ! is_selected "nginx_proxy"; then
        return 0
    fi
    local ip
    ip=$(hostname -I | awk '{print $1}')
    sleep 5
    cat >"$SETUP_DIR/npm_info.txt" <<EOF
NPM: http://${ip}:81
Login: admin@example.com
Pass:  changeme
EOF
}

###############################################################################
#  ФИНАЛЬНАЯ СВОДКА
###############################################################################
show_final_summary() {
    local ip
    ip=$(hostname -I | awk '{print $1}')
    local sf="$STATE_DIR/final_summary.txt"
    local running
    running=$(docker ps --format "{{.Names}} ({{.Image}}) -> {{.Status}}" 2>/dev/null) || running=""

    : >"$sf"
    cat >>"$sf" <<SUM
==================================================
          УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО
==================================================

  Сервер:  $ip

--- Установленные контейнеры ---
SUM
    if [[ -n "$running" ]]; then
        echo "$running" >>"$sf"
    else
        echo "  (нет данных)" >>"$sf"
    fi

    cat >>"$sf" <<SUM

--- Директории ---
  Setup dir:       $SETUP_DIR
  docker-compose:  $SETUP_DIR/docker-compose.yml
  .env файл:       $SETUP_DIR/.env
  Apache www:      ${APACHE_WWW_PATH:-(не выбран)}
  State dir:       $STATE_DIR
SUM

    if is_selected "supabase" && [[ -f "$SETUP_DIR/supabase-docker/.env" ]]; then
        echo >>"$sf"
        echo "--- Supabase ключи ---" >>"$sf"
        grep "^ANON_KEY=" "$SETUP_DIR/supabase-docker/.env" >>"$sf" 2>/dev/null || echo "  ANON_KEY: не найден" >>"$sf"
        grep "^SERVICE_ROLE_KEY=" "$SETUP_DIR/supabase-docker/.env" >>"$sf" 2>/dev/null || true
    fi

    echo >>"$sf"
    echo "--- Доступы ---" >>"$sf"
    if is_selected "postgres"; then
        printf '  PostgreSQL: admin / %s\n' "${PGPASSWORD:-(не установлен)}" >>"$sf"
    fi
    if is_selected "supabase"; then
        printf '  JWT Secret: %s\n' "${JWT_SECRET:-(не установлен)}" >>"$sf"
    fi
    if is_selected "ollama"; then
        printf '  LLM Type: %s -> %s\n' "${LLM_TYPE:-(не выбран)}" "${LLM_API_URL:-(не указан)}" >>"$sf"
    fi
    printf '  LLM API Key: ' >>"$sf"
    if [[ -n "${LLM_API_KEY:-}" ]]; then
        printf '%s*****\n' "${LLM_API_KEY:0:4}" >>"$sf"
    else
        printf '(не указан)\n' >>"$sf"
    fi

    echo >>"$sf"
    echo "--- Веб-интерфейсы ---" >>"$sf"
    if is_selected "portainer"; then
        echo "  Portainer:     http://$ip:9000" >>"$sf"
    fi
    if is_selected "nginx_proxy"; then
        echo "  Nginx Proxy:   http://$ip:81  (admin@example.com / changeme)" >>"$sf"
    fi
    if is_selected "supabase"; then
        echo "  Supabase:      https://${SUPABASE_DOMAIN:-$ip}" >>"$sf"
    fi
    if is_selected "n8n"; then
        echo "  n8n:           http://${DOMAIN:-$ip}:${N8N_PORT}" >>"$sf"
    fi
    if is_selected "apache"; then
        echo "  Apache:        http://${DOMAIN:-$ip}:${APACHE_HTTP_PORT}" >>"$sf"
    fi
    if is_selected "qdrant"; then
        echo "  Qdrant:        http://$ip:${QDRANT_PORT}" >>"$sf"
    fi
    if is_selected "ollama"; then
        echo "  Ollama:        http://$ip:${OLLAMA_PORT}" >>"$sf"
    fi

    cat >>"$sf" <<SUM

--- Сохранённые файлы ---
  $STATE_DIR/params.env            -- параметры
  $STATE_DIR/selected_services.cfg -- список сервисов
  $LOG_FILE                        -- лог установки
  $SETUP_DIR/npm_info.txt          -- NPM доступы

  Сохраните эту информацию! Ключи не показываются повторно.
==========================================================
SUM
    chmod 600 "$sf"
    dialog --textbox "$sf" 28 72
    log "Final summary displayed"
}

###############################################################################
#  ПЕРЕУСТАНОВКА / СТАТУС
###############################################################################
reinstall_service() {
    local svc="$1"
    cd "$SETUP_DIR"
    case "$svc" in
        supabase)
            if ! dialog --yesno "Переустановить Supabase?\n\nВСЕ ДАННЫЕ БУДУТ УДАЛЕНЫ (-v)\nСделайте backup!" 8 60; then
                return 0
            fi
            docker compose -p supabase down -v 2>/dev/null || true
            rm -rf supabase-docker
            setup_supabase
            ;;
        *)
            log "Reinstalling $svc..."
            generate_compose_file
            docker compose stop "$svc" 2>/dev/null || true
            docker compose rm -fv "$svc" 2>/dev/null || true
            docker compose up -d "$svc" >/dev/null 2>&1
            ;;
    esac
    dialog --msgbox "${svc} переустановлен." 6 45
}

show_status() {
    docker compose ps 2>"$TMP2" || echo "Compose не найден в $SETUP_DIR" >"$TMP2"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null >>"$TMP2" || true
    dialog --title "Статус контейнеров" --textbox "$TMP2" 20 80
}

###############################################################################
#  POST-INSTALL МЕНЮ
###############################################################################
post_install_menu() {
    while true; do
        dialog --title "Post-install управление" --menu \
            "Установка завершена. Выберите действие:" 16 60 7 \
            "1" "Добавить/удалить сервисы" \
            "2" "Переустановить сервис" \
            "3" "Проверить статус" \
            "4" "Показать сводку" \
            "5" "Показать лог" \
            "6" "Сбросить всё" \
            "0" "Выйти" 2>"$TMP" || return 0

        local choice
        choice=$(<"$TMP")
        case "$choice" in
            1)
                run_steps
                save_params
                setup_network
                setup_supabase
                generate_compose_file
                docker compose down --remove-orphans >/dev/null 2>&1 || true
                docker compose up -d >/dev/null 2>&1 || true
                show_final_summary
                ;;
            2)
                local arr=() names svc
                names=$(docker ps --format '{{.Names}}' 2>/dev/null) || names=""
                for svc in postgres qdrant ollama apache nginx-proxy-manager portainer supabase n8n; do
                    if echo "$names" | grep -q "^${svc}$"; then
                        arr+=("$svc" "$svc" off)
                    fi
                done
                if [[ ${#arr[@]} -eq 0 ]]; then
                    dialog --msgbox "Нет запущенных сервисов." 6 50
                    continue
                fi
                dialog --checklist "Выберите для переустановки:" 15 60 6 "${arr[@]}" 2>"$TMP" || continue
                local ch
                while IFS= read -r ch; do
                    ch="${ch//\"/}"
                    [[ -n "$ch" ]] && reinstall_service "$ch"
                done <"$TMP"
                ;;
            3)
                show_status
                ;;
            4)
                show_final_summary
                ;;
            5)
                if [[ -f "$LOG_FILE" ]]; then
                    dialog --title "Лог" --textbox "$LOG_FILE" 24 80
                else
                    dialog --msgbox "Лог недоступен: $LOG_FILE" 6 50
                fi
                ;;
            6)
                if ! dialog --yesno "Сбросить ВСЁ?\n\nБудут удалены:\n  - ${STATE_DIR}\n  - compose down -v\n  - данные Supabase" 10 60; then
                    continue
                fi
                (cd "$SETUP_DIR" && docker compose down -v 2>/dev/null || true)
                docker compose -p supabase down -v 2>/dev/null || true
                rm -rf "$STATE_DIR" "$SETUP_DIR"
                dialog --msgbox "Всё сброшено." 6 50
                exec "$0"
                ;;
            0)
                return 0
                ;;
        esac
    done
}

###############################################################################
#  ГЛАВНАЯ
###############################################################################
main() {
    if ! grep -qi "ubuntu\|debian" /etc/os-release 2>/dev/null; then
        echo "Поддерживаются только Ubuntu/Debian"
        exit 1
    fi
    if [[ "$EUID" -ne 0 ]]; then
        echo "Запустите с sudo"
        exit 1
    fi
    if ! command -v dialog &>/dev/null; then
        apt-get update >/dev/null 2>&1 || true
        apt-get install -y dialog >/dev/null 2>&1 \
            || { echo "Не удалось установить dialog"; exit 1; }
    fi

    # Проверка свободного места (нужно >= 5 GB)
    local avail_gb
    avail_gb=$(df -BG / | awk 'NR==2{gsub(/G/,""); print $4}')
    if [[ "$avail_gb" =~ ^[0-9]+$ ]] && [[ "$avail_gb" -lt 5 ]]; then
        dialog --msgbox "Доступно ${avail_gb} GB. Нужно минимум 5 GB." 8 55
        exit 1
    fi

    load_selected_services
    load_params

    if [[ $# -eq 2 ]] && [[ "$1" == "--reinstall" ]]; then
        reinstall_service "$2"
        exit 0
    fi

    local state
    state=$(get_state)
    case "$state" in
        start)
            show_welcome
            show_service_menu
            if [[ ${#SELECTED_ARRAY[@]} -eq 0 ]]; then
                dialog --msgbox "Ничего не выбрано." 6 50
                exit 1
            fi
            if ! input_parameters; then
                save_state "start"
                exit 4
            fi
            install_docker
            save_state "done"
            setup_network
            setup_supabase
            generate_compose_file
            start_containers
            print_npm_info
            show_final_summary
            save_state "completed"
            ;;
        done|docker_installed|network_needed)
            setup_network
            setup_supabase
            generate_compose_file
            start_containers
            print_npm_info
            show_final_summary
            save_state "done"
            ;;
        completed)
            show_final_summary
            ;;
    esac

    post_install_menu
}

main "$@"
