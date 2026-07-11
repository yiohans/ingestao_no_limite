FROM python:3.11-slim

WORKDIR /app

# Instala dependências necessárias
RUN pip install --no-cache-dir polars pyarrow deltalake

COPY main.py .

CMD ["python", "main.py"]
