import os
import polars as pl

# Mapeamento de variáveis do ambiente
S3_ENDPOINT = os.getenv("S3_ENDPOINT", "http://localhost:9000")
BUCKET_TARGET = "s3://marketing-leads/silver_empresas"

print("--> [STARTER KIT] Pipeline iniciada...")
print("--> DICA: Voce pode alterar este arquivo ou reescrever a solucao em Rust, Go, C++, etc.")

# Esqueleto inicial incompleto (apenas para validar a estrutura do projeto)
# TODO: O participante deve implementar a leitura real dos zips em /data/
df_starter = pl.DataFrame({
    "cnpj_basico": ["00000000"],
    "razao_social": ["EMPRESA TEMPLATE LTDA"],
    "natureza_juridica": ["2062"],
    "qualificacao_responsavel": ["49"],
    "capital_social": [10000.00],
    "porte_codigo": ["05"],
    "porte_descricao": ["DEMAIS"],
    "ente_federativo": [None]
})

storage_options = {
    "aws_access_key_id": "admin",
    "aws_secret_access_key": "minio_password",
    "aws_endpoint_url": S3_ENDPOINT,
    "aws_allow_http": "true",
}

df_starter.write_delta(BUCKET_TARGET, mode="overwrite", storage_options=storage_options)
print("--> Pipeline starter finalizada.")
