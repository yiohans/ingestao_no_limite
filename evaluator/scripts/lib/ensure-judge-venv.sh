# Shared judge Python venv — source from evaluator.sh / smoke-test.sh
# Creates evaluator/judge/.venv and installs evaluator/judge/requirements.txt

_ensure_judge_venv_paths() {
    if [[ -z "${JUDGE_VENV_DIR:-}" ]]; then
        local _lib_dir
        _lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        JUDGE_VENV_DIR="$(cd "$_lib_dir/../.." && pwd)/judge/.venv"
    fi
    JUDGE_DIR="${JUDGE_DIR:-$(dirname "$JUDGE_VENV_DIR")}"
    JUDGE_REQUIREMENTS="${JUDGE_REQUIREMENTS:-$JUDGE_DIR/requirements.txt}"
}

ensure_judge_venv() {
    _ensure_judge_venv_paths

    if [[ ! -f "$JUDGE_REQUIREMENTS" ]]; then
        echo "ensure_judge_venv: requirements não encontrado: $JUDGE_REQUIREMENTS" >&2
        return 1
    fi

    if [[ ! -x "$JUDGE_VENV_DIR/bin/python" ]]; then
        python3 -m venv "$JUDGE_VENV_DIR" || return 1
    fi

    "$JUDGE_VENV_DIR/bin/pip" install -q -r "$JUDGE_REQUIREMENTS" || return 1
    JUDGE_PYTHON="$JUDGE_VENV_DIR/bin/python"
}

resolve_judge_python() {
    if [[ -n "${JUDGE_PYTHON:-}" && -x "$JUDGE_PYTHON" ]]; then
        return 0
    fi
    ensure_judge_venv
}
