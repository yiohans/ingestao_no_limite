#!/bin/bash
# Estimativa de timeout do pipeline a partir do perfil do dataset oficial.
#
# Uso (após carregar juiz/config.env):
#   source scripts/lib/estimate-timeout.sh
#   compute_pipeline_timeout    # imprime segundos
#   print_timeout_estimate      # log legível

# Dataset oficial:
#   5 zips ~1 GB comprimidos
#   arquivo 1: ~28M linhas (~2 GB descompactado)
#   arquivos 2–5: ~5M linhas cada (~20M linhas, ~1,4 GB)
#   total: ~48M linhas, ~3,5 GB descompactados, 7 colunas origem + 3 derivadas
: "${DATA_ZIP_COUNT:=5}"
: "${DATA_COMPRESSED_MB:=1024}"
: "${DATA_LINES_FILE1:=28000000}"
: "${DATA_LINES_OTHERS_EACH:=5000000}"
: "${DATA_FILES_OTHERS:=4}"
: "${DATA_SOURCE_COLUMNS:=7}"
: "${DATA_DERIVED_COLUMNS:=3}"
: "${DATA_UNCOMPRESSED_MB:=3500}"
: "${PIPELINE_ROWS_PER_SEC_FLOOR:=5000}"
: "${PIPELINE_THROUGHPUT_FLOOR_MBPS:=2.0}"
: "${PIPELINE_TIMEOUT_MARGIN_PCT:=25}"
: "${PIPELINE_TIMEOUT_ROUND_SEC:=300}"

format_timeout_human() {
    local sec="$1"
    awk -v s="$sec" 'BEGIN {
        m = int((s + 59) / 60)
        h = int(m / 60)
        rm = m % 60
        if (h > 0) printf "%dh%02dm (%ds)", h, rm, s
        else printf "%dm (%ds)", m, s
    }'
}

format_number() {
    awk -v n="$1" 'BEGIN {
        if (n >= 1000000) printf "%.1fM", n / 1000000
        else if (n >= 1000) printf "%.0fk", n / 1000
        else printf "%.0f", n
    }'
}

compute_total_lines() {
    awk -v f1="$DATA_LINES_FILE1" -v each="$DATA_LINES_OTHERS_EACH" -v n="$DATA_FILES_OTHERS" \
        'BEGIN {printf "%.0f", f1 + (each * n)}'
}

compute_pipeline_timeout() {
    local total_lines by_rows by_bytes timeout_rows timeout_bytes rounded
    total_lines="$(compute_total_lines)"

    by_rows=$(awk -v lines="$total_lines" -v rps="$PIPELINE_ROWS_PER_SEC_FLOOR" \
        'BEGIN {printf "%.0f", lines / rps}')
    timeout_rows=$(awk -v b="$by_rows" -v m="$PIPELINE_TIMEOUT_MARGIN_PCT" \
        'BEGIN {printf "%.0f", b * (1 + m / 100)}')

    by_bytes=$(awk -v mb="$DATA_UNCOMPRESSED_MB" -v mbps="$PIPELINE_THROUGHPUT_FLOOR_MBPS" \
        'BEGIN {printf "%.0f", mb / mbps}')
    timeout_bytes=$(awk -v b="$by_bytes" -v m="$PIPELINE_TIMEOUT_MARGIN_PCT" \
        'BEGIN {printf "%.0f", b * (1 + m / 100)}')

    timeout=$(awk -v r="$timeout_rows" -v b="$timeout_bytes" \
        'BEGIN {printf "%.0f", (r > b) ? r : b}')
    rounded=$(awk -v t="$timeout" -v round="$PIPELINE_TIMEOUT_ROUND_SEC" \
        'BEGIN {printf "%.0f", int((t + round - 1) / round) * round}')
    echo "$rounded"
}

print_timeout_estimate() {
    local computed human total_lines lines_label rps_label
    computed="$(compute_pipeline_timeout)"
    human="$(format_timeout_human "$computed")"
    total_lines="$(compute_total_lines)"
    lines_label="$(format_number "$total_lines")"
    rps_label="$(format_number "$PIPELINE_ROWS_PER_SEC_FLOOR")"

    cat <<EOF
Estimativa de timeout (dataset oficial):
  zips: ${DATA_ZIP_COUNT} (~${DATA_COMPRESSED_MB} MB comprimidos, ~${DATA_UNCOMPRESSED_MB} MB descompactados)
  linhas: arquivo 1 ~$(format_number "$DATA_LINES_FILE1") + ${DATA_FILES_OTHERS}×$(format_number "$DATA_LINES_OTHERS_EACH") = ~${lines_label} a processar
  colunas: ${DATA_SOURCE_COLUMNS} origem + ${DATA_DERIVED_COLUMNS} derivadas (regras de negócio)
  throughput mínimo assumido: ${rps_label} linhas/s (Celeron, 2 CPU / 2 GB RAM, streaming)
  margem: ${PIPELINE_TIMEOUT_MARGIN_PCT}%
  timeout calculado: ${human}
EOF
}

resolve_pipeline_timeout() {
    if [[ -n "${PIPELINE_TIMEOUT_SEC:-}" ]]; then
        echo "$PIPELINE_TIMEOUT_SEC"
        return
    fi
    compute_pipeline_timeout
}
