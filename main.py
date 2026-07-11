import os
import zipfile
import polars as pl

# Mapeamento do MinIO S3
S3_ENDPOINT = os.getenv("S3_ENDPOINT", "http://localhost:9000")
BUCKET_TARGET = "s3://marketing-leads/silver_empresas"

# Lê arquivos zip em /data/ e grava formato Delta/Parquet
print("--> Iniciando processamento do Template Base...")

# Exemplo de pipeline simples em Polars com leitura em batch
df = pl.read_csv(
    "/data/*.zip",
    separator=";",
    has_header=False,
    encoding="iso-8859-1",
    new_columns=[
        "cnpj_basico", "razao_social", "natureza_juridica", 
        "qualificacao_responsavel", "capital_social", "porte_codigo", "ente_federativo"
    ]
)

# Tratamentos do contrato
df = df.with_columns([
    pl.col("cnpj_basico").cast(pl.Utf8).str.zfill(8),
    pl.col("razao_social").str.to_uppercase().str.strip_chars(),
    pl.col("capital_social").str.replace(",", ".").cast(pl.Float64),
    pl.when(pl.col("porte_codigo") == "00").then(pl.lit("NÃO INFORMADO"))
      .when(pl.col("porte_codigo") == "01").then(pl.lit("MICRO EMPRESA"))
      .when(pl.col("porte_codigo") == "03").then(pl.lit("EMPRESA DE PEQUENO PORTE"))
      .otherwise(pl.lit("DEMAIS")).alias("porte_descricao")
])

# Filtros B2B
df = df.filter(
    (pl.col("capital_social") > 1000.0) & 
    (~pl.col("razao_social").str.contains(r"\d{11}$"))
)

# Gravação S3
storage_options = {
    "aws_access_key_id": "admin",
    "aws_secret_access_key": "minio_password",
    "aws_endpoint_url": S3_ENDPOINT,
    "aws_allow_http": "true",
}

df.write_delta(BUCKET_TARGET, mode="overwrite", storage_options=storage_options)
print("--> Processamento concluído com sucesso!")
