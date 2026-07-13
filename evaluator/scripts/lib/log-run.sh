#!/bin/bash
# Redireciona stdout/stderr para logs/<script>/ e mantém saída no terminal.
#
# Uso:
#   source scripts/lib/log-run.sh
#   log_run_init avaliador "renan_python_pr42"
#   trap 'log_run_finish $?' EXIT

log_run_root() {
    if [[ -n "${LOGS_DIR:-}" ]]; then
        echo "$LOGS_DIR"
        return
    fi
    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    echo "$(cd "$lib_dir/../.." && pwd)/logs"
}

log_run_slugify() {
    echo "$1" | tr -c '[:alnum:]_.-' '_' | sed 's/_*$//'
}

log_run_init() {
    local script_name="${1:?nome do script obrigatório}"
    local slug="${2:-run}"
    slug="$(log_run_slugify "$slug")"

    local ts logs_root
    ts="$(date +'%Y-%m-%d_%H-%M-%S')"
    logs_root="$(log_run_root)"
    RUN_LOG_DIR="$logs_root/$script_name/${ts}_${slug}"
    mkdir -p "$RUN_LOG_DIR"

    RUN_LOG_STDOUT="$RUN_LOG_DIR/stdout.log"
    RUN_LOG_STDERR="$RUN_LOG_DIR/stderr.log"
    RUN_LOG_META="$RUN_LOG_DIR/run.meta"

    {
        echo "script=$script_name"
        echo "slug=$slug"
        echo "started_at=$(date -Iseconds 2>/dev/null || date)"
        echo "pid=$$"
        echo "ppid=$PPID"
        echo "cwd=$(pwd)"
        echo "host=$(hostname 2>/dev/null || echo unknown)"
        echo "user=${USER:-unknown}"
        [[ -n "${PR_NUMERO:-}" ]] && echo "pr_numero=$PR_NUMERO"
        [[ -n "${GITHUB_RUN_ID:-}" ]] && echo "github_run_id=$GITHUB_RUN_ID"
        [[ -n "${GITHUB_RUN_ATTEMPT:-}" ]] && echo "github_run_attempt=$GITHUB_RUN_ATTEMPT"
        [[ -n "${PARTICIPANTE:-}" ]] && echo "participante=$PARTICIPANTE"
        [[ -n "${LOG_RUN_ACTIVE:-}" ]] && echo "parent_log=$LOG_RUN_ACTIVE"
    } > "$RUN_LOG_META"

    # Subprocesso: cria pasta própria, mas ainda grava stdout/stderr
    if [[ -n "${LOG_RUN_ACTIVE:-}" ]]; then
        echo "[log-run] subexec $script_name → $RUN_LOG_DIR"
    else
        export LOG_RUN_ACTIVE="$RUN_LOG_DIR"
        echo "[log-run] stdout → $RUN_LOG_STDOUT"
        echo "[log-run] stderr → $RUN_LOG_STDERR"
    fi

    exec > >(tee -a "$RUN_LOG_STDOUT") 2> >(tee -a "$RUN_LOG_STDERR" >&2)
}

log_run_finish() {
    local exit_code="${1:-$?}"
    [[ -n "${RUN_LOG_META:-}" && -f "$RUN_LOG_META" ]] || return 0
    {
        echo "finished_at=$(date -Iseconds 2>/dev/null || date)"
        echo "exit_code=$exit_code"
    } >> "$RUN_LOG_META"
}
