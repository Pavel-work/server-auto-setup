#!/bin/bash
set -uo pipefail

###############################################################################
#  Джентльменский набор - установщик сервисов v4.16
###############################################################################
#  Изменения v4.16 (fixes от анализа v4.15):
#    • generate_compose_file: YAML пароль через printf + экранирование '
#    • generate_compose_file: WEBHOOK_URL в одинарных кавычках YAML
#    • create_n8n_database: docker exec -T везде
#    • show_final_summary: защита пустого массива при -u
#    • inject_env: value не экранируется внутри — документировано,
#      все вызовы приведены к единому виду (plain для числел, env_esc для строк)
#    • s_supabase_ports: "Назад" при вводе порта → _nav_action=back + return 1
#    • setup_supabase: вложенные функции вынесены на верхний уровень
#    • setup_network: не обнуляет .env — использует inject_env
#    • verify_docker: убран лишний docker rm -f hello-world
#    • env_esc: экранирование backtick
#    • show_service_menu: grep -v заменён на чистый bash-фильтр
#    • supabase_compose_*: явный pushd/popd не нужен — вызываются из setup_supabase
#      после cd supabase-docker; добавлен guard PWD
#    • post_install_menu п.1: pushd/popd вокруг setup_supabase
#    • load_params: порядок не важен для ассоциативного массива — добавлен
#      комментарий; APACHE_WWW_PATH инициализируется после SETUP_DIR (уже так)
#    • save_params/load_params: цепочка b64 сохранена, добавлен комментарий
#    • b64enc: -w0 только GNU — добавлен fallback без -w0
#    • cleanup: добавлен глобальный массив _MKTEMPS для отслеживания mktemp
###############################################################################

# ─── Глобальные пути ────────────────────────────────────────────────────────
STATE_DIR="/root/.server-setup-state"
STATE_FILE="$STATE_DIR/state.cfg"
SELECTED_FILE="$STATE_DIR/selected_services.cfg"
PARAMS_FILE="$STATE_DIR/params.env"
SETUP_DIR="/root/server-setup"
LOG_FILE="/var/log/install.log"
REAL_USER="${SUDO_USER:-${USER:-root}}"

# Глобальные временные файлы (только два постоянных)
TMP=$(mktemp)
TMP2=$(mktemp)

# Массив для отслеживания всех mktemp — cleanup удалит всё
declare -a _MKTEMPS=("$TMP" "$TMP2")

# Обёртка над mktemp: регистрирует файл для cleanup
_mktemp() {
    local f
    f=$(mktemp "$@")
    _MKTEMPS+=("$f")
    printf '%s' "$f"
}

cleanup() {
    local f
    for f in "${_MKTEMPS[@]+"${_MKTEMPS[@]}"}"; do
        rm -f "$f" 2>/dev/null || true
    done
}
trap cleanup EXIT INT TERM

declare -a SELECTED_ARRAY=()

# ─── Логирование ────────────────────────────────────────────────────────────
log() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    printf '%s  %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE" 2>/dev/null || true
}

# ─── Утилиты ────────────────────────────────────────────────────────────────

# env_esc: для .env файла (bash-синтаксис, значение в двойных кавычках).
# Экранирует: \ " $ ` и перенос строки.
# Возвращает строку вида: "значение"
env_esc() {
    local v="${1:-}"
    v="${v//\\/\\\\}"       # \ → \\
    v="${v//\"/\\\"}"       # " → \"
    v="${v//\$/\\\$}"       # $ → \$
    v="${v//\`/\\\`}"       # ` → \`   ← исправлено v4.16
    v="${v//$'\n'/\\n}"     # LF → \n
    printf '"%s"' "$v"
}

# yaml_sq_esc: экранирование для YAML single-quoted scalar.
# В YAML одинарные кавычки экранируются удвоением: ' → ''
# Возвращает строку БЕЗ внешних кавычек — их добавляет вызывающий код.
yaml_sq_esc() {
    local v="${1:-}"
    v="${v//\'/\'\'}"       # ' → ''
    printf '%s' "$v"
}

# compose_esc: для YAML double-quoted scalar (пути и т.п.)
compose_esc() {
    local v="${1:-}"
    v="${v//\"/\\\"}"
    printf '%s' "$v"
}

# inject_env: заменяет KEY=... в файле или добавляет в конец.
# ВАЖНО: value должен быть передан уже готовым к записи:
#   - для строк:  "$(env_esc "$VAR")"
#   - для чисел:  "$NUMBER"  (без кавычек env_esc)
# Внутри функции value записывается as-is (без дополнительного экранирования).
inject_env() {
    local file="$1" key="$2" value="$3"
    local tmp found=0
    tmp=$(_mktemp)
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "${key}="* ]]; then
            printf '%s=%s\n' "$key" "$value"
            found=1
        else
            printf '%s\n' "$line"
        fi
    done < "$file" > "$tmp"
    [[ $found -eq 0 ]] && printf '%s=%s\n' "$key" "$value" >> "$tmp"
    mv "$tmp" "$file"
    # mv "съел" файл из _MKTEMPS — это нормально, rm -f несуществующего = no-op
}

b64enc() {
    if [[ -z "${1:-}" ]]; then
        printf ''
        return 0
    fi
    # GNU base64 поддерживает -w0; BSD/macOS — нет; пробуем оба варианта
    local result
    if result=$(printf '%s' "$1" | base64 -w0 2>/dev/null) && [[ -n "$result" ]]; then
        printf '%s' "$result"
    elif result=$(printf '%s' "$1" | base64 2>/dev/null | tr -d '\n') && [[ -n "$result" ]]; then
        printf '%s' "$result"
    else
        log "WARNING: b64enc failed for value"
        printf ''
    fi
}

b64dec() {
    if [[ -z "${1:-}" ]]; then
        printf ''
        return 0
    fi
    local result
    if result=$(printf '%s' "$1" | base64 -d 2>/dev/null); then
        printf '%s' "$result"
    else
        log "WARNING: b64dec failed for value"
        printf ''
    fi
}

load_param_b64() {
    local file="$1" key="$2"
    local line val
    line=$(grep "^${key}=" "$file" 2>/dev/null | head -n1) || line=""
    [[ -z "$line" ]] && return 1
    val="${line#*=}"
    # Снимаем внешние кавычки (двойные или одинарные)
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
        ss -tuln 2>/dev/null | grep -qE ":${port}[^0-9]" && in_use=1
    elif command -v netstat &>/dev/null; then
        netstat -tuln 2>/dev/null | grep -qE ":${port}[^0-9]" && in_use=1
    else
        bash -c "echo >/dev/tcp/localhost/${port}" 2>/dev/null && in_use=1
    fi
    if [[ $in_use -eq 1 ]]; then
        if dialog --title "Порт занят" \
            --yes-label "Другой порт" --no-label "Пропустить" \
            --yesno "Порт $port уже используется.\nПопробовать другой?" 8 55; then
            return 1
        fi
    fi
    return 0
}

# ─── is_selected ────────────────────────────────────────────────────────────
is_selected() {
    local s
    for s in "${SELECTED_ARRAY[@]+"${SELECTED_ARRAY[@]}"}"; do
        [[ "$s" == "$1" ]] && return 0
    done
    return 1
}

# ─── State helpers ──────────────────────────────────────────────────────────
save_state() { mkdir -p "$STATE_DIR"; printf '%s' "$1" >"$STATE_FILE"; }
get_state()  { [[ -f "$STATE_FILE" ]] && cat "$STATE_FILE" || echo "start"; }

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
    for i in "${SELECTED_ARRAY[@]+"${SELECTED_ARRAY[@]}"}"; do
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
    # Значения кодируются в base64 чтобы избежать проблем с спецсимволами.
    # load_params читает через load_param_b64 (снимает кавычки) + b64dec.
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
PORTAINER_PORT_B64="$(b64enc "${PORTAINER_PORT:-}")"
OLLAMA_PORT_B64="$(b64enc "${OLLAMA_PORT:-}")"
SUPABASE_PORT_STUDIO_B64="$(b64enc "${SUPABASE_PORT_STUDIO:-3000}")"
SUPABASE_PORT_PG_B64="$(b64enc "${SUPABASE_PORT_PG:-54322}")"
SUPABASE_PORT_API_B64="$(b64enc "${SUPABASE_PORT_API:-8000}")"
SUPABASE_PORT_MAIL_B64="$(b64enc "${SUPABASE_PORT_MAIL:-8085}")"
SUPABASE_PORT_AUTH_B64="$(b64enc "${SUPABASE_PORT_AUTH:-5555}")"
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
    [PORTAINER_PORT]="PORTAINER_PORT_B64"
    [OLLAMA_PORT]="OLLAMA_PORT_B64"
    [SUPABASE_PORT_STUDIO]="SUPABASE_PORT_STUDIO_B64"
    [SUPABASE_PORT_PG]="SUPABASE_PORT_PG_B64"
    [SUPABASE_PORT_API]="SUPABASE_PORT_API_B64"
    [SUPABASE_PORT_MAIL]="SUPABASE_PORT_MAIL_B64"
    [SUPABASE_PORT_AUTH]="SUPABASE_PORT_AUTH_B64"
)

load_params() {
    # Значения по умолчанию — устанавливаются ДО чтения файла
    PGPASSWORD=""
    JWT_SECRET=""
    LLM_TYPE="ollama"
    LLM_API_KEY=""
    LLM_API_URL="http://ollama:11434"
    DOMAIN=""
    SUPABASE_DOMAIN=""
    N8N_PORT=5678
    N8N_DB_POSTGRES=0
    # SETUP_DIR определён выше глобально — безопасно использовать здесь
    APACHE_WWW_PATH="$SETUP_DIR/www"
    APACHE_HTTP_PORT=8080
    QDRANT_PORT=6333
    PORTAINER_PORT=9000
    OLLAMA_PORT=11434
    SUPABASE_PORT_STUDIO=3000
    SUPABASE_PORT_PG=54322
    SUPABASE_PORT_API=8000
    SUPABASE_PORT_MAIL=8085
    SUPABASE_PORT_AUTH=5555

    if [[ -f "$PARAMS_FILE" ]]; then
        # Порядок итерации по ассоциативному массиву не гарантирован в bash,
        # но здесь это не важно — каждый ключ независим.
        local k b t
        for k in "${!_PM[@]}"; do
            if b=$(load_param_b64 "$PARAMS_FILE" "${_PM[$k]}"); then
                t=$(b64dec "$b")
                printf -v "$k" "%s" "$t"
            fi
        done
    fi

    # Санитизация числовых значений
    [[ "$N8N_PORT"             =~ ^[0-9]+$ ]] || N8N_PORT=5678
    [[ "$APACHE_HTTP_PORT"     =~ ^[0-9]+$ ]] || APACHE_HTTP_PORT=8080
    [[ "$QDRANT_PORT"          =~ ^[0-9]+$ ]] || QDRANT_PORT=6333
    [[ "$PORTAINER_PORT"       =~ ^[0-9]+$ ]] || PORTAINER_PORT=9000
    [[ "$OLLAMA_PORT"          =~ ^[0-9]+$ ]] || OLLAMA_PORT=11434
    [[ "$N8N_DB_POSTGRES"      =~ ^[01]$   ]] || N8N_DB_POSTGRES=0
    [[ "$SUPABASE_PORT_STUDIO" =~ ^[0-9]+$ ]] || SUPABASE_PORT_STUDIO=3000
    [[ "$SUPABASE_PORT_PG"     =~ ^[0-9]+$ ]] || SUPABASE_PORT_PG=54322
    [[ "$SUPABASE_PORT_API"    =~ ^[0-9]+$ ]] || SUPABASE_PORT_API=8000
    [[ "$SUPABASE_PORT_MAIL"   =~ ^[0-9]+$ ]] || SUPABASE_PORT_MAIL=8085
    [[ "$SUPABASE_PORT_AUTH"   =~ ^[0-9]+$ ]] || SUPABASE_PORT_AUTH=5555
}

###############################################################################
#  ДИНАМИЧЕСКАЯ НАВИГАЦИЯ
###############################################################################
_STEP=0
_STEP_MAX=0
_STEP_LABELS=()
_STEP_FUNC=()
_nav_action="next"

step_reg() { _STEP_LABELS+=("$1"); _STEP_FUNC+=("$2"); }

input_port() {
    local label="$1" varname="$2" default_port="$3"
    local default_val="${!varname:-$default_port}"
    while true; do
        dialog --ok-label "Далее " --cancel-label "Назад " \
            --title "Порт $label" \
            --inputbox "Укажите порт для $label:" 8 60 "$default_val" 2>"$TMP" \
            || { _nav_action="back"; return 1; }
        local val
        val=$(<"$TMP")
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

build_steps() {
    _STEP_LABELS=()
    _STEP_FUNC=()
    _STEP=0

    is_selected "postgres"    && step_reg "PostgreSQL пароль"        "s_pg"
    is_selected "ollama"      && step_reg "LLM Provider"             "s_llm"

    if is_selected "apache" || is_selected "n8n" || \
       is_selected "nginx_proxy" || is_selected "supabase"; then
        step_reg "Домен" "s_domain"
    fi

    is_selected "n8n"      && step_reg "n8n порт"                    "s_n8n_port"
    is_selected "n8n" && is_selected "postgres" && \
        step_reg "n8n: Postgres или SQLite?"                         "s_n8n_db"
    is_selected "supabase" && step_reg "Supabase поддомен"           "s_supabase_domain"
    is_selected "supabase" && step_reg "JWT Secret (Supabase)"       "s_jwt"
    is_selected "supabase" && step_reg "Supabase порты"              "s_supabase_ports"
    is_selected "apache"   && step_reg "Apache путь для сайтов"      "s_ap_path"
    is_selected "apache"   && step_reg "Apache порт"                 "s_ap_port"
    is_selected "qdrant"   && step_reg "Qdrant порт"                 "s_qdrant_port"
    is_selected "portainer"&& step_reg "Portainer порт"              "s_portainer_port"
    is_selected "ollama"   && step_reg "Ollama порт"                 "s_ollama_port"

    step_reg "Подтверждение" "s_confirm"
    _STEP_MAX=${#_STEP_LABELS[@]}
}

###############################################################################
#  ОТДЕЛЬНЫЕ ШАГИ
###############################################################################

s_pg() {
    dialog --ok-label "Далее " --cancel-label "Назад " \
        --title "[$((_STEP+1))/${_STEP_MAX}] PostgreSQL" \
        --inputbox "Пароль пользователя admin (пусто = сгенерировать)\n\nShift+Insert для вставки" \
        10 65 "${PGPASSWORD:-}" 2>"$TMP" \
        || { _nav_action="back"; return 1; }
    PGPASSWORD=$(<"$TMP")
    [[ -z "$PGPASSWORD" ]] && \
        PGPASSWORD=$(openssl rand -base64 24 | tr -d '+=/' | cut -c1-20)
    dialog --title "Готово" --ok-label "Далее " \
        --msgbox "Пароль PostgreSQL:\n\n${PGPASSWORD}" 10 60
    log "PGPASSWORD set"
}

s_llm() {
    LLM_TYPE=$(dialog --ok-label "Далее " --cancel-label "Назад " \
        --title "[$((_STEP+1))/${_STEP_MAX}] LLM Provider" \
        --radiolist "Выберите LLM провайдер:" 15 60 5 \
        "ollama"    "Ollama (локально)"    on \
        "openai"    "OpenAI (GPT)"         off \
        "anthropic" "Anthropic (Claude)"   off \
        "deepseek"  "DeepSeek"             off \
        "custom"    "Custom URL"           off \
        3>&1 1>&2 2>&3) || { _nav_action="back"; return 1; }

    case "$LLM_TYPE" in
        openai)    LLM_API_URL="https://api.openai.com/v1" ;;
        anthropic) LLM_API_URL="https://api.anthropic.com/v1" ;;
        ollama)    LLM_API_URL="http://ollama:11434"; LLM_API_KEY="" ;;
        deepseek)  LLM_API_URL="https://api.deepseek.com/v1" ;;
        custom)
            dialog --ok-label "Далее " --cancel-label "Назад " \
                --inputbox "Введите URL API:" 9 60 "${LLM_API_URL:-}" 2>"$TMP" \
                || { _nav_action="back"; return 1; }
            LLM_API_URL=$(<"$TMP")
            ;;
    esac

    if [[ "$LLM_TYPE" != "ollama" ]]; then
        dialog --ok-label "Далее " --cancel-label "Назад " \
            --inputbox "API ключ для ${LLM_TYPE} (пусто если нет):" \
            9 60 "${LLM_API_KEY:-}" 2>"$TMP" \
            || { _nav_action="back"; return 1; }
        LLM_API_KEY=$(<"$TMP")
    fi
    log "LLM: $LLM_TYPE -> $LLM_API_URL"
}

s_domain() {
    dialog --ok-label "Далее " --cancel-label "Назад " \
        --inputbox "Основной домен (пусто если нет):\n\nПример: example.com" \
        9 60 "${DOMAIN:-}" 2>"$TMP" \
        || { _nav_action="back"; return 1; }
    DOMAIN=$(<"$TMP")
    log "Domain: $DOMAIN"
}

s_n8n_port() { input_port "n8n" N8N_PORT 5678; }

s_n8n_db() {
    if dialog --yes-label "Postgres " --no-label "SQLite " \
        --title "[$((_STEP+1))/${_STEP_MAX}] n8n Database" \
        --yesno "Использовать PostgreSQL или SQLite для n8n?\n\nДа = PostgreSQL, Нет = SQLite" \
        9 60; then
        N8N_DB_POSTGRES=1
    else
        N8N_DB_POSTGRES=0
    fi
    _nav_action="next"
    log "n8n DB: $N8N_DB_POSTGRES"
}

s_supabase_domain() {
    dialog --ok-label "Далее " --cancel-label "Назад " \
        --inputbox "Поддомен Supabase (пусто если нет):\n\nПример: sup.example.com" \
        9 60 "${SUPABASE_DOMAIN:-}" 2>"$TMP" \
        || { _nav_action="back"; return 1; }
    SUPABASE_DOMAIN=$(<"$TMP")
    log "Supabase domain: $SUPABASE_DOMAIN"
}

s_jwt() {
    dialog --ok-label "Далее " --cancel-label "Назад " \
        --title "[$((_STEP+1))/${_STEP_MAX}] JWT Secret" \
        --inputbox "Секрет для Supabase JWT (пусто = сгенерировать)" \
        9 60 "${JWT_SECRET:-}" 2>"$TMP" \
        || { _nav_action="back"; return 1; }
    JWT_SECRET=$(<"$TMP")
    [[ -z "$JWT_SECRET" ]] && JWT_SECRET=$(openssl rand -hex 32)
    dialog --title "Готово" --ok-label "Далее " \
        --msgbox "JWT Secret:\n\n${JWT_SECRET}" 10 60
    log "JWT_SECRET set"
}

s_supabase_ports() {
    local _tmp_sf
    _tmp_sf=$(_mktemp)

    while true; do
        {
            printf 'Порты Supabase (по умолчанию в скобках):\n\n'
            printf '  Studio UI  (3000):  %s\n' "${SUPABASE_PORT_STUDIO:-3000}"
            printf '  Database   (54322): %s\n' "${SUPABASE_PORT_PG:-54322}"
            printf '  API/Kong   (8000):  %s\n' "${SUPABASE_PORT_API:-8000}"
            printf '  Mail       (8085):  %s\n' "${SUPABASE_PORT_MAIL:-8085}"
            printf '  Auth       (5555):  %s\n' "${SUPABASE_PORT_AUTH:-5555}"
            printf '\nДа  = оставить как есть\nНет = изменить порты\n'
        } > "$_tmp_sf"

        if dialog --title "[$((_STEP+1))/${_STEP_MAX}] Supabase порты" \
            --yes-label "Далее " --no-label "Изменить" \
            --yesno "$(cat "$_tmp_sf")" 20 55; then
            _nav_action="next"
            log "Supabase ports: Studio=$SUPABASE_PORT_STUDIO DB=$SUPABASE_PORT_PG \
API=$SUPABASE_PORT_API Mail=$SUPABASE_PORT_MAIL Auth=$SUPABASE_PORT_AUTH"
            return 0
        fi

        # Изменение каждого порта — отдельный диалог для каждого
        local _port_tmp
        _port_tmp=$(_mktemp)

        local _cancelled=0
        local port_var label default_val port_val

        for port_var in SUPABASE_PORT_STUDIO SUPABASE_PORT_PG SUPABASE_PORT_API \
                        SUPABASE_PORT_MAIL SUPABASE_PORT_AUTH; do
            case "$port_var" in
                SUPABASE_PORT_STUDIO) label="Studio UI";  default_val=3000  ;;
                SUPABASE_PORT_PG)     label="Database";   default_val=54322 ;;
                SUPABASE_PORT_API)    label="API/Kong";   default_val=8000  ;;
                SUPABASE_PORT_MAIL)   label="Mail";       default_val=8085  ;;
                SUPABASE_PORT_AUTH)   label="Auth";       default_val=5555  ;;
            esac

            dialog --ok-label "OK" --cancel-label "Назад " \
                --inputbox "Порт Supabase ${label} (по умолч. ${default_val}):" \
                8 55 "${!port_var:-$default_val}" 2>"$_port_tmp" \
                || { _cancelled=1; break; }

            port_val=$(<"$_port_tmp")

            if [[ "$port_val" =~ ^[0-9]+$ ]] && \
               [[ "$port_val" -ge 1024 ]]    && \
               [[ "$port_val" -le 65535 ]]; then
                printf -v "$port_var" "%s" "$port_val"
            else
                printf -v "$port_var" "%s" "$default_val"
            fi
        done

        if [[ $_cancelled -eq 1 ]]; then
            # Пользователь нажал "Назад" при вводе порта →
            # выходим из шага s_supabase_ports назад по навигации
            _nav_action="back"
            return 1
        fi
        # _cancelled=0: все порты введены → возвращаемся к диалогу показа
    done
}

s_ap_path() {
    dialog --ok-label "Далее " --cancel-label "Назад " \
        --inputbox "Путь для сайтов Apache:" 9 60 \
        "${APACHE_WWW_PATH:-$SETUP_DIR/www}" 2>"$TMP" \
        || { _nav_action="back"; return 1; }
    APACHE_WWW_PATH=$(<"$TMP")
    [[ -z "$APACHE_WWW_PATH" ]] && APACHE_WWW_PATH="$SETUP_DIR/www"
    APACHE_WWW_PATH=$(realpath -m "$APACHE_WWW_PATH")
    mkdir -p "$APACHE_WWW_PATH" "$APACHE_WWW_PATH/conf"
    [[ ! -f "$APACHE_WWW_PATH/index.html" ]] && \
        echo '<h1>It works!</h1>' >"$APACHE_WWW_PATH/index.html"
    log "Apache path: $APACHE_WWW_PATH"
}

s_ap_port()        { input_port "Apache"    APACHE_HTTP_PORT 8080;  }
s_qdrant_port()    { input_port "Qdrant"    QDRANT_PORT      6333;  }
s_portainer_port() { input_port "Portainer" PORTAINER_PORT   9000;  }
s_ollama_port()    { input_port "Ollama"    OLLAMA_PORT      11434; }

s_confirm() {
    local _tmp_sf
    _tmp_sf=$(_mktemp)

    {
        printf 'Выбранные сервисы:\n\n'
        local s
        for s in "${SELECTED_ARRAY[@]+"${SELECTED_ARRAY[@]}"}"; do
            printf '  - %s\n' "$s"
        done
        printf '\nПараметры:\n'

        if is_selected "postgres"; then
            printf '  PostgreSQL пароль: '
            if [[ -n "${PGPASSWORD:-}" ]]; then printf '**** (установлен)\n'
            else printf '(не установлен)\n'; fi
        fi

        if is_selected "supabase"; then
            printf '  JWT Secret: '
            if [[ -n "${JWT_SECRET:-}" ]]; then printf '**** (установлен)\n'
            else printf '(не установлен)\n'; fi
        fi

        is_selected "ollama" && \
            printf '  LLM: %s -> %s\n' "${LLM_TYPE:-none}" "${LLM_API_URL:-}"

        printf '  Домен: %s\n' "${DOMAIN:-(нет)}"

        if is_selected "supabase"; then
            printf '  Supabase поддомен: %s\n' "${SUPABASE_DOMAIN:-(нет)}"
            printf '  Supabase порты: Studio=%s DB=%s API=%s Mail=%s Auth=%s\n' \
                "${SUPABASE_PORT_STUDIO:-3000}" "${SUPABASE_PORT_PG:-54322}" \
                "${SUPABASE_PORT_API:-8000}"    "${SUPABASE_PORT_MAIL:-8085}" \
                "${SUPABASE_PORT_AUTH:-5555}"
        fi

        if is_selected "n8n"; then
            if [[ "${N8N_DB_POSTGRES:-0}" == "1" ]]; then
                printf '  n8n порт: %s (DB: Postgres)\n' "${N8N_PORT}"
            else
                printf '  n8n порт: %s (DB: SQLite)\n' "${N8N_PORT}"
            fi
        fi

        is_selected "apache" && \
            printf '  Apache: порт %s, путь %s\n' "${APACHE_HTTP_PORT}" "${APACHE_WWW_PATH}"
        is_selected "portainer" && \
            printf '  Portainer порт: %s\n' "${PORTAINER_PORT}"
        is_selected "qdrant" && \
            printf '  Qdrant порт: %s\n' "${QDRANT_PORT}"
        is_selected "ollama" && \
            printf '  Ollama порт: %s\n' "${OLLAMA_PORT}"

        printf '\nНазад  -- изменить параметры\nДалее  -- начать установку\n'
    } > "$_tmp_sf"

    if dialog --title "[$((_STEP+1))/${_STEP_MAX}] Подтверждение" \
        --yes-label "Далее " --no-label "Назад " \
        --yesno "$(cat "$_tmp_sf")" 26 68; then
        _nav_action="next"
    else
        _nav_action="back"
    fi
}

# ─── Главный цикл навигации ─────────────────────────────────────────────────
run_steps() {
    build_steps
    _STEP=0
    while true; do
        _nav_action="next"
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
    dialog --title "Добро пожаловать!" \
        --yes-label "Начать " --no-label "Выйти " \
        --yesno "
Джентльменский набор - установщик сервисов

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

Внимание: установка займёт от 2 до 30 минут.
" 34 85 || exit 0
    log "Welcome screen displayed"
}

###############################################################################
#  ВЫБОР СЕРВИСОВ
###############################################################################
show_service_menu() {
    # Сохраняем backup на случай отмены (Esc / Назад)
    local _backup=("${SELECTED_ARRAY[@]+"${SELECTED_ARRAY[@]}"}")

    local args=(
        "postgres"    "PostgreSQL"          off
        "qdrant"      "Qdrant"              off
        "ollama"      "Ollama"              off
        "apache"      "Apache"              off
        "nginx_proxy" "Nginx Proxy Manager" off
        "portainer"   "Portainer"           off
        "supabase"    "Supabase"            off
        "n8n"         "n8n"                 off
    )

    # Отмечаем ранее выбранные
    local i s
    for ((i=0; i<${#args[@]}; i+=3)); do
        for s in "${SELECTED_ARRAY[@]+"${SELECTED_ARRAY[@]}"}"; do
            [[ "${args[$i]}" == "$s" ]] && args[$((i+2))]="on"
        done
    done

    local _tmp_sel
    _tmp_sel=$(_mktemp)

    dialog --title "Выбор сервисов" \
        --cancel-label "Назад " \
        --checklist "Выберите нужное (Пробел). Esc -- на предыдущий шаг." \
        22 65 10 "${args[@]}" 2>"$_tmp_sel" \
        || {
            # Восстанавливаем выбор при Esc/Назад
            SELECTED_ARRAY=("${_backup[@]+"${_backup[@]}"}")
            _nav_action="back"
            return 1
        }

    if [[ ! -s "$_tmp_sel" ]]; then
        SELECTED_ARRAY=()
    else
        # dialog --checklist возвращает значения в одну строку через пробел,
        # в двойных кавычках. Разбираем чистым bash без grep.
        local raw item
        raw=$(tr -d '"\r' <"$_tmp_sel")
        SELECTED_ARRAY=()
        for item in $raw; do
            [[ -n "$item" ]] && SELECTED_ARRAY+=("$item")
        done
    fi

    save_selected_services
    log "Services selected: ${SELECTED_ARRAY[*]+"${SELECTED_ARRAY[*]}"}"
}

###############################################################################
#  ПАРАМЕТРЫ
###############################################################################
input_parameters() {
    run_steps
    save_params
}

###############################################################################
#  DOCKER
###############################################################################
ensure_docker() {
    if ! command -v docker &>/dev/null; then
        install_docker
    else
        if ! docker info &>/dev/null; then
            log "Docker installed but not running, starting..."
            systemctl start docker 2>/dev/null || true
            sleep 3
        fi
        if ! docker compose version &>/dev/null; then
            log "Installing docker-compose-plugin..."
            apt-get update  >>"$LOG_FILE" 2>&1 || true
            apt-get install -y docker-compose-plugin >>"$LOG_FILE" 2>&1 || true
        fi
        log "Docker already installed, verifying..."
        verify_docker
    fi
}

install_docker() {
    log "Installing Docker..."

    local gauge_pid

    dialog --gauge "Обновление пакетов..." 8 60 0 &
    gauge_pid=$!
    apt-get update >>"$LOG_FILE" 2>&1
    kill "$gauge_pid" 2>/dev/null || true
    wait "$gauge_pid" 2>/dev/null || true

    dialog --gauge "Скачивание установщика Docker..." 8 60 33 &
    gauge_pid=$!
    local _docker_sh
    _docker_sh=$(_mktemp)
    curl -fsSL https://get.docker.com -o "$_docker_sh" >>"$LOG_FILE" 2>&1
    kill "$gauge_pid" 2>/dev/null || true
    wait "$gauge_pid" 2>/dev/null || true

    dialog --gauge "Установка Docker..." 8 60 66 &
    gauge_pid=$!
    bash "$_docker_sh" >>"$LOG_FILE" 2>&1
    # _docker_sh остаётся в _MKTEMPS → cleanup удалит; rm здесь не нужен
    kill "$gauge_pid" 2>/dev/null || true
    wait "$gauge_pid" 2>/dev/null || true

    usermod -aG docker "$REAL_USER" 2>/dev/null || true
    systemctl enable docker --now >/dev/null 2>&1

    if command -v docker &>/dev/null; then
        dialog --msgbox "Docker установлен успешно!" 6 50
        log "Docker installed successfully"
    else
        log "ERROR: Docker installation failed"
        dialog --msgbox "Docker НЕ установлен. Проверьте логи:\n$LOG_FILE" 8 55
        exit 1
    fi

    if ! docker compose version &>/dev/null; then
        log "Installing docker-compose-plugin..."
        apt-get install -y docker-compose-plugin >>"$LOG_FILE" 2>&1 || true
    fi

    verify_docker
}

verify_docker() {
    log "Verifying Docker with hello-world..."
    local _vt
    _vt=$(_mktemp)

    # --rm автоматически удаляет контейнер после завершения;
    # docker rm -f здесь не нужен и потенциально опасен
    if docker run --rm hello-world >"$_vt" 2>&1; then
        log "Docker verified OK"
        return 0
    fi

    log "Docker verification FAILED — attempting auto-repair"
    cat "$_vt" >>"$LOG_FILE" 2>/dev/null || true

    if grep -qi "failed to lease\|containerd" "$_vt" 2>/dev/null; then
        dialog --title "Ремонт Docker" \
            --msgbox "Найдена проблема containerd.\nСейчас будет автоматически исправлена." \
            8 60

        systemctl stop docker      2>/dev/null || true
        systemctl stop containerd  2>/dev/null || true

        rm -rf /var/lib/containerd/io.containerd.metadata.v1.bolt/* 2>/dev/null || true
        rm -rf /var/lib/containerd/state/*                           2>/dev/null || true
        rm -rf /var/lib/containerd/tmpmounts/*                       2>/dev/null || true

        systemctl start containerd 2>/dev/null || true
        sleep 2
        systemctl start docker     2>/dev/null || true
        sleep 3

        if docker run --rm hello-world >"$_vt" 2>&1; then
            log "Docker repaired and verified OK"
            dialog --msgbox "Docker успешно починен и работает." 6 50
            return 0
        fi
    fi

    log "ERROR: Docker still broken after auto-repair"
    dialog --title "Ошибка Docker" --textbox "$_vt" 20 80
    exit 1
}

###############################################################################
#  СЕТЬ + .env
###############################################################################
setup_network() {
    docker network inspect internal_network &>/dev/null \
        || docker network create internal_network >>"$LOG_FILE" 2>&1

    mkdir -p "$SETUP_DIR"
    cd "$SETUP_DIR" || { log "ERROR: Cannot cd to $SETUP_DIR"; return 1; }

    # Создаём .env если не существует; НЕ обнуляем существующий —
    # используем inject_env чтобы обновить только нужные ключи.
    [[ ! -f .env ]] && touch .env
    chmod 600 .env

    # Строки — через env_esc (двойные кавычки bash-стиль)
    # Числа — plain (без кавычек)
    if is_selected "postgres"; then
        inject_env .env POSTGRES_PASSWORD "$(env_esc "${PGPASSWORD:-}")"
    fi
    if is_selected "supabase"; then
        inject_env .env JWT_SECRET "$(env_esc "${JWT_SECRET:-}")"
    fi
    inject_env .env LLM_TYPE    "$(env_esc "${LLM_TYPE:-}")"
    inject_env .env LLM_API_KEY "$(env_esc "${LLM_API_KEY:-}")"
    inject_env .env LLM_API_URL "$(env_esc "${LLM_API_URL:-}")"
    inject_env .env DOMAIN      "$(env_esc "${DOMAIN:-}")"

    if is_selected "supabase"; then
        inject_env .env SUPABASE_DOMAIN "$(env_esc "${SUPABASE_DOMAIN:-}")"
    fi
    if is_selected "n8n"; then
        inject_env .env N8N_PORT        "${N8N_PORT}"
        inject_env .env N8N_DB_POSTGRES "${N8N_DB_POSTGRES}"
    fi
    if is_selected "apache"; then
        inject_env .env APACHE_WWW_PATH  "$(env_esc "${APACHE_WWW_PATH:-}")"
        inject_env .env APACHE_HTTP_PORT "${APACHE_HTTP_PORT}"
    fi
    if is_selected "qdrant";    then inject_env .env QDRANT_PORT    "${QDRANT_PORT}";    fi
    if is_selected "portainer"; then inject_env .env PORTAINER_PORT "${PORTAINER_PORT}"; fi
    if is_selected "ollama";    then inject_env .env OLLAMA_PORT    "${OLLAMA_PORT}";    fi

    log "Network and .env updated"
}

###############################################################################
#  SUPABASE — вспомогательные функции (верхний уровень, не вложенные)
###############################################################################

# Патч портов в docker-compose.yml Supabase.
# Вызывается из setup_supabase после cd supabase-docker.
_supabase_patch_ports() {
    local _sb_tmp
    _sb_tmp=$(_mktemp)
    sed \
        -e "s/:3000:/:${SUPABASE_PORT_STUDIO}:/g" \
        -e "s/:54322:/:${SUPABASE_PORT_PG}:/g"    \
        -e "s/:8000:/:${SUPABASE_PORT_API}:/g"    \
        -e "s/:8085:/:${SUPABASE_PORT_MAIL}:/g"   \
        -e "s/:5555:/:${SUPABASE_PORT_AUTH}:/g"   \
        docker-compose.yml > "$_sb_tmp"
    mv "$_sb_tmp" docker-compose.yml
    log "Supabase: ports patched Studio=$SUPABASE_PORT_STUDIO \
DB=$SUPABASE_PORT_PG API=$SUPABASE_PORT_API \
Mail=$SUPABASE_PORT_MAIL Auth=$SUPABASE_PORT_AUTH"
}

# Добавляет секцию internal_network в docker-compose.yml Supabase если её нет.
# Вызывается из setup_supabase после cd supabase-docker.
_supabase_ensure_network() {
    if ! grep -q "internal_network" docker-compose.yml; then
        printf '\nnetworks:\n  internal_network:\n    external: true\n' \
            >> docker-compose.yml
    fi
}

_supabase_wait_healthy() {
    # $1 = container_name, $2 = max seconds to wait
    local container="$1" max_wait="${2:-120}"
    local elapsed=0
    while [[ $elapsed -lt $max_wait ]]; do
        local status
        status=$(docker inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null)
        if [[ "$status" == "healthy" ]]; then
            log "Supabase: $container — healthy after ${elapsed}s"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    log "WARNING: Supabase: $container did not become healthy in ${max_wait}s (current: $status)"
    return 1
}

_supabase_step_up() {
    # Поэтапный запуск: $1 = список сервисов (через пробел), $2 = заголовок, $3 = контейнер для health-ожидания
    local services="$1" label="$2" health_container="$3"
    dialog --title "Supabase" --gauge "[ЭТАП] $label" 8 60 0
    log "Supabase: [UP]  $services"
    docker compose -p supabase up -d $services >>"$LOG_FILE" 2>&1
    if [[ -n "$health_container" ]]; then
        sleep 10
        _supabase_wait_healthy "$health_container" 180
        return $?
    else
        sleep 5
    fi
}

verify_supabase() {
    local supa_count
    supa_count=$(docker ps \
        --filter "name=supabase" \
        --filter "status=running" \
        --format "{{.Names}}" 2>/dev/null | wc -l)
    if [[ "$supa_count" -gt 0 ]]; then
        log "Supabase verification OK: $supa_count containers running"
        return 0
    fi
    log "ERROR: Supabase verification FAILED — no running containers"
    return 1
}

supabase_compose_pull_retry() {
    # Вызывается из setup_supabase; PWD = SETUP_DIR/supabase-docker
    local max_pull=3 p=0
    while [[ $p -lt $max_pull ]]; do
        p=$((p + 1))
        log "Supabase: compose pull attempt $p/$max_pull..."
        if timeout 600 docker compose -p supabase pull >>"$LOG_FILE" 2>&1; then
            log "Supabase: all images pulled successfully"
            return 0
        fi
        log "WARNING: Supabase pull attempt $p failed, retrying in 15s..."
        sleep 15
    done
    log "ERROR: Supabase pull failed after $max_pull attempts"
    return 1
}

supabase_compose_up() {
    # ═══════════════════════════════════════════════════════════
    #  Поэтапный запуск Supabase в правильном порядке зависимостей:
    #
    #  Этап 1: db (PostgreSQL)                  → ждём healthy
    #  Этап 2: analytics (Logflare)              → ждём healthy (зависит от db)
    #  Этап 3: vector                            → ждём healthy (зависит от analytics)
    #  Этап 4: studio (dashboard)                → ждём healthy (зависит от analytics)
    #  Этап 5: kong (API Gateway)                → ждём healthy (зависит от studio)
    #  Этап 6: auth, rest, storage, meta,        → параллельно (все зависят только от db)
    #          realtime, imgproxy, supavisor,
    #          functions
    # ═════════════════════════════════════════════════════════==
    local max_attempts=3 attempt=0
    while [[ $attempt -lt $max_attempts ]]; do
        attempt=$((attempt + 1))
        log "Supabase compose up — stage launch attempt $attempt/$max_attempts"

        # --- Этап 1: БД ---
        _supabase_step_up "db" "1/6 — Запуск PostgreSQL (db)" "supabase-db"
        local db_ok=$?
        # db критична — без неё дальше смысла нет
        if [[ $db_ok -ne 0 ]]; then
            local db_status
            db_status=$(docker inspect --format '{{.State.Status}}' supabase-db 2>/dev/null)
            log "WARNING: Supabase: db not healthy (status=$db_status), continuing anyway..."
        fi

        # --- Этап 2: Аналитика ---
        _supabase_step_up "analytics" "2/6 — Запуск аналитики (analytics)" "supabase-analytics"

        # --- Этап 3: Vector ---
        _supabase_step_up "vector" "3/6 — Запуск Vector" "supabase-vector"

        # --- Этап 4: Студия (Dashboard) ---
        _supabase_step_up "studio" "4/6 — Запуск студии (studio)" "supabase-studio"

        # --- Этап 5: Kong (API Gateway) ---
        _supabase_step_up "kong" "5/6 — Запуск API-шлюза (kong)" "supabase-kong"
        local kong_status
        kong_status=$(docker inspect --format '{{.State.Status}}' supabase-kong 2>/dev/null)
        if [[ "$kong_status" != "running" ]]; then
            log "WARNING: Supabase: kong not running after stage 5 (status=$kong_status), trying docker start..."
            docker start supabase-kong >>"$LOG_FILE" 2>&1 || true
            sleep 10
            _supabase_wait_healthy "supabase-kong" 90 || true
        fi

        # --- Этап 6: Остальные сервисы (все зависят от db, но НЕ kong) ---
        # Запускаем параллельно — у них нет cross-зависимостей
        dialog --title "Supabase" --gauge "[ЭТАП] 6/6 — Все остальные сервисы" 8 60 0
        docker compose -p supabase up -d \
            auth rest storage meta realtime imgproxy supavisor functions \
            >>"$LOG_FILE" 2>&1 || true
        sleep 30

        # --- Даем time на стабилизацию ---
        log "Supabase: all services started, waiting 30s for stabilization..."
        sleep 30

        # --- Проверка ключевых сервисов ---
        local critical_ok=1
        for _svc in supabase-db supabase-analytics supabase-studio supabase-kong \
                    supabase-auth supabase-rest supabase-storage; do
            local st
            st=$(docker inspect --format '{{.State.Status}}' "$_svc" 2>/dev/null)
            if [[ "$st" == "running" ]]; then
                log "Supabase: $_svc — running ✓"
            else
                log "WARNING: Supabase: $_svc — $st ✗ — пытаемся перезапустить"
                docker start "$_svc" >>"$LOG_FILE" 2>&1 || true
                # Если kong не запустился — это критично, пробуем ещё раз
                if [[ "$_svc" == "supabase-kong" ]]; then
                    critical_ok=0
                fi
            fi
        done

        if verify_supabase; then
            log "Supabase: stage launch (attempt $attempt) — SUCCESS"
            return 0
        fi

        log "WARNING: Supabase: stage launch attempt $attempt — some services missing, retrying..."
        if [[ $attempt -lt $max_attempts ]]; then
            log "Supabase: stopping for retry..."
            docker compose -p supabase down >>"$LOG_FILE" 2>&1 || true
            supabase_compose_pull_retry || true
            sleep 15
        fi
    done
    return 1
}

connect_supabase_to_network() {
    docker ps \
        --filter "name=supabase" \
        --filter "status=running" \
        --format "{{.Names}}" 2>/dev/null \
    | while IFS= read -r c; do
        docker network connect internal_network "$c" 2>/dev/null || true
    done
}

setup_supabase() {
    if ! is_selected "supabase"; then
        return 0
    fi

    log "Supabase setup started"
    pushd "$SETUP_DIR" >/dev/null \
        || { log "ERROR: Cannot pushd to $SETUP_DIR"; return 1; }

    # ─── Скачивание docker-папки ────────────────────────────────────────────
    if [[ ! -d "supabase-docker" ]]; then
        local _gauge_pid
        dialog --title "Supabase (1/2)" \
            --gauge "Скачивание supabase/docker..." 8 60 10 &
        _gauge_pid=$!

        log "Supabase: downloading docker folder from GitHub..."
        local _dl_ok=0
        local _archive="$SETUP_DIR/supabase-docker.tar.gz"

        # Попытка 1: wget
        if command -v wget &>/dev/null; then
            log "Supabase: attempt 1 (wget with resume)"
            rm -f "$_archive"
            timeout 600 wget --tries=5 --continue --timeout=90 \
                -O "$_archive" -q \
                "https://codeload.github.com/supabase/supabase/tar.gz/refs/heads/master" \
                >>"$LOG_FILE" 2>&1 && _dl_ok=1
        fi

        # Попытка 2: curl codeload
        if [[ $_dl_ok -eq 0 ]] && command -v curl &>/dev/null; then
            log "Supabase: attempt 2 (curl codeload)"
            rm -f "$_archive"
            timeout 600 curl -fSL --retry 5 --retry-delay 15 \
                -o "$_archive" -s \
                "https://codeload.github.com/supabase/supabase/tar.gz/refs/heads/master" \
                >>"$LOG_FILE" 2>&1 && _dl_ok=1
        fi

        # Попытка 3: curl github archive
        if [[ $_dl_ok -eq 0 ]] && command -v curl &>/dev/null; then
            log "Supabase: attempt 3 (curl github archive)"
            rm -f "$_archive"
            timeout 600 curl -fSL --retry 5 --retry-delay 15 \
                -o "$_archive" -s \
                "https://github.com/supabase/supabase/archive/refs/heads/master.tar.gz" \
                >>"$LOG_FILE" 2>&1 && _dl_ok=1
        fi

        # Распаковка архива
        if [[ $_dl_ok -eq 1 ]] && [[ -f "$_archive" ]]; then
            log "Supabase: extracting docker folder..."
            mkdir -p "$SETUP_DIR/supabase-tmp"
            if timeout 60 tar -xzf "$_archive" -C "$SETUP_DIR/supabase-tmp" \
                >>"$LOG_FILE" 2>&1; then
                local _first_dir
                _first_dir=$(ls "$SETUP_DIR/supabase-tmp/" 2>/dev/null | head -1)
                if [[ -n "$_first_dir" ]] && \
                   [[ -d "$SETUP_DIR/supabase-tmp/$_first_dir/docker" ]]; then
                    mv "$SETUP_DIR/supabase-tmp/$_first_dir/docker" \
                       "$SETUP_DIR/supabase-docker"
                    _dl_ok=2
                else
                    log "ERROR: docker/ not found in archive"
                fi
            else
                log "ERROR: tar extraction failed"
            fi
            rm -rf "$SETUP_DIR/supabase-tmp" "$_archive"
        fi

        # Попытка 4: GitHub API отдельные файлы
        if [[ $_dl_ok -lt 2 ]] && command -v curl &>/dev/null; then
            log "Supabase: attempt 4 (GitHub API individual files)"
            local _api_json
            _api_json=$(_mktemp)
            rm -rf "$SETUP_DIR/supabase-docker"
            if curl -fSL -s -o "$_api_json" \
                "https://api.github.com/repos/supabase/supabase/contents/docker" \
                >>"$LOG_FILE" 2>&1; then
                mkdir -p "$SETUP_DIR/supabase-docker"
                local _urls _url _fname
                _urls=$(grep -o '"download_url":"[^"]*"' "$_api_json" \
                        | cut -d'"' -f4)
                for _url in $_urls; do
                    _fname=$(basename "$_url")
                    log "Supabase: GET $_fname"
                    timeout 60 curl -fSLo \
                        "$SETUP_DIR/supabase-docker/$_fname" \
                        -s "$_url" >>"$LOG_FILE" 2>&1 || true
                done
                if [[ -f "$SETUP_DIR/supabase-docker/docker-compose.yml" ]]; then
                    _dl_ok=3
                else
                    rm -rf "$SETUP_DIR/supabase-docker"
                fi
            fi
        fi

        # Попытка 5: git clone
        if [[ $_dl_ok -lt 2 ]]; then
            log "Supabase: attempt 5 (git clone --depth 1)"
            rm -rf "$SETUP_DIR/supabase-git"
            if timeout 600 git clone --depth 1 --no-tags \
                https://github.com/supabase/supabase \
                "$SETUP_DIR/supabase-git" >>"$LOG_FILE" 2>&1; then
                [[ -d "$SETUP_DIR/supabase-git/docker" ]] && \
                    mv "$SETUP_DIR/supabase-git/docker" \
                       "$SETUP_DIR/supabase-docker"
                rm -rf "$SETUP_DIR/supabase-git"
            fi
        fi

        kill "$_gauge_pid" 2>/dev/null || true
        wait "$_gauge_pid" 2>/dev/null || true

        if [[ ! -d "$SETUP_DIR/supabase-docker" ]]; then
            log "ERROR: supabase-docker not created after all attempts"
            popd >/dev/null 2>&1 || true
            dialog --title "Ошибка" \
                --msgbox "Не удалось скачать Supabase.\nНет интернета или блокировка GitHub.\nЛог: $LOG_FILE" \
                10 60
            return 1
        fi
        log "Supabase docker folder downloaded successfully"
    fi

    cd supabase-docker \
        || { log "ERROR: cd supabase-docker failed"; popd >/dev/null 2>&1 || true; return 1; }

    # Override для realtime healthcheck
    cat > docker-compose.override.yml << 'OVERRIDE_EOF'
services:
  realtime:
    healthcheck:
      test: "curl -sSfL --head -o /dev/null http://localhost:4000/ || exit 1"
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
OVERRIDE_EOF
    log "Supabase: realtime healthcheck override created"

    # ─── Обновление существующей установки ──────────────────────────────────
    if [[ -f ".env" ]] && grep -q "^ANON_KEY=" .env 2>/dev/null; then
        log "Supabase already installed, updating config..."

        [[ -n "${PGPASSWORD:-}" ]] && \
            inject_env .env POSTGRES_PASSWORD "$(env_esc "${PGPASSWORD}")"
        [[ -n "${JWT_SECRET:-}" ]] && \
            inject_env .env JWT_SECRET "$(env_esc "${JWT_SECRET}")"
        if [[ -n "${SUPABASE_DOMAIN:-}" ]]; then
            inject_env .env PUBLIC_URL       "$(env_esc "https://${SUPABASE_DOMAIN}")"
            inject_env .env API_EXTERNAL_URL "$(env_esc "https://${SUPABASE_DOMAIN}")"
            inject_env .env SITE_URL         "$(env_esc "https://${SUPABASE_DOMAIN}")"
        fi

        _supabase_ensure_network
        _supabase_patch_ports

        local _g_pid
        dialog --title "Supabase" --gauge "Перезапуск Supabase..." 8 60 50 &
        _g_pid=$!
        if supabase_compose_up; then
            connect_supabase_to_network
            kill "$_g_pid" 2>/dev/null || true
            wait "$_g_pid" 2>/dev/null || true
            dialog --title "Supabase" \
                --msgbox "Supabase (обновление) запущен и работает!" 6 55
        else
            kill "$_g_pid" 2>/dev/null || true
            wait "$_g_pid" 2>/dev/null || true
            log "ERROR: Supabase restart failed"
            dialog --title "Ошибка" \
                --msgbox "Supabase не удалось перезапустить.\nЛог: $LOG_FILE" 8 55
        fi
        popd >/dev/null 2>&1 || true
        return 0
    fi

    # ─── Новая установка ────────────────────────────────────────────────────
    if [[ ! -f ".env.example" ]]; then
        log "ERROR: .env.example not found in supabase-docker"
        popd >/dev/null 2>&1 || true
        dialog --title "Ошибка" \
            --msgbox "Файл .env.example не найден в supabase-docker.\nЛог: $LOG_FILE" \
            10 60
        return 1
    fi

    cp .env.example .env

    # Генерируем случайные ключи
    local ANON_KEY SERVICE_ROLE_KEY SECRET_KEY_BASE VAULT_ENC_KEY
    local PG_META_CRYPTO_KEY LOGFILE_PUBLIC_ACCESS_TOKEN
    local LOGFILE_PRIVATE_ACCESS_TOKEN S3_PROTOCOL_ACCESS_KEY_SECRET
    local S3_PROTOCOL_ACCESS_KEY_ID MINIO_ROOT_PASSWORD DASHBOARD_PASSWORD

    ANON_KEY=$(openssl rand -hex 32)
    SERVICE_ROLE_KEY=$(openssl rand -hex 32)
    SECRET_KEY_BASE=$(openssl rand -hex 32)
    VAULT_ENC_KEY=$(openssl rand -hex 32)
    PG_META_CRYPTO_KEY=$(openssl rand -hex 32)
    LOGFILE_PUBLIC_ACCESS_TOKEN=$(openssl rand -hex 32)
    LOGFILE_PRIVATE_ACCESS_TOKEN=$(openssl rand -hex 32)
    S3_PROTOCOL_ACCESS_KEY_SECRET=$(openssl rand -hex 32)
    S3_PROTOCOL_ACCESS_KEY_ID=$(openssl rand -hex 16)
    MINIO_ROOT_PASSWORD=$(openssl rand -hex 16)
    DASHBOARD_PASSWORD=$(openssl rand -hex 12)

    # Случайные ключи — hex, спецсимволов нет → plain (без env_esc)
    local var
    for var in ANON_KEY SERVICE_ROLE_KEY SECRET_KEY_BASE VAULT_ENC_KEY \
               PG_META_CRYPTO_KEY LOGFILE_PUBLIC_ACCESS_TOKEN \
               LOGFILE_PRIVATE_ACCESS_TOKEN S3_PROTOCOL_ACCESS_KEY_ID \
               S3_PROTOCOL_ACCESS_KEY_SECRET MINIO_ROOT_PASSWORD \
               DASHBOARD_PASSWORD; do
        inject_env .env "$var" "${!var}"
    done

    [[ -n "${JWT_SECRET:-}" ]] && \
        inject_env .env JWT_SECRET "$(env_esc "${JWT_SECRET}")"
    [[ -n "${PGPASSWORD:-}" ]] && \
        inject_env .env POSTGRES_PASSWORD "$(env_esc "${PGPASSWORD}")"
    if [[ -n "${SUPABASE_DOMAIN:-}" ]]; then
        inject_env .env PUBLIC_URL       "$(env_esc "https://${SUPABASE_DOMAIN}")"
        inject_env .env API_EXTERNAL_URL "$(env_esc "https://${SUPABASE_DOMAIN}")"
        inject_env .env SITE_URL         "$(env_esc "https://${SUPABASE_DOMAIN}")"
    fi

    _supabase_ensure_network
    _supabase_patch_ports

    log "Supabase: starting containers (new install)..."

    local _g_pid
    dialog --title "Supabase (2/2)" \
        --gauge "Запуск Supabase... это может занять время..." 8 60 50 &
    _g_pid=$!

    if supabase_compose_up; then
        connect_supabase_to_network
        kill "$_g_pid" 2>/dev/null || true
        wait "$_g_pid" 2>/dev/null || true
        dialog --title "Supabase" --msgbox "Supabase запущен и работает!" 6 50
        log "Supabase setup completed successfully"
    else
        kill "$_g_pid" 2>/dev/null || true
        wait "$_g_pid" 2>/dev/null || true
        log "ERROR: Supabase first start FAILED"
        dialog --title "Ошибка Supabase" \
            --msgbox "Supabase НЕ запустился.\nЛог: $LOG_FILE\n\nПроверьте:\n- Порты свободны\n- Docker ресурсы не исчерпаны" \
            12 60
    fi

    popd >/dev/null 2>&1 || true
}

###############################################################################
#  ГЕНЕРАЦИЯ docker-compose.yml
###############################################################################
generate_compose_file() {
    cd "$SETUP_DIR" || { log "ERROR: Cannot cd to $SETUP_DIR"; return 1; }

    # Проверяем есть ли хоть один compose-сервис (не supabase)
    local _has_compose_svc=0
    local _s
    for _s in postgres qdrant ollama nginx_proxy portainer n8n apache; do
        is_selected "$_s" && _has_compose_svc=1 && break
    done

    if [[ $_has_compose_svc -eq 0 ]]; then
        log "No compose services selected — skipping docker-compose generation"
        rm -f "$SETUP_DIR/docker-compose.yml"
        return 0
    fi

    # Пароль для YAML single-quoted scalar.
    # yaml_sq_esc экранирует ' → '' (единственный спецсимвол в YAML sq-scalar).
    # Внешние одинарные кавычки добавляем в printf явно.
    local _pg_sq
    _pg_sq=$(yaml_sq_esc "${PGPASSWORD:-}")

    # Путь Apache для YAML double-quoted scalar
    local _www
    _www=$(compose_esc "${APACHE_WWW_PATH:-}")

    # Домен/хост для WEBHOOK_URL — экранируем для YAML sq-scalar
    local _webhook_host
    _webhook_host=$(yaml_sq_esc "${DOMAIN:-localhost}")
    local _webhook_url
    _webhook_url="http://${_webhook_host}:${N8N_PORT}"

    {
        printf 'networks:\n'
        printf '  internal_network:\n'
        printf '    external: true\n'
        printf 'volumes:\n'
        is_selected "postgres"    && printf '  postgres_data:\n'
        is_selected "qdrant"      && printf '  qdrant_storage:\n'
        is_selected "ollama"      && printf '  ollama_data:\n'
        if is_selected "nginx_proxy"; then
            printf '  npm_data:\n'
            printf '  npm_letsencrypt:\n'
        fi
        is_selected "portainer"   && printf '  portainer_data:\n'
        is_selected "n8n"         && printf '  n8n_data:\n'
        printf 'services:\n'
    } > docker-compose.yml

    # --- PostgreSQL ---
    if is_selected "postgres"; then
        mkdir -p "$SETUP_DIR/pg-init"
        cat > "$SETUP_DIR/pg-init/init-n8n.sql" <<'SQLEOF'
SELECT 'CREATE DATABASE n8n'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'n8n')\gexec
SQLEOF
        # Пароль в YAML single-quoted scalar: '${_pg_sq}'
        # printf гарантирует корректную вставку без heredoc-интерполяции
        printf '  postgres:\n'                                             >> docker-compose.yml
        printf '    image: postgres:16-alpine\n'                          >> docker-compose.yml
        printf '    container_name: postgres\n'                           >> docker-compose.yml
        printf '    restart: unless-stopped\n'                            >> docker-compose.yml
        printf '    environment:\n'                                        >> docker-compose.yml
        printf '      POSTGRES_USER: admin\n'                             >> docker-compose.yml
        printf "      POSTGRES_PASSWORD: '%s'\n" "$_pg_sq"                >> docker-compose.yml
        printf '      POSTGRES_DB: appdb\n'                               >> docker-compose.yml
        printf '    volumes:\n'                                            >> docker-compose.yml
        printf '      - postgres_data:/var/lib/postgresql/data\n'         >> docker-compose.yml
        printf '      - ./pg-init:/docker-entrypoint-initdb.d\n'         >> docker-compose.yml
        printf '    networks:\n'                                           >> docker-compose.yml
        printf '      - internal_network\n'                               >> docker-compose.yml
    fi

    # --- Qdrant ---
    if is_selected "qdrant"; then
        printf '  qdrant:\n'                                               >> docker-compose.yml
        printf '    image: qdrant/qdrant:latest\n'                        >> docker-compose.yml
        printf '    container_name: qdrant\n'                             >> docker-compose.yml
        printf '    restart: unless-stopped\n'                            >> docker-compose.yml
        printf '    ports:\n'                                              >> docker-compose.yml
        printf "      - '%s:6333'\n" "${QDRANT_PORT}"                     >> docker-compose.yml
        printf '    volumes:\n'                                            >> docker-compose.yml
        printf '      - qdrant_storage:/qdrant/storage\n'                 >> docker-compose.yml
        printf '    networks:\n'                                           >> docker-compose.yml
        printf '      - internal_network\n'                               >> docker-compose.yml
    fi

    # --- Ollama ---
    if is_selected "ollama"; then
        printf '  ollama:\n'                                               >> docker-compose.yml
        printf '    image: ollama/ollama:latest\n'                        >> docker-compose.yml
        printf '    container_name: ollama\n'                             >> docker-compose.yml
        printf '    restart: unless-stopped\n'                            >> docker-compose.yml
        printf '    ports:\n'                                              >> docker-compose.yml
        printf "      - '%s:11434'\n" "${OLLAMA_PORT}"                    >> docker-compose.yml
        printf '    environment:\n'                                        >> docker-compose.yml
        printf '      OLLAMA_HOST: 0.0.0.0\n'                            >> docker-compose.yml
        printf '    volumes:\n'                                            >> docker-compose.yml
        printf '      - ollama_data:/root/.ollama\n'                      >> docker-compose.yml
        printf '    networks:\n'                                           >> docker-compose.yml
        printf '      - internal_network\n'                               >> docker-compose.yml
    fi

    # --- Apache ---
    if is_selected "apache"; then
        printf '  apache:\n'                                               >> docker-compose.yml
        printf '    image: httpd:2.4-alpine\n'                            >> docker-compose.yml
        printf '    container_name: apache\n'                             >> docker-compose.yml
        printf '    restart: unless-stopped\n'                            >> docker-compose.yml
        printf '    ports:\n'                                              >> docker-compose.yml
        printf "      - '%s:80'\n" "${APACHE_HTTP_PORT}"                  >> docker-compose.yml
        printf '    volumes:\n'                                            >> docker-compose.yml
        printf '      - "%s:/usr/local/apache2/htdocs/"\n' "$_www"        >> docker-compose.yml
        printf '      - "%s/conf:/usr/local/apache2/conf/extra/"\n' "$_www" >> docker-compose.yml
        printf '    networks:\n'                                           >> docker-compose.yml
        printf '      - internal_network\n'                               >> docker-compose.yml
    fi

    # --- Nginx Proxy Manager ---
    if is_selected "nginx_proxy"; then
        printf '  nginx-proxy-manager:\n'                                  >> docker-compose.yml
        printf '    image: jc21/nginx-proxy-manager:latest\n'             >> docker-compose.yml
        printf '    container_name: nginx-proxy-manager\n'                >> docker-compose.yml
        printf '    restart: unless-stopped\n'                            >> docker-compose.yml
        printf '    ports:\n'                                              >> docker-compose.yml
        printf "      - '80:80'\n"                                        >> docker-compose.yml
        printf "      - '443:443'\n"                                      >> docker-compose.yml
        printf "      - '81:81'\n"                                        >> docker-compose.yml
        printf '    volumes:\n'                                            >> docker-compose.yml
        printf '      - npm_data:/data\n'                                 >> docker-compose.yml
        printf '      - npm_letsencrypt:/etc/letsencrypt\n'               >> docker-compose.yml
        printf '    networks:\n'                                           >> docker-compose.yml
        printf '      - internal_network\n'                               >> docker-compose.yml
    fi

    # --- Portainer ---
    if is_selected "portainer"; then
        printf '  portainer:\n'                                            >> docker-compose.yml
        printf '    image: portainer/portainer-ce:latest\n'               >> docker-compose.yml
        printf '    container_name: portainer\n'                          >> docker-compose.yml
        printf '    restart: unless-stopped\n'                            >> docker-compose.yml
        printf '    command: -H unix:///var/run/docker.sock\n'            >> docker-compose.yml
        printf '    volumes:\n'                                            >> docker-compose.yml
        printf '      - /var/run/docker.sock:/var/run/docker.sock\n'      >> docker-compose.yml
        printf '      - portainer_data:/data\n'                           >> docker-compose.yml
        printf '    ports:\n'                                              >> docker-compose.yml
        printf "      - '%s:9000'\n" "${PORTAINER_PORT}"                  >> docker-compose.yml
        printf '    networks:\n'                                           >> docker-compose.yml
        printf '      - internal_network\n'                               >> docker-compose.yml
    fi

    # --- n8n ---
    if is_selected "n8n"; then
        printf '  n8n:\n'                                                  >> docker-compose.yml
        printf '    image: n8nio/n8n:latest\n'                            >> docker-compose.yml
        printf '    container_name: n8n\n'                                >> docker-compose.yml
        printf '    restart: unless-stopped\n'                            >> docker-compose.yml
        printf '    ports:\n'                                              >> docker-compose.yml
        printf "      - '%s:5678'\n" "${N8N_PORT}"                        >> docker-compose.yml
        printf '    environment:\n'                                        >> docker-compose.yml

        if [[ "${N8N_DB_POSTGRES:-0}" == "1" ]] && is_selected "postgres"; then
            printf '      DB_TYPE: postgresdb\n'                          >> docker-compose.yml
            printf '      DB_POSTGRESDB_HOST: postgres\n'                 >> docker-compose.yml
            printf "      DB_POSTGRESDB_PORT: '5432'\n"                   >> docker-compose.yml
            printf '      DB_POSTGRESDB_DATABASE: n8n\n'                  >> docker-compose.yml
            printf '      DB_POSTGRESDB_USER: admin\n'                    >> docker-compose.yml
            # Пароль — YAML single-quoted scalar
            printf "      DB_POSTGRESDB_PASSWORD: '%s'\n" "$_pg_sq"      >> docker-compose.yml
        fi

        printf '      N8N_HOST: 0.0.0.0\n'                               >> docker-compose.yml
        printf "      N8N_PORT: '5678'\n"                                 >> docker-compose.yml
        # WEBHOOK_URL — YAML single-quoted scalar; домен уже экранирован в _webhook_url
        printf "      WEBHOOK_URL: '%s'\n" "$_webhook_url"                >> docker-compose.yml

        if [[ "${N8N_DB_POSTGRES:-0}" == "1" ]] && is_selected "postgres"; then
            printf '    depends_on:\n'                                     >> docker-compose.yml
            printf '      - postgres\n'                                    >> docker-compose.yml
        fi

        printf '    volumes:\n'                                            >> docker-compose.yml
        printf '      - n8n_data:/home/node/.n8n\n'                       >> docker-compose.yml
        printf '    networks:\n'                                           >> docker-compose.yml
        printf '      - internal_network\n'                               >> docker-compose.yml
    fi

    log "docker-compose.yml generated"
}

###############################################################################
#  СОЗДАНИЕ БД n8n
###############################################################################
create_n8n_database() {
    local wait_sec=0
    log "n8n DB: waiting for PostgreSQL to be ready..."

    while [[ $wait_sec -lt 90 ]]; do
        local _h
        # -T: не выделять TTY (обязательно в неинтерактивном контексте)
        _h=$(docker exec -T postgres \
            pg_isready -U admin -h localhost 2>&1) || true
        if echo "$_h" | grep -qi "accepting"; then
            log "n8n DB: PostgreSQL ready after ${wait_sec}s"
            break
        fi
        sleep 3
        wait_sec=$((wait_sec + 3))
    done

    if [[ $wait_sec -ge 90 ]]; then
        log "WARNING: PostgreSQL did not become ready in 90s, trying anyway..."
    fi

    local n=0
    while [[ $n -lt 3 ]]; do
        n=$((n + 1))
        log "n8n DB: check attempt $n..."

        local _check _rc
        _rc=0
        # -T обязателен — без него docker exec может зависнуть
        _check=$(docker exec -T postgres \
            psql -U admin -h localhost -d appdb \
            -c "SELECT 1 FROM pg_database WHERE datname='n8n';" -tA 2>&1) \
            || _rc=$?

        log "n8n DB check (try $n): rc=$_rc output=$_check"

        if [[ "$(printf '%s' "$_check" | tr -d '[:space:]')" == "1" ]]; then
            log "n8n database EXISTS"
            return 0
        fi

        log "n8n DB: creating..."
        local _result _rc_c
        _rc_c=0
        _result=$(docker exec -T postgres \
            psql -U admin -h localhost -d appdb \
            -c "CREATE DATABASE n8n;" 2>&1) \
            || _rc_c=$?

        log "n8n CREATE (try $n): rc=$_rc_c output=$_result"

        if [[ $_rc_c -eq 0 ]] || \
           printf '%s' "$_result" | grep -qi "already\|created"; then
            log "n8n database CREATED successfully"
            return 0
        fi

        sleep 5
    done

    # Fallback через compose exec -T
    log "n8n DB: fallback via compose exec -T..."
    (cd "$SETUP_DIR" && \
        docker compose exec -T postgres \
        psql -U admin -h localhost -d appdb \
        -c "CREATE DATABASE n8n;" 2>&1) | tee -a "$LOG_FILE" || true

    log "n8n DB: continuing regardless (n8n will retry on start)"
    return 0
}

###############################################################################
#  ЗАПУСК КОНТЕЙНЕРОВ
###############################################################################
start_containers() {
    cd "$SETUP_DIR" || { log "ERROR: Cannot cd to $SETUP_DIR"; return 1; }

    if [[ ! -f "docker-compose.yml" ]]; then
        log "No docker-compose.yml — skipping container start (supabase only mode)"
        return 0
    fi

    local _has_n8n_pg=0
    if is_selected "n8n" && \
       [[ "${N8N_DB_POSTGRES:-0}" == "1" ]] && \
       is_selected "postgres"; then
        _has_n8n_pg=1
    fi

    local _gp
    if [[ $_has_n8n_pg -eq 1 ]]; then
        dialog --gauge "Шаг 1/3: Запуск PostgreSQL..." 8 60 10 &
        _gp=$!
        docker compose up -d postgres >>"$LOG_FILE" 2>&1
        kill "$_gp" 2>/dev/null || true
        wait "$_gp" 2>/dev/null || true
        sleep 20

        dialog --gauge "Шаг 2/3: Создание БД для n8n..." 8 60 40 &
        _gp=$!
        create_n8n_database
        kill "$_gp" 2>/dev/null || true
        wait "$_gp" 2>/dev/null || true
        sleep 5

        dialog --gauge "Шаг 3/3: Запуск всех контейнеров..." 8 60 70 &
        _gp=$!
        docker compose up -d >>"$LOG_FILE" 2>&1
        kill "$_gp" 2>/dev/null || true
        wait "$_gp" 2>/dev/null || true
        sleep 20
    else
        dialog --gauge "Запуск контейнеров..." 8 60 10 &
        _gp=$!
        docker compose up -d >>"$LOG_FILE" 2>&1
        kill "$_gp" 2>/dev/null || true
        wait "$_gp" 2>/dev/null || true
        sleep 10
    fi

    log "Containers after start:"
    docker ps --format "{{.Names}}\t{{.Status}}" >>"$LOG_FILE" 2>&1

    local running_count
    running_count=$(docker ps \
        --filter "label=com.docker.compose.project" \
        --format '{{.Names}}' 2>/dev/null | wc -l)

    if [[ "$running_count" -eq 0 ]]; then
        log "ERROR: No containers started"
        dialog --title "Ошибка" \
            --msgbox "Контейнеры не запустились.\nЛог: $LOG_FILE" 8 60
        exit 1
    fi
    log "Containers started: $running_count running"
}

###############################################################################
#  NPM INFO
###############################################################################
print_npm_info() {
    is_selected "nginx_proxy" || return 0
    local ip
    ip=$(hostname -I | awk '{print $1}')
    sleep 5
    cat >"$SETUP_DIR/npm_info.txt" <<EOF
NPM: http://${ip}:81
Login: admin@example.com
Pass:  changeme
EOF
    log "NPM info saved to $SETUP_DIR/npm_info.txt"
}

###############################################################################
#  ФИНАЛЬНАЯ СВОДКА
###############################################################################
show_final_summary() {
    local ip
    ip=$(hostname -I | awk '{print $1}')
    local sf="$STATE_DIR/final_summary.txt"
    local running
    running=$(docker ps \
        --format "{{.Names}} ({{.Image}}) -> {{.Status}}" 2>/dev/null) || running=""

    {
        printf '==================================================\n'
        printf '          УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО\n'
        printf '==================================================\n\n'
        printf '  Сервер:  %s\n\n' "$ip"
        printf '--- Установленные контейнеры ---\n'
        if [[ -n "$running" ]]; then
            printf '%s\n' "$running"
        else
            printf '  (нет данных)\n'
        fi
        printf '\n--- Веб-интерфейсы ---\n'
        is_selected "portainer"   && \
            printf '  Portainer:   http://%s:%s\n' "$ip" "${PORTAINER_PORT}"
        is_selected "nginx_proxy" && \
            printf '  Nginx Proxy: http://%s:81  (admin@example.com / changeme)\n' "$ip"
        is_selected "supabase"    && \
            printf '  Supabase:    https://%s\n' "${SUPABASE_DOMAIN:-$ip}"
        is_selected "n8n"         && \
            printf '  n8n:         http://%s:%s\n' "${DOMAIN:-$ip}" "${N8N_PORT}"
        is_selected "apache"      && \
            printf '  Apache:      http://%s:%s\n' "${DOMAIN:-$ip}" "${APACHE_HTTP_PORT}"
        is_selected "qdrant"      && \
            printf '  Qdrant:      http://%s:%s\n' "$ip" "${QDRANT_PORT}"
        is_selected "ollama"      && \
            printf '  Ollama:      http://%s:%s\n' "$ip" "${OLLAMA_PORT}"
        printf '\n--- Лог: %s ---\n' "$LOG_FILE"
        printf '==========================================================\n'
    } > "$sf"
    chmod 600 "$sf"

    dialog --textbox "$sf" 28 72
    log "Final summary displayed"
}

###############################################################################
#  ПЕРЕУСТАНОВКА СЕРВИСА
###############################################################################
reinstall_service() {
    local svc="$1"
    cd "$SETUP_DIR" || { log "ERROR: Cannot cd to $SETUP_DIR"; return 1; }

    case "$svc" in
        supabase)
            dialog --yesno \
                "Переустановить Supabase?\n\nВСЕ ДАННЫЕ БУДУТ УДАЛЕНЫ (-v)\nСделайте backup!" \
                8 60 || return 0
            docker compose -p supabase down -v >>"$LOG_FILE" 2>&1 || true
            rm -rf supabase-docker
            setup_supabase
            ;;
        *)
            log "Reinstalling $svc..."
            generate_compose_file
            docker compose stop "$svc"    >>"$LOG_FILE" 2>&1 || true
            docker compose rm -fv "$svc"  >>"$LOG_FILE" 2>&1 || true
            docker compose up -d "$svc"   >>"$LOG_FILE" 2>&1
            ;;
    esac
    dialog --msgbox "${svc} переустановлен." 6 45
}

###############################################################################
#  СТАТУС
###############################################################################
show_status() {
    local _st
    _st=$(_mktemp)
    if [[ ! -d "$SETUP_DIR" ]]; then
        printf 'Директория %s не найдена.\nСервисы ещё не установлены.\n' \
            "$SETUP_DIR" > "$_st"
    else
        {
            (cd "$SETUP_DIR" && docker compose ps 2>&1) || \
                printf 'Compose не найден в %s\n' "$SETUP_DIR"
            printf '\n--- Все контейнеры ---\n'
            docker ps --format \
                "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || true
        } > "$_st"
    fi
    dialog --title "Статус контейнеров" --textbox "$_st" 24 85
}

###############################################################################
#  POST-INSTALL МЕНЮ
###############################################################################
post_install_menu() {
    while true; do
        local _choice
        _choice=$(dialog --title "Post-install управление" \
            --menu "Установка завершена. Выберите действие:" 20 60 8 \
            "1" "Установить/Добавить сервисы" \
            "2" "Переустановить сервис" \
            "3" "Проверить статус" \
            "4" "Показать сводку" \
            "5" "Показать лог" \
            "6" "Сбросить всё" \
            "7" "Скачать лог (копия в /tmp)" \
            "0" "Выйти" \
            3>&1 1>&2 2>&3) || return 0

        case "$_choice" in
            1)
                show_service_menu
                if [[ ${#SELECTED_ARRAY[@]} -eq 0 ]]; then
                    dialog --msgbox "Ничего не выбрано." 6 50
                    continue
                fi
                if ! input_parameters; then
                    continue
                fi
                save_params
                setup_network
                generate_compose_file
                start_containers
                print_npm_info
                show_final_summary
                # setup_supabase использует pushd/popd — рабочая директория
                # восстанавливается автоматически
                setup_supabase
                ;;
            2)
                local arr=() names svc
                names=$(docker ps --format '{{.Names}}' 2>/dev/null) || names=""
                for svc in postgres qdrant ollama apache nginx-proxy-manager \
                           portainer supabase n8n; do
                    printf '%s\n' "$names" | grep -q "^${svc}$" && \
                        arr+=("$svc" "$svc" off)
                done
                if [[ ${#arr[@]} -eq 0 ]]; then
                    dialog --msgbox "Нет запущенных сервисов." 6 50
                    continue
                fi
                local _sel_svc
                _sel_svc=$(_mktemp)
                dialog --checklist "Выберите для переустановки:" \
                    15 60 6 "${arr[@]}" 2>"$_sel_svc" \
                    || continue
                local ch
                while IFS= read -r ch; do
                    ch="${ch//\"/}"
                    [[ -n "$ch" ]] && reinstall_service "$ch"
                done < "$_sel_svc"
                ;;
            3) show_status ;;
            4) show_final_summary ;;
            5) dialog --title "Лог установки" \
                   --textbox "$LOG_FILE" 32 95 2>/dev/null ;;
            6)
                dialog --yesno \
                    "Сбросить ВСЁ?\n\nБудут удалены:\n  - ${STATE_DIR}\n  - compose down -v\n  - данные Supabase" \
                    10 60 || continue
                (cd "$SETUP_DIR" && docker compose down -v 2>/dev/null || true)
                docker compose -p supabase down -v 2>/dev/null || true
                rm -rf "$STATE_DIR" "$SETUP_DIR"
                dialog --msgbox "Всё сброшено." 6 50
                exec "$0"
                ;;
            7)
                cp "$LOG_FILE" /tmp/install.log 2>/dev/null && \
                    chmod 644 /tmp/install.log 2>/dev/null || true
                local _log_size
                _log_size=$(wc -l < /tmp/install.log 2>/dev/null || echo "?")
                local _ip
                _ip=$(hostname -I | awk '{print $1}')
                dialog --title "Лог скопирован" \
                    --msgbox "Лог готов к скачиванию:\n\n  /tmp/install.log\n  Строк: ${_log_size}\n\nСкачайте локально:\n  scp root@${_ip}:/tmp/install.log .\n\nИли просмотрите прямо здесь (пункт 5)." \
                    14 60
                ;;
            0) return 0 ;;
        esac
    done
}

###############################################################################
#  ГЛАВНАЯ
###############################################################################
main() {
    # Проверка ОС
    if ! grep -qi "ubuntu\|debian" /etc/os-release 2>/dev/null; then
        echo "Поддерживаются только Ubuntu/Debian"
        exit 1
    fi

    # Проверка root
    if [[ "$EUID" -ne 0 ]]; then
        echo "Запустите с sudo"
        exit 1
    fi

    # Установка dialog если нет
    if ! command -v dialog &>/dev/null; then
        apt-get update >/dev/null 2>&1 || true
        apt-get install -y dialog >/dev/null 2>&1 \
            || { echo "Не удалось установить dialog"; exit 1; }
    fi

    # Проверка места на диске
    local avail_gb
    avail_gb=$(df -BG / | awk 'NR==2{gsub(/G/,""); print $4}')
    if [[ "$avail_gb" =~ ^[0-9]+$ ]] && [[ "$avail_gb" -lt 5 ]]; then
        dialog --msgbox "Доступно ${avail_gb} GB. Нужно минимум 5 GB." 8 55
        exit 1
    fi

    load_selected_services
    load_params

    # Режим переустановки из CLI
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
            ensure_docker
            save_state "docker_installed"
            setup_network
            generate_compose_file
            start_containers
            print_npm_info
            show_final_summary
            # Supabase в самом конце — тяжёлый, много образов;
            # pushd/popd внутри гарантируют возврат рабочей директории
            setup_supabase
            save_state "completed"
            ;;

        done|docker_installed|network_needed)
            # При повторном запуске — всегда проверяем Docker
            ensure_docker
            # setup_network обновляет .env через inject_env (не обнуляет)
            setup_network
            generate_compose_file
            start_containers
            print_npm_info
            show_final_summary
            setup_supabase
            save_state "completed"
            ;;

        completed)
            show_final_summary
            ;;
    esac

    post_install_menu
}

main "$@"
