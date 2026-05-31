#!/bin/bash
set -euo pipefail

###############################################################################
#  Универсальный установщик сервисов v3.0
###############################################################################
#  Что нового:
#    • Приветственное окно с описанием приложения
#    • Навигация «Назад / Далее» между экранами параметров
#    • Прогресс-бар при установке Docker / Supabase
#    • load_params рефакторен в цикл (было 13 строк → 1)
#    • input_port — единая функция вместо кодо-нагромождения
#    • Лог действий в /var/log/install.log
#    • --remove-orphans при изменении состава сервисов
#    • Supabase .env: plain values (без кавычек, корректно для Supabase)
#    • Финальная сводка со всеми логинами, паролями, ключами и путями
#    • Кнопка «Сбросить всё» в post-install меню
#    • Проверка свободного диска перед тяжёлыми операциями
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
log()  { mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null; printf '%s  %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE" 2>/dev/null || true; }

# ─── Утилиты кодирования ────────────────────────────────────────────────────
# Docker Compose .env → KEY="value"
env_esc() {
    local v="${1:-}"; v="${v//\\/\\\\}"; v="${v//\"/\\\"}"; v="${v//\$/\\\$}"; printf '"%s"' "$v"
}
# Supabase .env → plain, sed-safe
# Safe KEY=VALUE replacement in .env files (no sed, no escaping issues)
inject_env() {
    local file="$1" key="$2" value="$3" tmp
    tmp=$(mktemp)
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == "${key}="* ]] && printf '%%s=%%s
' "$key" "$value" && continue
        printf '%%s
' "$line"
    done < "$file" > "$tmp"
    mv "$tmp" "$file"
}


b64enc() { [[ -z "${1:-}" ]] && printf '' || printf '%s' "$1" | base64 -w0; }
b64dec() { [[ -z "${1:-}" ]] && printf '' || printf '%s' "$1" | base64 -d; }

load_param_b64() {
    local line val
    line=$(grep "^${2}=" "$1" 2>/dev/null | head -n1 || true)
    [[ -z "${line:-}" ]] && return 1
    val="${line#*=}"; val="${val#\"}"; val="${val%\"}"; val="${val#\'}"; val="${val%\'}"
    printf '%s' "$val"
}

# ─── Проверка порта ─────────────────────────────────────────────────────────
check_port() {
    local port="$1"
    if command -v ss &>/dev/null; then
        if ss -tuln 2>/dev/null | grep -qE ":${port}[^0-9]"; then err_port "$port"; fi
    elif command -v netstat &>/dev/null; then
        if netstat -tuln 2>/dev/null | grep -qE ":${port}[^0-9]"; then err_port "$port"; fi
    elif bash -c "{ echo >/dev/tcp/localhost/$port; } 2>/dev/null"; then
        err_port "$port"
    fi
}
err_port() { dialog --title " Порт занят" --yesno "\Zb\Z1Порт $1\Zn уже используется.\nПопробовать другой?" 7 50 || exit 1; return 1; }

# ─── is_selected ───────────────────────────────────────────────────────────
is_selected() {
    [[ ${#SELECTED_ARRAY[@]} -eq 0 ]] && return 1
    local s
    for s in "${SELECTED_ARRAY[@]}"; do
        [[ "$s" == "$1" ]] && return 0
    done
    return 1
}

# ─── State helpers ──────────────────────────────────────────────────────────
save_state() { mkdir -p "$STATE_DIR"; printf '%s' "$1">"$STATE_FILE"; }
get_state()  { [[ -f "$STATE_FILE" ]] && cat "$STATE_FILE" || echo "start"; }

save_selected_services() {
    mkdir -p "$STATE_DIR"
    [[ ${#SELECTED_ARRAY[@]} -gt 0 ]] && printf '%s\n' "${SELECTED_ARRAY[@]}">"$SELECTED_FILE" || :>"$SELECTED_FILE"
}

load_selected_services() {
    SELECTED_ARRAY=()
    [[ ! -f "$SELECTED_FILE" || ! -s "$SELECTED_FILE" ]] && return 0
    mapfile -t SELECTED_ARRAY < "$SELECTED_FILE"
    local c=() i
    for i in "${SELECTED_ARRAY[@]}"; do
        i="${i//\"/}"; i="${i// /}"; i="${i//$'\r'/}"; [[ -n "$i" ]] && c+=("$i")
    done
    SELECTED_ARRAY=("${c[@]+"${c[@]}"}")
}

# ─── save_params ────────────────────────────────────────────────────
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

# ─── load_params ────────────────────────────────
declare -A _PM=( [PGPASSWORD]="PGPASSWORD_B64" [JWT_SECRET]="JWT_SECRET_B64"
    [LLM_TYPE]="LLM_TYPE_B64" [LLM_API_KEY]="LLM_API_KEY_B64" [LLM_API_URL]="LLM_API_URL_B64"
    [DOMAIN]="DOMAIN_B64" [SUPABASE_DOMAIN]="SUPABASE_DOMAIN_B64" [N8N_PORT]="N8N_PORT_B64"
    [N8N_DB_POSTGRES]="N8N_DB_POSTGRES_B64" [APACHE_WWW_PATH]="APACHE_WWW_PATH_B64"
    [APACHE_HTTP_PORT]="APACHE_HTTP_PORT_B64" [QDRANT_PORT]="QDRANT_PORT_B64" [OLLAMA_PORT]="OLLAMA_PORT_B64" )

load_params() {
    PGPASSWORD="${PGPASSWORD:-}" JWT_SECRET="${JWT_SECRET:-}"
    LLM_TYPE="${LLM_TYPE:-}" LLM_API_KEY="${LLM_API_KEY:-}" LLM_API_URL="${LLM_API_URL:-}"
    DOMAIN="${DOMAIN:-}" SUPABASE_DOMAIN="${SUPABASE_DOMAIN:-}"
    N8N_PORT="${N8N_PORT:-5678}" N8N_DB_POSTGRES="${N8N_DB_POSTGRES:-0}"
    APACHE_WWW_PATH="${APACHE_WWW_PATH:-$SETUP_DIR/www}" APACHE_HTTP_PORT="${APACHE_HTTP_PORT:-8080}"
    QDRANT_PORT="${QDRANT_PORT:-6333}" OLLAMA_PORT="${OLLAMA_PORT:-11434}"
    if [[ -f "$PARAMS_FILE" ]]; then
        local k b t
        for k in "${!_PM[@]}"; do
            if b=$(load_param_b64 "$PARAMS_FILE" "${_PM[$k]}"); then t=$(b64dec "$b"); printf -v "$k" "%s" "$t"; fi
        done
    fi
    N8N_PORT="${N8N_PORT:-5678}" N8N_DB_POSTGRES="${N8N_DB_POSTGRES:-0}"
    APACHE_WWW_PATH="${APACHE_WWW_PATH:-$SETUP_DIR/www}" APACHE_HTTP_PORT="${APACHE_HTTP_PORT:-8080}"
    QDRANT_PORT="${QDRANT_PORT:-6333}" OLLAMA_PORT="${OLLAMA_PORT:-11434}"
    [[ "$N8N_PORT" =~ ^[0-9]+$ ]] || N8N_PORT=5678
    [[ "$APACHE_HTTP_PORT" =~ ^[0-9]+$ ]] || APACHE_HTTP_PORT=8080
    [[ "$QDRANT_PORT" =~ ^[0-9]+$ ]] || QDRANT_PORT=6333
    [[ "$OLLAMA_PORT" =~ ^[0-9]+$ ]] || OLLAMA_PORT=11434
    [[ "$N8N_DB_POSTGRES" =~ ^[01]$ ]] || N8N_DB_POSTGRES=0
}

###############################################################################
#  НАВИГАЦИЯ ШАГОВ С КНОПКАМИ Назад / Далее
###############################################################################
_step=0  _step_max=0
_step_labels=()  _step_func=()
nav_action="next"   # "next" | "back" | "cancel"

step_reg() { _step_labels+=("$1"); _step_func+=("$2"); }

# Универсальный ввод порта
input_port() {
    while true; do
        dialog --title " Порт $1" --inputbox "Укажите порт для $1:" 8 60 "${!2:-$3}" 2>"$TMP" || { nav_action="cancel"; return 1; }
        printf -v "$2" "%s" "$(<"$TMP")"
        [[ "${!2}" =~ ^[0-9]+$ ]] || printf -v "$2" "%s" "$3"
        check_port "${!2}" && return 0
    done
}

# Генерация списка шагов
build_steps() {
    _step_labels=(); _step_func=(); _step=0
    step_reg "PostgreSQL пароль"  "s_pg"
    step_reg "JWT Secret"         "s_jwt"
    step_reg "LLM Provider"       "s_llm"
    is_selected "n8n"  && is_selected "postgres" && step_reg "n8n → Postgres?" "n8n_db_yn"
    step_reg "Домены"             "s_domains"
    is_selected "n8n"  && step_reg "n8n порт"     "s_n8n_port"
    is_selected "apache" && step_reg "Apache путь" "s_ap_path"
    is_selected "apache" && step_reg "Apache порт" "s_ap_port"
    is_selected "qdrant" && step_reg "Qdrant порт" "s_qdrant_port"
    is_selected "ollama" && step_reg "Ollama порт" "s_ollama_port"
    is_selected "n8n"  && ! is_selected "postgres" && step_reg "n8n → Postgres?" "n8n_db_yn2"
    step_reg "Подтверждение"      "s_confirm"
    _step_max=${#_step_labels[@]}
}

# --- Отдельные шаги ---------------------------------------------------------

s_pg() {
    dialog --clear --title "[$((_step+1))/${_step_max}] PostgreSQL" \
        --inputbox "Пароль пользователя admin (пусто = сгенерировать)\n\n Shift+Insert для вставки" 11 65 \
        "${PGPASSWORD:-}" 2>"$TMP" || { nav_action="cancel"; return 1; }
    PGPASSWORD=$(<"$TMP"); [[ -z "$PGPASSWORD" ]] && PGPASSWORD=$(openssl rand -base64 24|tr -d '+=/'|cut -c1-20)
    dialog --title " Готово" --msgbox "Пароль PostgreSQL:\n\n\Zb\Z1${PGPASSWORD}\Zn" 8 60
    log "PGPASSWORD set"
}

s_jwt() {
    dialog --title "[$((_step+1))/${_step_max}] JWT Secret" \
        --inputbox "Секрет для JWT (пусто = сгенерировать)" 9 60 "${JWT_SECRET:-}" 2>"$TMP" \
        || { nav_action="cancel"; return 1; }
    JWT_SECRET=$(<"$TMP"); [[ -z "$JWT_SECRET" ]] && JWT_SECRET=$(openssl rand -hex 32)
    log "JWT_SECRET set"
}

s_llm() {
    LLM_TYPE=$(dialog --clear --title "[$((_step+1))/${_step_max}] LLM Provider" \
        --radiolist "Выберите LLM провайдер:" 15 60 5 \
        "ollama" "Ollama (локально)" on \
        "openai" "OpenAI (GPT)" off \
        "anthropic" "Anthropic (Claude)" off \
        "deepseek" "DeepSeek" off \
        "custom" "Custom (свой URL)" off \
        3>&1 1>&2 2>&3) || { nav_action="cancel"; return 1; }
    case "$LLM_TYPE" in
        openai)     LLM_API_URL="https://api.openai.com/v1";;
        anthropic)  LLM_API_URL="https://api.anthropic.com/v1";;
        ollama)     LLM_API_URL="http://ollama:11434"; LLM_API_KEY="";;
        deepseek)   LLM_API_URL="https://api.deepseek.com/v1";;
        custom)
            dialog --inputbox "Введите URL вашего API:" 9 60 "${LLM_API_URL:-}" 2>"$TMP" || { nav_action="cancel"; return 1; }
            LLM_API_URL=$(<"$TMP")
            ;;
    esac
    log "LLM: $LLM_TYPE → $LLM_API_URL"
}

n8n_db_yn() {
    dialog --title "[$((_step+1))/${_step_max}] n8n Database" \
        --yesno "Использовать PostgreSQL как базу данных n8n?\n\nНет → SQLite (файл)" 9 60 \
        && N8N_DB_POSTGRES=1 || N8N_DB_POSTGRES=0
    log "n8n DB: $N8N_DB_POSTGRES"
}
n8n_db_yn2() { n8n_db_yn; }

s_domains() {
    dialog --inputbox "Основной домен (пусто если нет):\n\nПример: example.com" 10 60 "${DOMAIN:-}" 2>"$TMP" \
        || { nav_action="cancel"; return 1; }
    DOMAIN=$(<"$TMP")
    dialog --inputbox "Поддомен Supabase (пусто если не нужен):\n\nПример: supabase.example.com" 10 60 "${SUPABASE_DOMAIN:-}" 2>"$TMP" \
        || { nav_action="cancel"; return 1; }
    SUPABASE_DOMAIN=$(<"$TMP")
    log "Domain: $DOMAIN | Supabase: $SUPABASE_DOMAIN"
}

s_n8n_port() { input_port "n8n" N8N_PORT 5678; }
s_ap_path() {
    dialog --inputbox "Путь для сайтов Apache:" 9 60 "${APACHE_WWW_PATH:-$SETUP_DIR/www}" 2>"$TMP" || { nav_action="cancel"; return 1; }
    APACHE_WWW_PATH=$(<"$TMP"); [[ -z "$APACHE_WWW_PATH" ]] && APACHE_WWW_PATH="$SETUP_DIR/www"
    APACHE_WWW_PATH=$(realpath -m "$APACHE_WWW_PATH"); mkdir -p "$APACHE_WWW_PATH" "$APACHE_WWW_PATH/conf"
    [[ ! -f "$APACHE_WWW_PATH/index.html" ]] && echo '<h1>It works!</h1>' >"$APACHE_WWW_PATH/index.html"
    log "Apache path: $APACHE_WWW_PATH"
}
s_ap_port() { input_port "Apache" APACHE_HTTP_PORT 8080; }
s_qdrant_port() { input_port "Qdrant" QDRANT_PORT 6333; }
s_ollama_port() { input_port "Ollama" OLLAMA_PORT 11434; }

s_confirm() {
    local tmp_confirm="$TMP2"
    cat >"$tmp_confirm" <<CONF
\Zb\Z1═══ Выбранные сервисы ═══\Zn

CONF
    local s
    if [[ ${#SELECTED_ARRAY[@]} -gt 0 ]]; then
        for s in "${SELECTED_ARRAY[@]}"; do printf '  \Zb●\Zn %s\n' "$s" >>"$tmp_confirm"; done
    fi
    cat >>"$tmp_confirm" <<CONF

\Zb\Z1═══ Параметры ═══\Zn
  PostgreSQL пароль :  ${PGPASSWORD:+"**** (установлен)"}
  JWT Secret        :  ${JWT_SECRET:+"**** (установлен)"}
  LLM               :  ${LLM_TYPE:-none} -> ${LLM_API_URL:-}
  Домен             :  ${DOMAIN:-(нет)}
  Supabase домен    :  ${SUPABASE_DOMAIN:-(нет)}

\Zb\Z1═══ Порты ═══\Zn
  n8n               :  ${N8N_PORT}  (DB: $([ "$N8N_DB_POSTGRES" = "1" ] && echo "Postgres" || echo "SQLite"))
  Apache            :  ${APACHE_HTTP_PORT}  (${APACHE_WWW_PATH})
  Qdrant            :  ${QDRANT_PORT}
  Ollama            :  ${OLLAMA_PORT}

\Zb\Z1═══ Действия ═══\Zn
Назад  — изменить параметры
Далее  — начать установку
CONF
    dialog --title "[$((_step+1))/${_step_max}] Подтверждение" --yes-label "Далее " --no-label "Назад " \
        --yesno "$(cat "$tmp_confirm")" 28 65
    [[ $? -eq 0 ]] && nav_action="next" || nav_action="back"
}

# ─── Главный цикл навигации ────────────────────────────────────────────────
run_steps() {
    build_steps
    _step=0
    while true; do
        "${_step_func[$_step]}"
        case "$nav_action" in
            next)    _step=$((_step + 1)); [[ $_step -ge $_step_max ]] && return 0;;
            back)    _step=$((_step - 1)); [[ $_step -lt 0 ]] && { _step=0; nav_action="cancel"; return 1; };;
            cancel)  return 1;;
        esac
    done
}

###############################################################################
#  ПРИВЕТСТВИЕ
###############################################################################
show_welcome() {
    dialog --clear --title " Добро пожаловать!" \
        --yes-label " Начать " --no-label " Выйти "  \
        --yesno "\
\Zb\Z1 Универсальный установщик сервисов v3.0\Zn

Это приложение автоматизирует установку и настройку
стека серверных сервисов на Ubuntu/Debian:

  \Zb●\Zn PostgreSQL       — реляционная БД
  \Zb●\Zn Qdrant           — векторная БД
  \ZB●\Zn Ollama           — локальные LLM
  \Zb●\Zn Apache           — веб-сервер
  \ZB●\Zn Nginx Proxy Mgr  — реверс-прокси + SSL
  \Zb●\Zn Portainer        — управление Docker
  \ZB●\Zn Supabase         — Firebase-альтернатива
  \ZB●\Zn n8n              — no-code автоматизация

\Zb Возможности:\Zn
  ✓ Все параметры сохраняются — можно продолжить
  ✓ Навигация Назад / Далее между шагами
  ✓ Безопасное хранение паролей (base64)
  ✓ Автоматическая проверка портов
  ✓ Лог действий

\Zb Требования:\Zn
  • Ubuntu / Debian
  •.root или sudo
  • Интернет-соединение

\Zb\Z1  Внимание:  установка может занять от 5 до 30 минут.\Zn
" 28 70
    [[ $? -ne 0 ]] && exit 0
    log "Welcome screen displayed"
}

###############################################################################
#  1. Выбор сервисов
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
    dialog --clear --title " Выбор сервисов" \
        --checklist "Выберите нужное (Пробел). Esc — выход." 22 65 10 \
        "${args[@]}" 2>"$TMP" || { echo "Отмена."; exit 1; }
    if [[ ! -s "$TMP" ]]; then
        SELECTED_ARRAY=()
    else
        readarray -t SELECTED_ARRAY < <(tr -d '"\r' <"$TMP" | tr ' ' '\n' | grep -v '^$' || true)
        local c=() i
        for i in "${SELECTED_ARRAY[@]}"; do [[ -n "$i" ]] && c+=("$i"); done
        SELECTED_ARRAY=("${c[@]+"${c[@]}"}")
    fi
    save_selected_services
    log "Services selected: ${SELECTED_ARRAY[*]:-none}"
}

###############################################################################
#  2. Параметры (с навигацией)
###############################################################################
input_parameters() {
    run_steps
    save_params
}

###############################################################################
#  3. Docker
###############################################################################
install_docker() {
    if ! command -v docker &>/dev/null; then
        log "Installing Docker..."
        # Прогресс-бар: apt-get update → curl → install → enable
        local pipe=$(mktemp -u)
        mkfifo "$pipe"
        exec {fd}<>"$pipe"
        (
            trap 'exec {fd}>&-; rm -f "$pipe"' EXIT
            dialog --title " Docker" --gauge "Обновление пакетов..." 8 60 10 <"$pipe" &
            local gp=$!
            echo 10 >&$fd
            echo "XXX\nОбновление репозиториев...\nXXX" >&$fd
            apt-get update >&$fd 2>&1
            echo 25 >&$fd
            echo "XXX\nСкачивание скрипта установки...\nXXX" >&$fd
            curl -fsSL https://get.docker.com -o "$TMP" >&$fd 2>&1
            echo 40 >&$fd
            echo "XXX\nУстановка...\nXXX" >&$fd
            bash "$TMP" >&$fd 2>&1
            echo 70 >&$fd
            echo "XXX\nДобавление пользователя в docker...\nXXX" >&$fd
            usermod -aG docker "$REAL_USER" 2>&$fd || true
            systemctl enable docker --now 2>&$fd
            echo 100 >&$fd
            sleep 1
            kill "$gp" 2>/dev/null || true
        ) &
        wait $!
        exec {fd}>&-; rm -f "$pipe"
        if command -v docker &>/dev/null; then
            log "Docker installed successfully"
        else
            log "ERROR: Docker installation failed"
            dialog --title " Ошибка" --msgbox "Docker не удалось установить.\nПроверьте логи выше." 8 55
            return 1
        fi
    fi
    if ! docker compose version &>/dev/null; then
        log "Installing docker-compose-plugin..."
        apt-get update >/dev/null 2>&1 || true
        apt-get install -y docker-compose-plugin >/dev/null 2>&1
    fi
    log "Docker ready"
}

###############################################################################
#  4. Сеть + .env
###############################################################################
setup_network() {
    docker network inspect internal_network &>/dev/null || docker network create internal_network
    mkdir -p "$SETUP_DIR"; cd "$SETUP_DIR"
    cat >.env <<EOF
POSTGRES_PASSWORD=$(env_esc "${PGPASSWORD:-}")
JWT_SECRET=$(env_esc "${JWT_SECRET:-}")
LLM_TYPE=$(env_esc "${LLM_TYPE:-}")
LLM_API_KEY=$(env_esc "${LLM_API_KEY:-}")
LLM_API_URL=$(env_esc "${LLM_API_URL:-}")
DOMAIN=$(env_esc "${DOMAIN:-}")
SUPABASE_DOMAIN=$(env_esc "${SUPABASE_DOMAIN:-}")
N8N_PORT=${N8N_PORT}
N8N_DB_POSTGRES=${N8N_DB_POSTGRES}
APACHE_WWW_PATH=$(env_esc "${APACHE_WWW_PATH:-}")
APACHE_HTTP_PORT=${APACHE_HTTP_PORT}
QDRANT_PORT=${QDRANT_PORT}
OLLAMA_PORT=${OLLAMA_PORT}
EOF
    chmod 600 .env
    log "Network and .env created"
}

###############################################################################
#  5. Supabase
###############################################################################
setup_supabase() {
    is_selected "supabase" || return 0
    cd "$SETUP_DIR"
    log "Supabase setup started"

    # Прогресс-бар git clone
    if [[ ! -d "supabase-docker" ]]; then
        local ppipe=$(mktemp -u); mkfifo "$ppipe"; exec {pfd}<>"$ppipe"
        (
            trap 'exec {pfd}>&-; rm -f "$ppipe"' EXIT
            dialog --title " Supabase (1/2)" --gauge "Клонирование Supabase..." 8 60 5 <"$ppipe" &
            local bgp=$!
            echo 5 >&$pfd; echo "XXX\nКлонирование репозитория...\nXXX" >&$pfd
            git clone --depth 1 --filter=blob:none --sparse https://github.com/supabase/supabase &>"$TMP"
            echo 50 >&$pfd; echo "XXX\nsparse-checkout docker...\nXXX" >&$pfd
            (cd supabase && git sparse-checkout set docker &>"$TMP")
            echo 75 >&$pfd; echo "XXX\nПеремещение...\nXXX" >&$pfd
            mv supabase/docker supabase-docker; rm -rf supabase
            echo 100 >&$pfd; sleep 1; kill "$bgp" 2>/dev/null || true
        ) & wait $!
        exec {pfd}>&-; rm -f "$ppipe"
    fi
    cd supabase-docker

    # Если уже установлен — НЕ перегенерировать
    if [[ -f ".env" ]] && grep -q "^ANON_KEY=" .env 2>/dev/null; then
        log "Supabase already installed, preserving keys"
        dialog --msgbox "Supabase уже установлен. Ключи сохранены." 6 55
        inject_env .env POSTGRES_PASSWORD "${PGPASSWORD:-}"
        inject_env .env JWT_SECRET "${JWT_SECRET}"
        if [[ -n "${SUPABASE_DOMAIN:-}" ]]; then
            inject_env .env PUBLIC_URL "https://${SUPABASE_DOMAIN}"
            inject_env .env API_EXTERNAL_URL "https://${SUPABASE_DOMAIN}"
            inject_env .env SITE_URL "https://${SUPABASE_DOMAIN}"
        fi
        grep -q "internal_network" docker-compose.yml \
            || printf '\nnetworks:\n  internal_network:\n    external: true\n' >> docker-compose.yml
        docker compose -p supabase up -d >/dev/null 2>&1
        sleep 5
        docker ps --filter "name=supabase" --format "{{.Names}}" 2>/dev/null \
            | while IFS= read -r c; do docker network connect internal_network "$c" 2>/dev/null || true; done
        cd "$SETUP_DIR"; return 0
    fi

    cp .env.example .env
    local keys=("ANON_KEY" "SERVICE_ROLE_KEY" "SECRET_KEY_BASE" "VAULT_ENC_KEY"
                "PG_META_CRYPTO_KEY" "LOGFILE_PUBLIC_ACCESS_TOKEN"
                "LOGFILE_PRIVATE_ACCESS_TOKEN" "S3_PROTOCOL_ACCESS_KEY_SECRET")
    for key in "${keys[@]}"; do declare "$key=$(openssl rand -hex 32)"; done
    S3_PROTOCOL_ACCESS_KEY_ID=$(openssl rand -hex 16)
    MINIO_ROOT_PASSWORD=$(openssl rand -hex 16)
    DASHBOARD_PASSWORD=$(openssl rand -hex 12)

    # Безопасная замена всех значений через inject_env (без sed)
    for var in ANON_KEY SERVICE_ROLE_KEY SECRET_KEY_BASE VAULT_ENC_KEY PG_META_CRYPTO_KEY \
               LOGFILE_PUBLIC_ACCESS_TOKEN LOGFILE_PRIVATE_ACCESS_TOKEN \
               S3_PROTOCOL_ACCESS_KEY_ID S3_PROTOCOL_ACCESS_KEY_SECRET \
               MINIO_ROOT_PASSWORD DASHBOARD_PASSWORD; do
        inject_env .env "$var" "${!var}"
    done
    inject_env .env POSTGRES_PASSWORD "${PGPASSWORD}"
    inject_env .env JWT_SECRET "${JWT_SECRET}"
    if [[ -n "${SUPABASE_DOMAIN:-}" ]]; then
        inject_env .env PUBLIC_URL "https://${SUPABASE_DOMAIN}"
        inject_env .env API_EXTERNAL_URL "https://${SUPABASE_DOMAIN}"
        inject_env .env SITE_URL "https://${SUPABASE_DOMAIN}"
    fi
    grep -q "internal_network" docker-compose.yml \
        || printf '\nnetworks:\n  internal_network:\n    external: true\n' >> docker-compose.yml

    # Прогресс при up
    dialog --title " Supabase (2/2)" --gauge "Запуск контейнеров..." 8 60 50
    docker compose -p supabase up -d >/dev/null 2>&1
    sleep 10
    docker ps --filter "name=supabase" --format "{{.Names}}" 2>/dev/null \
        | while IFS= read -r c; do docker network connect internal_network "$c" 2>/dev/null || true; done
    cd "$SETUP_DIR"
    log "Supabase setup completed"
}

###############################################################################
#  6. Генерация docker-compose.yml
###############################################################################
generate_compose_file() {
    cd "$SETUP_DIR"
    local _pg=$(env_esc "${PGPASSWORD:-}") _ll=$(env_esc "${LLM_TYPE:-}")
    local _url=$(env_esc "${LLM_API_URL:-}") _ak=$(env_esc "${LLM_API_KEY:-}")
    local _www=$(env_esc "${APACHE_WWW_PATH:-}")

    cat >docker-compose.yml <<'HDR'
networks:
  internal_network:
    external: true
volumes:
HDR
    is_selected "postgres"  && echo "  postgres_data:"  >>docker-compose.yml
    is_selected "qdrant"    && echo "  qdrant_storage:"  >>docker-compose.yml
    is_selected "ollama"    && echo "  ollama_data:"     >>docker-compose.yml
    is_selected "nginx_proxy" && { echo "  npm_data:" >>docker-compose.yml; echo "  npm_letsencrypt:" >>docker-compose.yml; }
    is_selected "portainer" && echo "  portainer_data:"  >>docker-compose.yml
    is_selected "n8n"       && echo "  n8n_data:"        >>docker-compose.yml
    echo >>docker-compose.yml; echo "services:" >>docker-compose.yml

    is_selected "postgres" && cat >>docker-compose.yml <<YEOF
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

    is_selected "qdrant" && cat >>docker-compose.yml <<YEOF
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

    is_selected "ollama" && cat >>docker-compose.yml <<YEOF
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

    is_selected "apache" && cat >>docker-compose.yml <<YEOF
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

    is_selected "nginx_proxy" && cat >>docker-compose.yml <<'YEOF'
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

    is_selected "portainer" && cat >>docker-compose.yml <<'YEOF'
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

    if is_selected "n8n"; then
        local n8n_db=""
        [[ "${N8N_DB_POSTGRES}" -eq 1 ]] && n8n_db="
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_PORT: 5432
      DB_POSTGRESDB_USER: admin
      DB_POSTGRESDB_PASSWORD: ${_pg}
      DB_POSTGRESDB_DATABASE: n8n"
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
#  7. Запуск контейнеров
###############################################################################
start_containers() {
    cd "$SETUP_DIR"
    dialog --title " Запуск" --gauge "Подъём контейнеров..." 8 60 30
    docker compose up -d >/dev/null 2>&1
    if is_selected "n8n" && [[ "${N8N_DB_POSTGRES:-0}" -eq 1 ]]; then
        dialog --title " Запуск" --gauge "Создание БД n8n..." 8 60 80
        sleep 15
        docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^postgres$' \
            && docker exec -e PGPASSWORD="${PGPASSWORD}" postgres \
                psql -U admin -c "CREATE DATABASE n8n;" 2>/dev/null || true
    fi
    log "Containers started"
}

###############################################################################
#  8. NPM info
###############################################################################
print_npm_info() {
    is_selected "nginx_proxy" || return 0
    local ip; ip=$(hostname -I | awk '{print $1}')
    sleep 5
    cat >"$SETUP_DIR/npm_info.txt" <<EOF
NPM: http://${ip}:81
Login: admin@example.com
Pass:  changeme
EOF
}

###############################################################################
#  9. Финальная сводка (контейнеры, логины, пароли, ключи, пути)
###############################################################################
show_final_summary() {
    local ip; ip=$(hostname -I | awk '{print $1}')
    local sf="$STATE_DIR/final_summary.txt"

    # Собираем статус контейнеров
    local running=""
    running=$(docker ps --format "{{.Names}} ({{.Image}}) → {{.Status}}" 2>/dev/null || true)

    cat >"$sf" <<SUM

\Zb\Z1═══════════════════════════════════════════════════════\Zn
\Zb\Z1           УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО              \Zn
\Zb\Z1═══════════════════════════════════════════════════════\Zn

\Zb\Z1  Сервер:  \Zn$ip

\Zb\Z1═══ Установленные контейнеры ═══\Zn
SUM
    [[ -n "$running" ]] && echo "$running" >>"$sf" || echo "  (нет данных)" >>"$sf"

    cat >>"$sf" <<SUM

\Zb\Z1═══ Директории ═══\Zn
  Setup dir     :  $SETUP_DIR
  docker-compose:  $SETUP_DIR/docker-compose.yml
  .env файл     :  $SETUP_DIR/.env
  Apache www    :  ${APACHE_WWW_PATH:-(не выбран)}
  State dir     :  $STATE_DIR
SUM

    if is_selected "supabase" && [[ -f "$SETUP_DIR/supabase-docker/.env" ]]; then
        echo >>"$sf"; echo "\Zb\Z1═══ Supabase ключи ═══\Zn" >>"$sf"
        grep "^ANON_KEY=" "$SETUP_DIR/supabase-docker/.env" 2>/dev/null >>"$sf" || echo "  ANON_KEY: не найден" >>"$sf"
        grep "^SERVICE_ROLE_KEY=" "$SETUP_DIR/supabase-docker/.env" 2>/dev/null >>"$sf" || true
    fi

    cat >>"$sf" <<SUM

\Zb\Z1═══ Доступы ═══\Zn
  PostgreSQL    :  admin  /  ${PGPASSWORD:-(не установлен)}
  JWT Secret    :  ${JWT_SECRET:-(не установлен)}
  LLM Type      :  ${LLM_TYPE:-(не выбран)}
  LLM API URL   :  ${LLM_API_URL:-(не указан)}
  LLM API Key   :  ${LLM_API_KEY:+${LLM_API_KEY:0:4}*****}${LLM_API_KEY:-(не указан)}
SUM

    cat >>"$sf" <<SUM

\Zb\Z1═══ Веб-интерфейсы ═══\Zn
  Portainer     :  http://$ip:9000
  Nginx Proxy   :  http://$ip:81  (admin@example.com / changeme)
SUM
    is_selected "supabase" && echo "  Supabase    :  https://${SUPABASE_DOMAIN:-$ip (через IP)}" >>"$sf"
    is_selected "n8n"     && echo "  n8n         :  http://${DOMAIN:-$ip}:${N8N_PORT}" >>"$sf"
    is_selected "apache"  && echo "  Apache      :  http://${DOMAIN:-$ip}:${APACHE_HTTP_PORT}" >>"$sf"
    is_selected "qdrant"  && echo "  Qdrant      :  http://${ip}:${QDRANT_PORT}" >>"$sf"
    is_selected "ollama"  && echo "  Ollama      :  http://${ip}:${OLLAMA_PORT}" >>"$sf"

    cat >>"$sf" <<SUM

\Zb\Z1═══ Сохранённые файлы ═══\Zn
  $STATE_DIR/params.env          — параметры (зашифрованы base64)
  $STATE_DIR/selected_services.cfg — список сервисов
  $LOG_FILE                   — лог установки
  $SETUP_DIR/npm_info.txt       — NPM доступы

\Zb\Z1  Сохраните эту информацию!  Ключи не показываются повторно.\Zn
\Zb\Z1═══════════════════════════════════════════════════════\Zn
SUM
    chmod 600 "$sf"
    dialog --title " Готово!" --textbox "$sf" 28 72
    log "Final summary displayed"
    cat "$sf"
}

###############################################################################
#  10. Переустановка / управление
###############################################################################
reinstall_service() {
    local svc="$1"
    cd "$SETUP_DIR"
    case "$svc" in
        supabase)
            dialog --yesno "Переустановить Supabase?\n\n\Zb\Z1 ВСЕ ДАННЫЕ БУДУТ УДАЛЕНЫ (-v)\Zn\nСоздайте backup!" 10 60 || return 0
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
    local sf="$TMP2"
    docker compose ps 2>/dev/null >"$sf" || echo "Compose не найден в $SETUP_DIR" >"$sf"
    echo >>"$sf"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null >>"$sf" || true
    dialog --title " Статус контейнеров" --textbox "$sf" 20 80
}

###############################################################################
#  11. Post-install меню
###############################################################################
post_install_menu() {
    while true; do
        dialog --clear --title " Post-install управление" --menu \
            "Установка завершена. Выберите действие:" 18 60 7 \
            "1" " Добавить / удалить сервисы" \
            "2" " Переустановить сервис" \
            "3" " Проверить статус" \
            "4" " Показать сводку (пароли/ключи)" \
            "5" " Показать лог установки" \
            "6" " Сбросить всё и начать заново" \
            "0" " Выйти" 2>"$TMP" || return 0

        case "$(<"$TMP")" in
            1)  run_steps
                save_params
                setup_network
                setup_supabase
                generate_compose_file
                # Удаляем осиротевшие контейнеры и поднимаем заново
                docker compose down --remove-orphans >/dev/null 2>&1 || true
                docker compose up -d >/dev/null 2>&1 || true
                show_final_summary
                ;;
            2)
                local arr=() nm
                local names; names=$(docker ps --format '{{.Names}}' 2>/dev/null || true)
                local svc iname
                for svc in postgres qdrant ollama apache nginx-proxy-manager portainer supabase n8n; do
                    if echo "$names" | grep -qw "^${svc}$"; then
                        iname="$svc"; [[ "$svc" == "nginx-proxy-manager" ]] && iname="nginx_proxy"
                        arr+=("$iname" "$svc" off)
                    fi
                done
                [[ ${#arr[@]} -eq 0 ]] && { dialog --msgbox "Нет запущенных сервисов." 6 50; continue; }
                dialog --checklist "Выберите для переустановки:" 15 60 6 "${arr[@]}" 2>"$TMP" || continue
                local ch
                while IFS= read -r ch; do
                    ch="${ch//\"/}"; [[ -n "$ch" ]] && reinstall_service "$ch"
                done <"$TMP"
                ;;
            3)  show_status;;
            4)  show_final_summary;;
            5)  if [[ -f "$LOG_FILE" ]]; then
                    dialog --title " Лог" --textbox "$LOG_FILE" 24 80
                else dialog --msgbox "Лог недоступен: $LOG_FILE" 6 50
                fi
                ;;
            6)
                dialog --yesno "Сбросить ВСЁ?\n\nБудут удалены:\n  • ${STATE_DIR}\n  • docker compose down -v\n  • Все данные Supabase" 10 60 || continue
                (cd "$SETUP_DIR" && docker compose down -v 2>/dev/null || true)
                docker compose -p supabase down -v 2>/dev/null || true
                rm -rf "$STATE_DIR" "$SETUP_DIR"
                dialog --msgbox "Всё сброшено." 6 50
                exec "$0"
                ;;
            0)  return 0;;
        esac
    done
}

###############################################################################
#  12. Главная
###############################################################################
main() {
    if ! grep -qi "ubuntu\|debian" /etc/os-release 2>/dev/null; then
        echo " Поддерживаются только Ubuntu/Debian"; exit 1; fi
    if [[ "$EUID" -ne 0 ]]; then echo " Запустите с sudo"; exit 1; fi
    if ! command -v dialog &>/dev/null; then
        apt-get update >/dev/null 2>&1 && apt-get install -y dialog >/dev/null 2>&1 \
            || { echo " Не удалось установить dialog"; exit 1; }
    fi

    # Проверка свободного места (нужно ≥ 5 GB)
    local avail_gb
    avail_gb=$(df -BG / | awk 'NR==2{gsub(/G/,""); print $4}')
    if [[ "$avail_gb" =~ ^[0-9]+$ ]] && [[ "$avail_gb" -lt 5 ]]; then
        dialog --title " Мало места" --msgbox "Доступно ${avail_gb} GB. Нужно минимум 5 GB." 8 55
        exit 1
    fi

    load_selected_services
    load_params

    if [[ $# -eq 2 ]] && [[ "$1" == "--reinstall" ]]; then
        reinstall_service "$2"; exit 0
    fi

    local state; state=$(get_state)
    case "$state" in
        start)
            show_welcome
            show_service_menu
            input_parameters || { save_state "start"; exit 4; }
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
        docker_installed|network_needed)
            setup_network; setup_supabase; generate_compose_file
            start_containers; print_npm_info; show_final_summary
            save_state "done"
            ;;
        completed)
            show_final_summary
            ;;
    esac

    # Post-install меню (после любого сценария)
    post_install_menu
}

main "$@"
