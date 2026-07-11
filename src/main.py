import time
import sys

def main():
    print("🚀 Iniciando pipeline de ingestão de dados...")
    start_time = time.time()
    
    # Simula um processamento leve de lote de dados
    total_linhas = 1_000_000
    print(f"--> Processando {total_linhas:,} registros em memória...")
    
    # Processamento em lotes seguro para 2 GB de RAM
    soma = sum(i for i in range(total_linhas))
    
    elapsed = time.time() - start_time
    print(f"✅ Ingestão concluída com sucesso! Tempo: {elapsed:.3f}s | Checksum: {soma}")

if __name__ == "__main__":
    main()
