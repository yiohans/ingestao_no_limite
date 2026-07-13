#!/bin/bash
# Smoke test — valida toolchain, juiz, workflow e (opcional) avaliador.sh ponta a ponta.
#
# Uso:
#   ./scripts/smoke-test.sh           # juiz + infra (rápido)
#   ./scripts/smoke-test.sh --full    # inclui avaliador.sh com clone local
#   ./scripts/smoke-test.sh --no-seed # pula seed (tabela já existe)
set -eo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JUIZ_DIR="$ROOT/juiz"
PARTICIPANTE="${SMOKE_PARTICIPANTE:-smoke_test}"
RUN_FULL=false
RUN_SEED=true

for arg in "$@"; do
    case "$arg" in
        --full) RUN_FULL=true ;;
        --no-seed) RUN_SEED=false ;;
        -h|--help)
            sed -n '2,6p' "$0"
            exit 0
            ;;
        *) echo "Argumento desconhecido: $arg" >&2; exit 1 ;;
    esac
done

PASS=0
FAIL=0
SKIP=0
SMOKE_ENV=""
SMOKE_JSON=""
VENV_DIR="$ROOT/.venv-smoke"

log()  { echo -e "[smoke] $*"; }
pass() { PASS=$((PASS + 1)); log "✅ $*"; }
fail() { FAIL=$((FAIL + 1)); log "❌ $*"; }
skip() { SKIP=$((SKIP + 1)); log "⏭️  $*"; }

cleanup() {
    [[ -n "$SMOKE_ENV" && -f "$SMOKE_ENV" ]] && rm -f "$SMOKE_ENV"
    [[ -n "$SMOKE_JSON" && -f "$SMOKE_JSON" ]] && rm -f "$SMOKE_JSON"
}
trap cleanup EXIT

run_step() {
    local title="$1"
    shift
    log ""
    log "── $title"
    if "$@"; then
        pass "$title"
        return 0
    fi
    fail "$title"
    return 1
}

require_cmd() {
    command -v "$1" &>/dev/null
}

check_toolchain() {
    local missing=0
    for cmd in jq git docker python3; do
        require_cmd "$cmd" || { log "   ausente: $cmd"; missing=1; }
    done
    [[ $missing -eq 0 ]]
}

check_python_deps() {
    "$VENV_DIR/bin/python" - <<'PY'
import importlib
for mod in ("psycopg2", "boto3"):
    importlib.import_module(mod)
PY
}

ensure_venv() {
    if [[ ! -x "$VENV_DIR/bin/python" ]]; then
        log "   criando venv em $VENV_DIR..."
        python3 -m venv "$VENV_DIR"
    fi
    "$VENV_DIR/bin/pip" install -q -r "$JUIZ_DIR/requirements.txt"
}

python_juiz() {
    ensure_venv
    JUIZ_CONFIG="$SMOKE_ENV" "$VENV_DIR/bin/python" "$JUIZ_DIR/validar.py" "$@"
}

check_repo_layout() {
    local missing=0
    for f in avaliador.sh juiz/validar.py juiz/requirements.txt \
             .github/workflows/teste.yml Dockerfile; do
        [[ -f "$ROOT/$f" ]] || { log "   ausente: $f"; missing=1; }
    done
    [[ $missing -eq 0 ]]
}

check_sql_layout() {
    local sql_base="${JUIZ_SQL_DIR:-$JUIZ_DIR/sql}"
    local missing=0
    for f in gates/dq-01_cnpj_basico.sql gates/dq-08_mei_cpf.sql \
             metrics/table_exists.sql metrics/row_count.sql \
             schema/ranking_ingestao.sql dev/seed_participante.sql; do
        [[ -f "$sql_base/$f" ]] || { log "   ausente: $sql_base/$f"; missing=1; }
    done
    [[ $missing -eq 0 ]]
}

check_workflow_yaml() {
    local wf="$ROOT/.github/workflows/teste.yml"
    grep -q "pull_request:" "$wf" \
        && grep -q "submissoes/\*\.json" "$wf" \
        && grep -q "avaliador.sh" "$wf" \
        && grep -q "self-hosted" "$wf"
}

check_submission_json() {
    local json="$ROOT/submissoes/dev_python.json"
    jq -e '.participante and .repositorio' "$json" >/dev/null
}

prepare_smoke_env() {
    local base_cfg="$JUIZ_DIR/config.env"
    [[ -f "$base_cfg" ]] || base_cfg="$JUIZ_DIR/config.env.example"

    SMOKE_ENV="$(mktemp)"
    {
        echo "# gerado por scripts/smoke-test.sh"
        echo "JUIZ_SQL_DIR=$JUIZ_DIR/sql"
        echo "VOLUME_MIN=1"
        echo "VOLUME_MAX=100"
        grep -v -E '^(JUIZ_SQL_DIR|VOLUME_MIN|VOLUME_MAX)=' "$base_cfg" \
            | grep -v '^# gerado por'
    } > "$SMOKE_ENV"

    export JUIZ_CONFIG="$SMOKE_ENV"
    export JUIZ_SQL_DIR="$JUIZ_DIR/sql"
    export VOLUME_MIN=1
    export VOLUME_MAX=100
}

check_postgres_container() {
    local pg_container="${PG_CONTAINER:-postgres_db}"
    docker ps --format '{{.Names}}' | grep -q "^${pg_container}$"
}

check_databases() {
  # shellcheck disable=SC1091
    set -a && source "$SMOKE_ENV" && set +a
    local pg_container="${PG_CONTAINER:-postgres_db}"
    docker exec -e PGPASSWORD="$PG_PASSWORD" "$pg_container" \
        psql -U "$PG_USER" -d "$PG_DB_RANKING" -tAc "SELECT 1" >/dev/null \
        && docker exec -e PGPASSWORD="$PG_PASSWORD" "$pg_container" \
        psql -U "$PG_USER" -d "$PG_DB_EMPRESAS" -tAc "SELECT 1" >/dev/null
}

ensure_schema() {
    chmod +x "$JUIZ_DIR/run-sql.sh"
    JUIZ_CONFIG="$SMOKE_ENV" "$JUIZ_DIR/run-sql.sh" schema >/dev/null
}

check_preflight() {
    python_juiz preflight --participante "$PARTICIPANTE" | grep -q PREFLIGHT_OK
}

seed_participant() {
    JUIZ_CONFIG="$SMOKE_ENV" "$JUIZ_DIR/run-sql.sh" seed "$PARTICIPANTE" >/dev/null
}

check_registrar() {
    python_juiz registrar \
        --participante "$PARTICIPANTE" \
        --status SMOKE_TEST \
        --repositorio "https://github.com/smoke/test" \
        | grep -q REGISTRADO
}

check_avaliar_classificado() {
    local out
    out="$(python_juiz avaliar \
        --participante "$PARTICIPANTE" \
        --repositorio "https://github.com/smoke/test" \
        --tempo 3.0 \
        --exit-code 0 \
        --peak-ram-mb 64 \
        --timed-out false \
        --commit-sha deadbeef \
        --pr-numero 0)"

    echo "$out" | grep -q '"status": "CLASSIFICADO"' \
        && echo "$out" | grep -q '"classificado": true'
}

simulate_workflow_json_pick() {
    local json="$ROOT/submissoes/dev_python.json"
    local picked
    picked="$(echo "$json" | awk '{print $1}')"
    [[ -n "$picked" && -f "$picked" ]]
}

run_avaliador_full() {
    ensure_venv
    SMOKE_JSON="$(mktemp)"
    cat > "$SMOKE_JSON" <<EOF
{
  "participante": "$PARTICIPANTE",
  "repositorio": "file://${ROOT}"
}
EOF

    chmod +x "$ROOT/avaliador.sh"
    JUIZ_CONFIG="$SMOKE_ENV" \
        PR_NUMERO=0 \
        LOG_RUN_SLUG="${PARTICIPANTE}_smoke" \
        CONTAINER_APP_NAME="app_smoke_test" \
        PATH="$VENV_DIR/bin:$PATH" \
        "$ROOT/avaliador.sh" "$SMOKE_JSON"
}

main() {
    local log_slug="smoke_test"
    $RUN_FULL && log_slug="${log_slug}_full"

    # shellcheck disable=SC1091
    source "$ROOT/scripts/lib/log-run.sh"
    log_run_init smoke-test "$log_slug"
    trap 'log_run_finish $?' EXIT

    log "Smoke test — Ingestão no Limite"
    log "Raiz: $ROOT | participante: $PARTICIPANTE"

    run_step "Toolchain (jq, git, docker, python3)" check_toolchain

    if ensure_venv && check_python_deps 2>/dev/null; then
        pass "Dependências Python (venv + psycopg2, boto3)"
    else
        fail "Dependências Python (venv + psycopg2, boto3)"
    fi

    run_step "Layout do repositório" check_repo_layout
    run_step "Layout SQL do juiz" check_sql_layout
    run_step "Workflow teste.yml" check_workflow_yaml
    run_step "JSON de submissão (dev_python)" check_submission_json
    run_step "Simulação de pick do workflow" simulate_workflow_json_pick

    prepare_smoke_env
    pass "Config smoke gerada ($SMOKE_ENV)"

    if check_postgres_container; then
        pass "Container Postgres rodando"
    else
        fail "Container Postgres rodando"
        log ""
        log "Resumo: $PASS ok, $FAIL falha(s), $SKIP pulado(s)"
        exit 1
    fi

    run_step "Conexão aos bancos db_ingestao e db_empresas" check_databases
    run_step "Schema ranking (idempotente)" ensure_schema
    run_step "Preflight do juiz" check_preflight

    if $RUN_SEED; then
        run_step "Seed da tabela ${PARTICIPANTE}_empresas" seed_participant
    else
        skip "Seed da tabela ( --no-seed )"
    fi

    run_step "Registrar status no ranking" check_registrar
    run_step "Avaliar gates + CLASSIFICADO (juiz)" check_avaliar_classificado

    if $RUN_FULL; then
        if $RUN_SEED; then
            seed_participant >/dev/null 2>&1 || true
        fi
        log ""
        log "── Avaliador ponta a ponta (--full)"
        if run_avaliador_full; then
            pass "Avaliador ponta a ponta (--full)"
        else
            fail "Avaliador ponta a ponta (--full)"
        fi
    else
        skip "Avaliador ponta a ponta (use --full)"
    fi

    log ""
    if [[ $FAIL -eq 0 ]]; then
        log "🎉 Smoke test OK — $PASS passou, $SKIP pulado(s)"
        exit 0
    fi

    log "💥 Smoke test FALHOU — $PASS ok, $FAIL falha(s), $SKIP pulado(s)"
    exit 1
}

main "$@"
