# ==============================================================================
# TEMPLATE DE DOCKERFILE - RINHA DE INGESTÃO DE DADOS
# ==============================================================================
# Este é um arquivo de EXEMPLO para soluções em Python.
# Você pode alterar a imagem base, linguagem e dependências, DESDE QUE:
# 1. O Dockerfile fique localizado na RAIZ do seu repositório externo.
# 2. O comando final (ENTRYPOINT ou CMD) execute a ingestão automaticamente.
# ==============================================================================

# 1. Imagem base (Ex: python:3.11-slim, rust:latest, golang:1.22, etc.)
FROM python:3.11-slim

# 2. Diretório de trabalho dentro do container
WORKDIR /app

# 3. Instalação das dependências necessárias para a sua solução
RUN pip install --no-cache-dir polars pyarrow deltalake

# 4. Copia o código-fonte do seu projeto para o container
#    Recomendação: Mantenha seus scripts dentro da pasta src/
COPY src/ ./src/

# 5. Comando que inicia a ingestão de dados ao subir o container
CMD ["python", "src/main.py"]
