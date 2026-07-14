# 🏛️ Arquitetura do Projeto — Ingestão no Limite

Este documento descreve a arquitetura do sistema de avaliação da competição **Ingestão no Limite**: componentes, fluxos, responsabilidades e como uma submissão percorre o pipeline do PR até o ranking.

Documentos relacionados:

| Documento | Conteúdo |
| :--- | :--- |
| [REGRAS_E_CONTRATO.md](./REGRAS_E_CONTRATO.md) | Schema, filtros B2B, data quality |
| [STACK_E_LIMITES.md](./STACK_E_LIMITES.md) | Variáveis de ambiente, limites de hardware |
| [GATES_E_RANKING.md](./GATES_E_RANKING.md) | Gates, status, critérios de ranking |
| [CHECKLIST_PR.md](./CHECKLIST_PR.md) | Checklist para participantes |

---

## 1. Visão geral

A competição separa claramente **dois mundos**:

1. **Mundo do participante** — repositório público com `Dockerfile` e pipeline de ingestão.
2. **Mundo do organizador** — servidor self-hosted (Celeron) que orquestra builds, executa containers isolados e valida resultados.

O repositório `ingestao_no_limite` é o **hub da competição**: recebe submissões via PR, dispara o avaliador e publica resultados no ranking.

```mermaid
flowchart TB
    subgraph GitHub["GitHub"]
        Fork["Fork do participante"]
        PR["PR com submissions/*.json"]
        Action["GitHub Action<br/>teste.yml"]
    end

    subgraph Servidor["Servidor self-hosted (Celeron)"]
        Avaliador["evaluator/evaluator.sh<br/>orquestrador bash"]
        Juiz["evaluator/judge/validar.py<br/>juiz automático"]
        Runner["GitHub Actions Runner"]
    end

    subgraph Infra["Infraestrutura Docker (sempre ativa)"]
        PG["postgres_db<br/>db_empresas + db_ingestao"]
        MinIO["minio<br/>S3 lab (opcional)"]
        Data["/data/*.zip<br/>somente leitura"]
    end

    subgraph Participante["Container do participante (efêmero)"]
        Pipeline["Pipeline de ingestão<br/>2 CPU / 1 GB RAM"]
    end

    RepoSolucao["Repositório da solução<br/>(público)"]

    Fork --> PR
    PR --> Action
    Action --> Runner
    Runner --> Avaliador
    Avaliador -->|"git clone"| RepoSolucao
    Avaliador -->|"docker build + run"| Pipeline
    Avaliador --> Juiz
    Juiz --> PG
    Juiz --> MinIO
    Pipeline -->|"leitura"| Data
    Pipeline -->|"grava tabela final"| PG
    Pipeline -.->|"opcional"| MinIO
    PG -->|"ranking_ingestao"| Juiz
```

---

## 2. Princípios de arquitetura

| Princípio | Como é aplicado |
| :--- | :--- |
| **Orquestrador fino** | `evaluator/evaluator.sh` só clona, builda, roda Docker e delega validação ao juiz |
| **Juiz com regras** | `validar.py` concentra gates SQL, métricas e INSERT no ranking |
| **Isolamento** | Cada submissão roda em container efêmero com limites rígidos de CPU/RAM |
| **Fila única** | Uma avaliação por vez; cooldown de 15 min entre runs |
| **Segredos fora do repo** | SQL dos gates e `config.env` ficam no servidor, não no GitHub público |
| **Fail-fast** | Preflight verifica Postgres antes de clone/build |

---

## 3. Componentes

```mermaid
graph LR
    subgraph Entrada
        JSON["submissions/*.json"]
        WF[".github/workflows/teste.yml"]
    end

    subgraph Orquestracao
        AV["evaluator/evaluator.sh"]
        LOG["evaluator/scripts/lib/log-run.sh"]
        EST["evaluator/scripts/lib/estimate-timeout.sh"]
    end

    subgraph Juiz
        VP["evaluator/judge/validar.py"]
        RS["evaluator/judge/run-sql.sh"]
        SQL["evaluator/judge/sql/<br/>(privado no servidor)"]
    end

    subgraph Manutencao
        SM["evaluator/scripts/smoke-test.sh"]
    end

    subgraph Saida
        RANK["db_ingestao.ranking_ingestao"]
        LOGS["evaluator/logs/avaliador/"]
    end

    JSON --> WF
    WF --> AV
    AV --> LOG
    AV --> EST
    AV --> VP
    VP --> SQL
    RS --> SQL
    VP --> RANK
    AV --> LOGS
    SM -.->|"validação manual"| VP
```

### 3.1 `evaluator/evaluator.sh` — orquestrador

Responsabilidades:

- Validar toolchain (`jq`, `git`, `docker`, `python3`)
- Preparar venv Python do juiz (`evaluator/judge/.venv` — `psycopg2`, `boto3`)
- Verificar se `postgres_db` está rodando
- Ler e validar JSON de submissão
- Chamar preflight do juiz (Gate G1)
- `git clone --depth 1` do repositório do participante
- `docker build` com timeout de 15 min
- `docker run` com 2 CPU / 1 GB RAM (sem swap)
- Medir wall time e pico de RAM via `docker stats`
- Limpar container e imagem após execução
- Delegar gates G2–G4 e ranking ao juiz

**Não faz:** queries de data quality, regras de negócio ou ranking — isso é do juiz.

### 3.2 `evaluator/judge/validar.py` — juiz automático

Três comandos principais:

| Comando | Quando | Função |
| :--- | :--- | :--- |
| `preflight` | Antes do build | Testa conectividade com `db_empresas` |
| `registrar` | Falha antecipada | Grava status de erro no ranking |
| `avaliar` | Após `docker run` | Gates G2–G4, métricas, INSERT ranking |

Dependências Python: `psycopg2-binary`, `boto3` (instaladas automaticamente em `evaluator/judge/.venv` pelo `evaluator/evaluator.sh`).

### 3.3 GitHub Action — `teste.yml`

| Aspecto | Comportamento |
| :--- | :--- |
| Trigger | **Merge** na `main` alterando `submissions/*.json` (`push`) |
| Reavaliação manual | `workflow_dispatch` com caminho do JSON (ex.: `submissions/dataforma-hub.json`) |
| Runner | `self-hosted` (servidor local) |
| Concurrency | `avaliador-ingestao` — fila única, sem cancelar em andamento |
| Cooldown | 15 min (`COOLDOWN_SEC`) após cada avaliação |

### 3.4 Infraestrutura compartilhada

Serviços **sempre ativos** no host (não sobem por submissão):

| Serviço | Container | Bancos / paths |
| :--- | :--- | :--- |
| PostgreSQL | `postgres_db` | `db_empresas` (dados), `db_ingestao` (ranking) |
| MinIO (S3 lab) | `minio` | bucket `marketing-leads` — alvo S3 local para benchmark; não é recomendação de produção |
| Dados brutos | volume montado | `/data/*.zip` (read-only) |

> **Licença:** o MinIO na infra de avaliação é componente interno de laboratório (AGPLv3 + [MinIO Software License](https://docs.min.io/license/) para binários). Participantes devem abstrair a API S3 no código; para produção ou replicação do desafio, use backends S3-compatíveis à escolha de cada time. Detalhes em [STACK_E_LIMITES.md](./STACK_E_LIMITES.md#-object-storage-s3-compatível-opcional).

---

## 4. Rede Docker na avaliação

Todos os containers relevantes compartilham a mesma rede Docker (`DOCKER_NETWORK` em `evaluator/judge/config.env`).

```mermaid
flowchart LR
    subgraph Rede["Rede Docker (homelab_net)"]
        APP["Container participante<br/>app_submissao_test"]
        PG["postgres_db:5432"]
        S3["minio:9000<br/>(S3-compatível)"]
    end

    VOL["Host: /data/*.zip<br/>montado em /data:ro"]

    VOL -->|"volume -v"| APP
    APP -->|"PG_HOST=postgres_db"| PG
    APP -.->|"S3_ENDPOINT=http://minio:9000"| S3

    style APP fill:#e1f5fe
    style PG fill:#f3e5f5
    style S3 fill:#fff3e0
```

Variáveis injetadas no container do participante estão documentadas em [STACK_E_LIMITES.md](./STACK_E_LIMITES.md).

---

## 5. Fluxo de uma submissão (workflow completo)

```mermaid
sequenceDiagram
    autonumber
    actor P as Participante
    participant GH as GitHub
    participant WF as teste.yml
    participant AV as evaluator/evaluator.sh
    participant JZ as validar.py
    participant DK as Docker
    participant PG as PostgreSQL
    participant MN as S3 (MinIO lab)

    P->>GH: Abre PR com submissions/user.json
    P->>GH: Merge na main
    GH->>WF: Dispara Action (push, self-hosted)
    Note over WF: concurrency: fila única

    WF->>WF: Checkout + detecta JSON alterado
    WF->>AV: ./evaluator/evaluator.sh submissions/user.json

    AV->>AV: Diagnóstico (docker, postgres, venv juiz)
    AV->>JZ: preflight --participante user
    JZ->>PG: Testa conexão db_empresas
    JZ-->>AV: PREFLIGHT_OK

    AV->>AV: git clone repositório da solução
    AV->>DK: docker build (timeout 15 min)
    DK-->>AV: imagem submissao_user

    AV->>DK: docker run (2 CPU, 1 GB, timeout 60 min)
    Note over DK: Pipeline do participante
    DK->>DK: Lê /data/*.zip
    DK->>PG: Grava public.user_empresas
    DK-.->MN: Staging opcional (prefixo user/)
    DK-->>AV: exit code + wall time

    AV->>AV: Mede pico RAM, limpa container/imagem
    AV->>JZ: avaliar --tempo --exit-code --peak-ram-mb
    JZ->>PG: Gate execução, volume, DQ-01..10
    JZ->>MN: Métrica storage S3 (prefixo participante)
    JZ->>PG: INSERT ranking_ingestao
    JZ-->>AV: CLASSIFICADO ou ERRO_*

    AV-->>WF: exit code
  WF->>WF: Cooldown 15 min (COOLDOWN_SEC)
    Note over WF: Libera fila para próxima submissão
    WF-->>GH: Job concluído
```

---

## 6. Gates de validação

Gates são **binários**: falhou um = não classificado.

```mermaid
flowchart TD
    Start([Merge na main]) --> G0

    subgraph G0["Gate G0 — Estrutura"]
        G0A{JSON válido?}
        G0B{git clone OK?}
        G0C{Dockerfile na raiz?}
        G0D{docker build OK?}
    end

    G0A -->|não| E0[ERRO_JSON_INVALIDO]
    G0A -->|sim| G0B
    G0B -->|não| E1[ERRO_CLONE_GIT]
    G0B -->|sim| G0C
    G0C -->|não| E2[DOCKERFILE_AUSENTE]
    G0C -->|sim| G0D
    G0D -->|timeout| E3[ERRO_BUILD_TIMEOUT]
    G0D -->|falha| E4[ERRO_BUILD_DOCKER]

    G0D -->|sim| G1

    subgraph G1["Gate G1 — Preflight"]
        G1A{Postgres db_empresas OK?}
    end

    G1A -->|não| E5[ERRO_PREFLIGHT_PG]
    G1A -->|sim| G2

    subgraph G2["Gate G2 — Execução"]
        G2A{OOM? exit 137}
        G2B{Timeout?}
        G2C{exit code 0?}
        G2D{Tabela existe?}
    end

    G2A -->|sim| E6[ERRO_OOM]
    G2B -->|sim| E7[ERRO_TIMEOUT]
    G2C -->|não| E8[ERRO_EXECUCAO]
    G2C -->|sim| G2D
    G2D -->|não| E9[ERRO_TABELA_AUSENTE]

    G2D -->|sim| G3

    subgraph G3["Gate G3 — Volume"]
        G3A{Registros na faixa<br/>24,9M – 25,15M?}
    end

    G3A -->|0| E10[ERRO_TABELA_VAZIA]
    G3A -->|poucos| E11[ERRO_POUCOS_REGISTROS]
    G3A -->|muitos| E12[ERRO_REGISTROS_DEMAIS]
    G3A -->|ok| G4

    subgraph G4["Gate G4 — Data Quality"]
        G4A{DQ-01..10 = 0 erros?}
    end

    G4A -->|não| E13[ERRO_DATA_QUALITY]
    G4A -->|sim| OK([CLASSIFICADO → ranking])
```

| Gate | Responsável | Onde roda |
| :--- | :--- | :--- |
| G0 | `evaluator/evaluator.sh` | Bash + Docker |
| G1 | `validar.py preflight` | Python |
| G2 (execução) | `evaluator/evaluator.sh` + `validar.py` | Bash mede; Python valida |
| G3 (volume) | `validar.py` + SQL | Python |
| G4 (DQ) | `validar.py` + SQL | Python |

---

## 7. Fluxo de dados

```mermaid
flowchart LR
    subgraph Origem
        Z0["Empresas0.zip (~511 MB)<br/>28,2M linhas"]
        Z1["Empresas1..9.zip<br/>~4,5M linhas cada"]
    end

    subgraph Container
        READ["Leitura streaming<br/>ISO-8859-1 → UTF-8"]
        TRANS["Transformação<br/>filtros B2B"]
        LOAD["Carga Postgres"]
    end

    subgraph DestinoObrigatorio["Destino obrigatório"]
        TBL["db_empresas.public.<br/>{participante}_empresas"]
    end

    subgraph DestinoOpcional["Destino opcional"]
        S3P["s3://marketing-leads/<br/>{participante}/"]
    end

    subgraph Validacao
        DQ["10 gates DQ"]
        VOL["Sanidade de volume"]
        MET["Métricas storage + tempo + RAM"]
    end

    subgraph Ranking
        RK["db_ingestao.ranking_ingestao"]
    end

    Z0 & Z1 --> READ
    READ --> TRANS --> LOAD
    LOAD --> TBL
    TRANS -.-> S3P
    TBL --> DQ & VOL
    S3P -.-> MET
    TBL --> MET
    DQ & VOL & MET --> RK
```

**Perfil do dataset oficial (medido — ver [PERFIL_DATASET.md](./PERFIL_DATASET.md)):**

| Métrica | Valor real |
| :--- | :--- |
| Arquivos `.zip` | 10 |
| Tamanho comprimido | ~1,26 GB |
| Total descompactado | **~5,0 GB** (compressão 4,0x) |
| Arquivo 1 (`Empresas0.zip`) — linhas | **28.175.408** (~2,1 GB) |
| Arquivos 2–10 — linhas cada | **4.494.860** cada |
| **Total de linhas a processar** | **68.629.148** |
| Colunas origem + derivadas | **7 + 3** (regras de negócio) |
| Registros finais (após filtros) | **25.031.418** (faixa apertada 24,9M – 25,15M) |

---

## 8. Fila e fairness

O workflow garante que submissões **nunca corram em paralelo** e que haja um intervalo entre elas.

```mermaid
stateDiagram-v2
    [*] --> AguardandoFila: JSON mergeado na main

    AguardandoFila --> EmAvaliacao: Slot livre<br/>(concurrency group)
    EmAvaliacao --> Cooldown: evaluator/evaluator.sh termina<br/>(sucesso ou falha)
    Cooldown --> AguardandoFila: sleep COOLDOWN_SEC<br/>(padrão 15 min)
    AguardandoFila --> EmAvaliacao: Próxima submissão na fila

    note right of EmAvaliacao
        Apenas 1 job ativo
        cancel-in-progress: false
    end note

    note right of Cooldown
        if: always()
        Mantém o slot ocupado
    end note
```

| Regra | Implementação |
| :--- | :--- |
| Fila única | `concurrency.group: avaliador-ingestao` |
| Não cancelar em andamento | `cancel-in-progress: false` |
| Intervalo entre runs | Step `Intervalo de cortesia` com `sleep 900` |
| Configurável | Variável de repo `COOLDOWN_SEC` no GitHub |

---

## 9. Limites de recursos

```mermaid
graph TB
    subgraph Host["Servidor Celeron (host)"]
        subgraph Build["docker build"]
            B_CPU["≤ 1 CPU"]
            B_RAM["≤ 1 GB RAM"]
            B_TIME["timeout 15 min"]
        end

        subgraph Pipeline["docker run (participante)"]
            P_CPU["2 CPU"]
            P_RAM["1 GB RAM"]
            P_SWAP["sem swap<br/>memory-swap=1g"]
            P_TIME["timeout 60 min<br/>~68,6M linhas"]
        end

        subgraph Servicos["Sempre ativos"]
            PG_SVC["postgres_db"]
            MN_SVC["minio<br/>(S3 lab)"]
        end

        subgraph Orquestrador["Leve"]
            AV_SVC["evaluator/evaluator.sh + juiz<br/>< 50 MB RAM"]
        end
    end

    Build --> Pipeline
    style Pipeline fill:#c8e6c9
    style Build fill:#fff9c4
    style Orquestrador fill:#e3f2fd
```

O timeout do pipeline é um **orçamento fixo de 60 min (3600 s)** — restritivo por design. Com **68.629.148 linhas** a processar (28,2M + 9×4,5M), isso exige **~19.000 linhas/s sustentadas** em 2 CPU / 1 GB RAM. O cálculo está em `evaluator/scripts/lib/estimate-timeout.sh`. Detalhes em [STACK_E_LIMITES.md](./STACK_E_LIMITES.md).

---

## 10. Estrutura de diretórios

```
ingestao_no_limite/
├── .github/workflows/
│   └── teste.yml              # CI: dispara avaliação após merge (push + dispatch manual)
├── docs/
│   ├── ARCHITECTURE.md        # Este documento
│   ├── REGRAS_E_CONTRATO.md
│   ├── STACK_E_LIMITES.md
│   ├── GATES_E_RANKING.md
│   └── CHECKLIST_PR.md
├── submissions/
│   └── *.json                 # Metadados (participante + repo + email opcional)
├── submitter/                 # Starter — copiar para o repo do participante
│   ├── Dockerfile
│   ├── requirements.txt
│   ├── participante.json.example
│   └── src/
└── evaluator/                 # Tooling do servidor (organizadores)
    ├── evaluator.sh           # Orquestrador principal
    ├── judge/
    │   ├── validar.py         # Judge automático (gates + ranking)
    │   ├── run-sql.sh         # Executor SQL (organizador)
    │   ├── config.env.example
    │   ├── requirements.txt
    │   └── sql/               # Gates e métricas (privado — .gitignore)
    ├── scripts/
    │   ├── smoke-test.sh
    │   └── lib/
    │       ├── log-run.sh
    │       └── estimate-timeout.sh
    └── logs/                  # Saída de execuções (.gitignore)
        ├── avaliador/
        ├── smoke-test/
        └── run-sql/
```

---

## 11. Separação público vs privado

```mermaid
flowchart TB
    subgraph Publico["Repositório GitHub (público)"]
        Code["evaluator/evaluator.sh, validar.py, docs"]
        Sub["submissions/*.json"]
        WF2["teste.yml"]
    end

    subgraph Privado["Servidor self-hosted (privado)"]
        CFG["/opt/ingestao-juiz/config.env<br/>senhas, paths, rede"]
        SQL2["/opt/ingestao-juiz/sql/<br/>queries dos gates"]
        Data2["/data/*.zip<br/>dataset oficial"]
    end

    WF2 -->|"checkout"| Code
    Code -->|"JUIZ_CONFIG"| CFG
    Code -->|"JUIZ_SQL_DIR"| SQL2
    Code -->|"DATA_VOLUME"| Data2
```

Competidores **não** têm acesso SSH ao servidor. A avaliação roda automaticamente após o merge na `main` (ou via disparo manual do organizador).

---

## 12. Smoke test (organizador)

O `evaluator/scripts/smoke-test.sh` **não** roda automaticamente em cada submissão. É uma ferramenta de manutenção para validar a infra antes de abrir a fila.

```mermaid
flowchart LR
    subgraph Smoke["evaluator/scripts/smoke-test.sh"]
        T["Toolchain"]
        L["Layout repo + SQL"]
        DB["Conexão Postgres"]
        PF["Preflight juiz"]
        SE["Seed + avaliar"]
        FU["--full: evaluator ponta a ponta"]
    end

    T --> L --> DB --> PF --> SE
    SE -.-> FU

    subgraph Quando["Quando usar"]
        W1["Após mudanças no evaluator/"]
        W2["Antes de abrir submissões"]
        W3["Debug de infra quebrada"]
    end
```

Em cada submissão real, apenas o **preflight** do juiz roda antes do build — equivalente ao Gate G1, sem o overhead do smoke completo.

---

## 13. Ranking

Soluções **classificadas** entram no ranking pelo **score composto** (menor vence) — não é mais só velocidade:

```mermaid
flowchart LR
    S["SCORE = 0.60·(tempo/3600)<br/>+ 0.25·(RAM/1024)<br/>+ 0.15·(storage/4096)"]
    A["1º — Menor score"]
    B["Desempate — tempo, storage, RAM"]

    S --> A --> B
```

Recompensa eficiência holística (tempo + RAM + storage). Dados gravados em `db_ingestao.public.ranking_ingestao` (coluna `score`). Detalhes e pesos em [GATES_E_RANKING.md](./GATES_E_RANKING.md). Views para o site: `v_leaderboard`, `v_melhor_por_participante`, `v_ultima_avaliacao`.

---

## 14. Resumo executivo

| Pergunta | Resposta |
| :--- | :--- |
| O que dispara a avaliação? | Merge na `main` (`push` em `submissions/*.json`) ou `workflow_dispatch` manual |
| Quem orquestra? | `evaluator/evaluator.sh` no runner self-hosted |
| Quem valida regras? | `evaluator/judge/validar.py` + SQL privado |
| Onde o participante grava dados? | `db_empresas.public.{participante}_empresas` |
| Quantas avaliações em paralelo? | **1** (fila única) |
| Intervalo entre submissões? | **15 min** de cooldown |
| Limites do container? | 2 CPU, 1 GB RAM, 60 min timeout (~68,6M linhas) |
| O smoke test roda em cada submissão? | **Não** — só preflight + pipeline real |
