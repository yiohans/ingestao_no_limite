#!/bin/bash
# ==============================================================================
# JUIZ OFICIAL SEGURO - MODELO DE SUBMISSÃO VIA JSON
# ==============================================================================

JSON_FILE=$1 # Ex: submissoes/maria-dataeng.json

if [ ! -f "$JSON_FILE" ]; then
    echo "❌ Arquivo JSON de submissão não encontrado!"
    exit 1
fi

# Extrai o nome e o link do repo usando jq
PARTICIPANTE_TAG=$(jq -r '.participante' "$JSON_FILE")
REPO_URL=$(jq -r '.repositorio' "$JSON_FILE")

echo "================================================="
echo "  AVALIANDO PARTICIPANTE: $PARTICIPANTE_TAG"
echo "  REPOSITÓRIO: $REPO_URL"
echo "================================================="

DIR_TEMP="/tmp/testes_ingestao/$PARTICIPANTE_TAG"
CONTAINER_NAME="teste_ingestao_$PARTICIPANTE_TAG"
DATA_INPUT="/mnt/hd_externo/dados_gov/empresas"
MINIO_OUTPUT_PATH="/home/renan/minio_data/marketing-leads/silver_empresas"

# 1. Limpeza Prévia
rm -rf "$DIR_TEMP" "$MINIO_OUTPUT_PATH"
docker rm -f $CONTAINER_NAME 2>/dev/null

# 2. Clona o código do participante em pasta isolada
echo "--> Clonando o repositório do participante em $DIR_TEMP..."
git clone --depth 1 "$REPO_URL" "$DIR_TEMP"

if [ $? -ne 0 ]; then
    echo "❌ ERRO: Não foi possível clonar o repositório do participante."
    docker exec postgres_db psql -U postgres -c "INSERT INTO ranking_ingestao (github_user, tempo_segundos, tamanho_mb, status) VALUES ('$PARTICIPANTE_TAG', 0, 0, 'ERRO_CLONE_GIT');"
    exit 1
fi

# 3. Build local a partir do código clonado
echo "--> Realizando Build da imagem Docker..."
cd "$DIR_TEMP"
docker build -t "img_$PARTICIPANTE_TAG" .

if [ $? -ne 0 ]; then
    echo "❌ ERRO: Falha no build da imagem Docker do participante."
    docker exec postgres_db psql -U postgres -c "INSERT INTO ranking_ingestao (github_user, tempo_segundos, tamanho_mb, status) VALUES ('$PARTICIPANTE_TAG', 0, 0, 'ERRO_BUILD');"
    rm -rf "$DIR_TEMP"
    exit 1
fi

# 4. Executa o teste com os limites de 2GB de RAM e 2 vCPUs
echo "--> Executando pipeline com restrições rígidas..."
START_TIME=$(date +%s%N)

docker run --name $CONTAINER_NAME \
  --net=host \
  --memory="2g" \
  --cpus="2" \
  -v "$DATA_INPUT":/data:ro \
  "img_$PARTICIPANTE_TAG"

EXIT_CODE=$?
END_TIME=$(date +%s%N)

# 5. Se falhou na execução (OOM)
if [ $EXIT_CODE -ne 0 ]; then
    echo "❌ DESCLASSIFICADO: Execução falhou ou estourou os 2GB de RAM (Exit code: $EXIT_CODE)"
    docker rmi "img_$PARTICIPANTE_TAG" -f 2>/dev/null
    rm -rf "$MINIO_OUTPUT_PATH" "$DIR_TEMP"
    docker exec postgres_db psql -U postgres -c "INSERT INTO ranking_ingestao (github_user, tempo_segundos, tamanho_mb, status) VALUES ('$PARTICIPANTE_TAG', 0, 0, 'ERRO_OOM_EXECUCAO');"
    exit 1
fi

# 6. Métricas e Auditoria via DuckDB
DURATION_SEC=$(echo "scale=3; ($END_TIME - $START_TIME)/1000000000" | bc)
STORAGE_MB=$(du -sm "$MINIO_OUTPUT_PATH" 2>/dev/null | cut -f1)
STORAGE_MB=${STORAGE_MB:-0}

echo "--> Validando regras de qualidade via DuckDB..."

ERROS_TOTAL=$(duckdb -total -noheader -list -c "
INSTALL httpfs;
INSTALL delta;
LOAD httpfs;
LOAD delta;
SET s3_endpoint='localhost:9000';
SET s3_access_key_id='admin';
SET s3_secret_access_key='minio_password';
SET s3_use_ssl=false;
SET s3_url_style='path';

SELECT 
    COALESCE(SUM(CASE WHEN length(cnpj_basico) != 8 OR cnpj_basico NOT SIMILAR TO '^[0-9]{8}$' THEN 1 ELSE 0 END), 0) +
    COALESCE(SUM(CASE WHEN capital_social <= 1000.00 THEN 1 ELSE 0 END), 0) +
    COALESCE(SUM(CASE WHEN razao_social SIMILAR TO '.*[0-9]{11}$' THEN 1 ELSE 0 END), 0) +
    COALESCE(SUM(CASE WHEN porte_descricao NOT IN ('NÃO INFORMADO', 'MICRO EMPRESA', 'EMPRESA DE PEQUENO PORTE', 'DEMAIS') THEN 1 ELSE 0 END), 0)
FROM delta_scan('s3://marketing-leads/silver_empresas');
" 2>/dev/null)

# 7. Limpeza Total dos Dados Temporários
rm -rf "$MINIO_OUTPUT_PATH" "$DIR_TEMP"
docker rmi "img_$PARTICIPANTE_TAG" -f 2>/dev/null
docker rm -f $CONTAINER_NAME 2>/dev/null

# 8. Gravação no Postgres
if [ -z "$ERROS_TOTAL" ] || [ "$ERROS_TOTAL" -gt 0 ]; then
    echo "❌ REPROVADO NO DATA QUALITY: $ERROS_TOTAL erros encontrados no contrato."
    docker exec postgres_db psql -U postgres -c "INSERT INTO ranking_ingestao (github_user, tempo_segundos, tamanho_mb, status) VALUES ('$PARTICIPANTE_TAG', $DURATION_SEC, $STORAGE_MB, 'FALHA_DATA_QUALITY');"
    exit 1
fi

echo "================================================="
echo "  ✅ AVALIAÇÃO CONCLUÍDA COM SUCESSO!"
echo "  - Tempo: $DURATION_SEC s | Storage: $STORAGE_MB MB"
echo "================================================="

docker exec postgres_db psql -U postgres -c "INSERT INTO ranking_ingestao (github_user, tempo_segundos, tamanho_mb, status) VALUES ('$PARTICIPANTE_TAG', $DURATION_SEC, $STORAGE_MB, 'CLASSIFICADO');"
