#!/bin/bash
# Orquestrador fino — clone, docker build/run, delega gates ao juiz/validar.py
set -eo pipefail
export LC_NUMERIC=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JUIZ_DIR="$SCRIPT_DIR/juiz"

# ------------------------------------------------------------------------------
# Logs (stdout/stderr → logs/avaliador/)
# ------------------------------------------------------------------------------
JSON_FILE="${1:-}"
_LOG_SLUG="${LOG_RUN_SLUG:-$(basename "${JSON_FILE:-sem-json}" .json)}"
[[ -n "${PR_NUMERO:-}" ]] && _LOG_SLUG="${_LOG_SLUG}_pr${PR_NUMERO}"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/scripts/lib/log-run.sh"
log_run_init avaliador "$_LOG_SLUG"
trap 'log_run_finish $?' EXIT

# ------------------------------------------------------------------------------
# Configuração (juiz/config.env sobrescreve defaults)
# ------------------------------------------------------------------------------
PG_CONTAINER="${PG_CONTAINER:-postgres_db}"
DIR_TESTES="${DIR_TESTES:-/tmp/testes_ingestao}"
CONTAINER_APP_NAME="${CONTAINER_APP_NAME:-app_submissao_test}"
DOCKER_NETWORK="${DOCKER_NETWORK:-}"
DATA_VOLUME="${DATA_VOLUME:-}"
BUILD_TIMEOUT_SEC="${BUILD_TIMEOUT_SEC:-900}"
BUILD_CPU_LIMIT="${BUILD_CPU_LIMIT:-1.0}"
BUILD_MEM_LIMIT="${BUILD_MEM_LIMIT:-1g}"

if [[ -f "${JUIZ_CONFIG:-$JUIZ_DIR/config.env}" ]]; then
    # shellcheck disable=SC1091
    set -a && source "${JUIZ_CONFIG:-$JUIZ_DIR/config.env}" && set +a
fi

# shellcheck disable=SC1091
source "$SCRIPT_DIR/scripts/lib/estimate-timeout.sh"
PIPELINE_TIMEOUT_SEC="$(resolve_pipeline_timeout)"

# ------------------------------------------------------------------------------
# Logs
# ------------------------------------------------------------------------------
log_info()  { echo -e "[\033[1;34mINFO\033[0m]    $(date +'%H:%M:%S') - $*"; }
log_ok()    { echo -e "[\033[1;32mOK\033[0m]      $(date +'%H:%M:%S') - $*"; }
log_warn()  { echo -e "[\033[1;33mALERTA\033[0m] $(date +'%H:%M:%S') - $*"; }
log_error() { echo -e "[\033[1;31mERRO\033[0m]    $(date +'%H:%M:%S') - $*"; }

# ------------------------------------------------------------------------------
# Juiz Python
# ------------------------------------------------------------------------------
run_juiz() {
    python3 "$JUIZ_DIR/validar.py" "$@"
}

juiz_registrar() {
    local participante="$1" status="$2" repositorio="${3:-}"
    local args=(registrar --participante "$participante" --status "$status")
    [[ -n "$repositorio" ]] && args+=(--repositorio "$repositorio")
    run_juiz "${args[@]}" || log_warn "Falha ao registrar status $status no ranking"
}

parse_mem_mb() {
    local raw="$1" num unit
    num=$(echo "$raw" | grep -oE '^[0-9.]+' || echo "0")
    unit=$(echo "$raw" | grep -oE '[A-Za-z]+$' || echo "B")
    case "$unit" in
        GiB) awk "BEGIN {printf \"%.2f\", $num * 1024}" ;;
        MiB) awk "BEGIN {printf \"%.2f\", $num}" ;;
        KiB) awk "BEGIN {printf \"%.2f\", $num / 1024}" ;;
        *)   echo "0" ;;
    esac
}

track_peak_ram() {
    local container="$1" peak_file="$2"
    echo "0" > "$peak_file"

    # Aguarda o container aparecer (build pode demorar)
    local waited=0
    while ! docker ps -q -f "name=^${container}$" 2>/dev/null | grep -q .; do
        sleep 0.5
        waited=$((waited + 1))
        [[ $waited -ge 120 ]] && return
    done

    while docker ps -q -f "name=^${container}$" 2>/dev/null | grep -q .; do
        local raw mb current peak
        raw=$(docker stats --no-stream --format '{{.MemUsage}}' "$container" 2>/dev/null | awk '{print $1}')
        mb=$(parse_mem_mb "$raw")
        current=$(cat "$peak_file")
        peak=$(awk "BEGIN {print ($mb > $current) ? $mb : $current}")
        echo "$peak" > "$peak_file"
        sleep 1
    done
}

# ------------------------------------------------------------------------------
# Diagnóstico inicial
# ------------------------------------------------------------------------------
echo -e "\n================================================="
echo "  DIAGNÓSTICO — SERVIDOR DE AVALIAÇÃO"
echo -e "=================================================\n"

for cmd in jq git docker python3; do
    command -v "$cmd" &>/dev/null || { log_error "Dependência ausente: $cmd"; exit 1; }
done

docker info &>/dev/null || { log_error "Docker não está operacional"; exit 1; }
docker ps --format '{{.Names}}' | grep -q "^${PG_CONTAINER}$" \
    || { log_error "Container PostgreSQL '$PG_CONTAINER' não está rodando"; exit 1; }

log_ok "Ambiente pronto (docker, postgres, python3)"
log_info "Orquestrador leve — recursos reservados para o container do participante"
print_timeout_estimate | while IFS= read -r line; do log_info "$line"; done

# ------------------------------------------------------------------------------
# JSON de submissão (Gate G0 — parcial no bash)
# ------------------------------------------------------------------------------
[[ -n "$JSON_FILE" ]] || { log_error "Uso: ./avaliador.sh submissoes/nome.json"; exit 1; }
[[ -f "$JSON_FILE" ]] || { log_error "Arquivo não encontrado: $JSON_FILE"; exit 1; }

jq empty "$JSON_FILE" 2>/dev/null || { log_error "JSON inválido: $JSON_FILE"; exit 1; }

PARTICIPANTE=$(jq -r '.participante // empty' "$JSON_FILE")
REPO_URL=$(jq -r '.repositorio // empty' "$JSON_FILE")
echo "participante=$PARTICIPANTE" >> "$RUN_LOG_META"
echo "repositorio=$REPO_URL" >> "$RUN_LOG_META"

[[ -n "$PARTICIPANTE" && -n "$REPO_URL" ]] \
    || { log_error "JSON precisa de 'participante' e 'repositorio'"; exit 1; }

PG_TABLE="${PARTICIPANTE}_empresas"

echo -e "\n================================================="
echo "  PARTICIPANTE: $PARTICIPANTE"
echo "  REPOSITÓRIO:  $REPO_URL"
echo "  TABELA:       public.$PG_TABLE"
echo -e "=================================================\n"

# ------------------------------------------------------------------------------
# Gate G1 — Preflight (juiz)
# ------------------------------------------------------------------------------
log_info "Preflight (Postgres db_empresas)..."
if ! run_juiz preflight --participante "$PARTICIPANTE"; then
    juiz_registrar "$PARTICIPANTE" "ERRO_PREFLIGHT_PG" "$REPO_URL"
    exit 1
fi
log_ok "Preflight aprovado"

# ------------------------------------------------------------------------------
# Clone + Dockerfile (Gate G0)
# ------------------------------------------------------------------------------
DIR_PARTICIPANTE="$DIR_TESTES/$PARTICIPANTE"
rm -rf "$DIR_PARTICIPANTE" && mkdir -p "$DIR_PARTICIPANTE"

log_info "Clonando repositório..."
if ! git clone --depth 1 "$REPO_URL" "$DIR_PARTICIPANTE"; then
    juiz_registrar "$PARTICIPANTE" "ERRO_CLONE_GIT" "$REPO_URL"
    exit 1
fi

COMMIT_SHA=$(git -C "$DIR_PARTICIPANTE" rev-parse HEAD 2>/dev/null || echo "")

[[ -f "$DIR_PARTICIPANTE/Dockerfile" ]] || {
    juiz_registrar "$PARTICIPANTE" "DOCKERFILE_AUSENTE" "$REPO_URL"
    exit 1
}

# ------------------------------------------------------------------------------
# Build (Gate G0)
# ------------------------------------------------------------------------------
NOME_IMAGEM="submissao_${PARTICIPANTE}"
log_info "Build Docker ($NOME_IMAGEM, timeout ${BUILD_TIMEOUT_SEC}s)..."
BUILD_LIMIT_ARGS=()
if docker build --help 2>&1 | grep -q -- '--cpus'; then
    BUILD_LIMIT_ARGS=(--cpus="$BUILD_CPU_LIMIT" --memory="$BUILD_MEM_LIMIT")
    log_info "Build limitado a ${BUILD_CPU_LIMIT} CPU / ${BUILD_MEM_LIMIT}"
fi
set +e
timeout "$BUILD_TIMEOUT_SEC" docker build "${BUILD_LIMIT_ARGS[@]}" -t "$NOME_IMAGEM" "$DIR_PARTICIPANTE"
BUILD_EXIT=$?
set -e
if [[ $BUILD_EXIT -eq 124 ]]; then
    juiz_registrar "$PARTICIPANTE" "ERRO_BUILD_TIMEOUT" "$REPO_URL"
    exit 1
elif [[ $BUILD_EXIT -ne 0 ]]; then
    juiz_registrar "$PARTICIPANTE" "ERRO_BUILD_DOCKER" "$REPO_URL"
    exit 1
fi
log_ok "Imagem construída"

# ------------------------------------------------------------------------------
# Execução (Gate G2 — orquestração no bash, validação no juiz)
# ------------------------------------------------------------------------------
docker rm -f "$CONTAINER_APP_NAME" &>/dev/null || true

DOCKER_ARGS=(
    --name "$CONTAINER_APP_NAME"
    --cpus="2.0"
    --memory="2g"
    --memory-swap="2g"
    --pids-limit=512
    -e "PARTICIPANTE=$PARTICIPANTE"
    -e "PG_TABLE=$PG_TABLE"
    -e "PG_HOST=${PG_HOST:-postgres_db}"
    -e "PG_PORT=${PG_PORT:-5432}"
    -e "PG_USER=${PG_USER:-homelab_postgres}"
    -e "PG_PASSWORD=${PG_PASSWORD:-}"
    -e "PG_DB=${PG_DB_EMPRESAS:-db_empresas}"
    -e "S3_ENDPOINT=${MINIO_ENDPOINT:-http://minio:9000}"
    -e "AWS_ACCESS_KEY_ID=${MINIO_ACCESS_KEY:-admin}"
    -e "AWS_SECRET_ACCESS_KEY=${MINIO_SECRET_KEY:-minio_password}"
    -e "MINIO_BUCKET=${MINIO_BUCKET:-marketing-leads}"
    -e "POLARS_SKIP_CPU_CHECK=1"
)

[[ -n "$DOCKER_NETWORK" ]] && DOCKER_ARGS+=(--network "$DOCKER_NETWORK")
[[ -n "$DATA_VOLUME" ]] && DOCKER_ARGS+=(-v "$DATA_VOLUME")

PEAK_RAM_FILE=$(mktemp)
START_TIME=$(date +%s.%N)
EXIT_CODE=0
TIMED_OUT=false

log_info "Executando pipeline (timeout $(format_timeout_human "$PIPELINE_TIMEOUT_SEC"), 2 CPU, 2 GB RAM, sem swap)..."

track_peak_ram "$CONTAINER_APP_NAME" "$PEAK_RAM_FILE" &
TRACKER_PID=$!

set +e
timeout "$PIPELINE_TIMEOUT_SEC" docker run "${DOCKER_ARGS[@]}" "$NOME_IMAGEM"
EXIT_CODE=$?
set -e

[[ $EXIT_CODE -eq 124 ]] && TIMED_OUT=true

sleep 1
kill "$TRACKER_PID" 2>/dev/null || true
wait "$TRACKER_PID" 2>/dev/null || true

END_TIME=$(date +%s.%N)
DURATION_SEC=$(awk "BEGIN {printf \"%.3f\", $END_TIME - $START_TIME}")
PEAK_RAM_MB=$(tr ',' '.' < "$PEAK_RAM_FILE")
rm -f "$PEAK_RAM_FILE"

log_info "Execução finalizada — exit=$EXIT_CODE tempo=${DURATION_SEC}s pico_ram=${PEAK_RAM_MB}MB"

# ------------------------------------------------------------------------------
# Limpeza Docker
# ------------------------------------------------------------------------------
docker rm -f "$CONTAINER_APP_NAME" &>/dev/null || true
docker rmi -f "$NOME_IMAGEM" &>/dev/null || true

# ------------------------------------------------------------------------------
# Gates G2–G4 + métricas + ranking (juiz)
# ------------------------------------------------------------------------------
JUIZ_ARGS=(
    avaliar
    --participante "$PARTICIPANTE"
    --repositorio "$REPO_URL"
    --tempo "$DURATION_SEC"
    --exit-code "$EXIT_CODE"
    --peak-ram-mb "$PEAK_RAM_MB"
    --timed-out "$TIMED_OUT"
)
[[ -n "$COMMIT_SHA" ]] && JUIZ_ARGS+=(--commit-sha "$COMMIT_SHA")
[[ -n "${PR_NUMERO:-}" ]] && JUIZ_ARGS+=(--pr-numero "$PR_NUMERO")

log_info "Juiz automático validando gates e gravando ranking..."
set +e
run_juiz "${JUIZ_ARGS[@]}"
JUIZ_EXIT=$?
set -e

echo -e "\n================================================="
if [[ $JUIZ_EXIT -eq 0 ]]; then
    echo "  AVALIAÇÃO CONCLUÍDA — CLASSIFICADO"
else
    echo "  AVALIAÇÃO CONCLUÍDA — NÃO CLASSIFICADO"
fi
echo -e "=================================================\n"

exit $JUIZ_EXIT
