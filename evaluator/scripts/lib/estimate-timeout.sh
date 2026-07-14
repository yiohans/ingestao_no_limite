#!/bin/bash
# Perfil do dataset oficial e budget do pipeline.
#
# Filosofia (competição "no limite"): o timeout NÃO é dimensionado para caber
# com folga. É um ORÇAMENTO FIXO e apertado. Cabe ao participante fazer o
# cálculo de engenharia — "meu design sustenta o throughput exigido dentro de
# 1 GB de RAM?" — antes de submeter.
#
# Uso (após carregar evaluator/judge/config.env):
#   source scripts/lib/estimate-timeout.sh
#   resolve_pipeline_timeout      # segundos (orçamento fixo)
#   required_throughput           # linhas/s exigidas para caber no orçamento
#   print_timeout_estimate        # log legível
#
# Perfil real (medido por evaluator/scripts/profile_empresas.py):
#   10 zips, ~1,26 GB comprimidos → ~5,0 GB descompactados (4,0x)
#   Empresas0: 28.175.408 linhas (~2,1 GB) + 9 arquivos de 4.494.860 linhas
#   total: 68.629.148 linhas, 7 colunas de origem + 3 derivadas
#   após filtros B2B: ~25.031.418 registros na tabela final
: "${DATA_ZIP_COUNT:=10}"
: "${DATA_COMPRESSED_MB:=1290}"
: "${DATA_LINES_FILE1:=28175408}"
: "${DATA_LINES_OTHERS_EACH:=4494860}"
: "${DATA_FILES_OTHERS:=9}"
: "${DATA_SOURCE_COLUMNS:=7}"
: "${DATA_DERIVED_COLUMNS:=3}"
: "${DATA_UNCOMPRESSED_MB:=5112}"
: "${DATA_FINAL_ROWS_EST:=25031418}"

# Orçamento fixo e limites de hardware (restritivos por design).
: "${PIPELINE_TIMEOUT_SEC:=3600}"     # 60 min — hard cap
: "${PIPELINE_CPU_LIMIT:=2.0}"
: "${PIPELINE_MEM_LIMIT:=1g}"

# Piso de throughput apenas como fallback caso PIPELINE_TIMEOUT_SEC não exista.
: "${PIPELINE_ROWS_PER_SEC_FLOOR:=19000}"
: "${PIPELINE_TIMEOUT_MARGIN_PCT:=0}"
: "${PIPELINE_TIMEOUT_ROUND_SEC:=60}"

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

# Fallback: timeout derivado do piso de throughput (só se não houver cap fixo).
compute_pipeline_timeout() {
    local total_lines by_rows rounded
    total_lines="$(compute_total_lines)"
    by_rows=$(awk -v lines="$total_lines" -v rps="$PIPELINE_ROWS_PER_SEC_FLOOR" \
        'BEGIN {printf "%.0f", lines / rps}')
    by_rows=$(awk -v b="$by_rows" -v m="$PIPELINE_TIMEOUT_MARGIN_PCT" \
        'BEGIN {printf "%.0f", b * (1 + m / 100)}')
    rounded=$(awk -v t="$by_rows" -v round="$PIPELINE_TIMEOUT_ROUND_SEC" \
        'BEGIN {printf "%.0f", int((t + round - 1) / round) * round}')
    echo "$rounded"
}

# Throughput (linhas/s) exigido para processar todo o dataset no orçamento.
required_throughput() {
    local total_lines budget
    total_lines="$(compute_total_lines)"
    budget="$(resolve_pipeline_timeout)"
    awk -v lines="$total_lines" -v t="$budget" 'BEGIN {printf "%.0f", lines / t}'
}

resolve_pipeline_timeout() {
    if [[ -n "${PIPELINE_TIMEOUT_SEC:-}" ]]; then
        echo "$PIPELINE_TIMEOUT_SEC"
        return
    fi
    compute_pipeline_timeout
}

print_timeout_estimate() {
    local budget human total_lines lines_label rps_label final_label
    budget="$(resolve_pipeline_timeout)"
    human="$(format_timeout_human "$budget")"
    total_lines="$(compute_total_lines)"
    lines_label="$(format_number "$total_lines")"
    rps_label="$(format_number "$(required_throughput)")"
    final_label="$(format_number "$DATA_FINAL_ROWS_EST")"

    cat <<EOF
Perfil do dataset e orçamento do pipeline:
  zips: ${DATA_ZIP_COUNT} (~${DATA_COMPRESSED_MB} MB comprimidos, ~${DATA_UNCOMPRESSED_MB} MB descompactados)
  linhas: arquivo 1 ~$(format_number "$DATA_LINES_FILE1") + ${DATA_FILES_OTHERS}×$(format_number "$DATA_LINES_OTHERS_EACH") = ~${lines_label} a processar
  colunas: ${DATA_SOURCE_COLUMNS} origem + ${DATA_DERIVED_COLUMNS} derivadas (regras de negócio)
  tabela final estimada (pós-filtros B2B): ~${final_label} registros
  hardware: ${PIPELINE_CPU_LIMIT} CPU / ${PIPELINE_MEM_LIMIT} RAM (sem swap)
  orçamento (hard cap): ${human}
  throughput EXIGIDO: ~${rps_label} linhas/s sustentado (ler+transformar+filtrar+gravar)
EOF
}
