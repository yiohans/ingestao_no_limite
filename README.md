# ⚡ Ingestão no Limite: Um desafio para os engenheiros de dados "engenhocar" seus pipelines

Seja bem-vindo ao **Ingestão no Limite**, o desafio de Engenharia de Dados focado em **eficiência extrema, código performático e FinOps**.

*Contexto Narrativo*:

Uma agência de marketing B2B precisa de uma base de dados grande e robusta para criar campanhas automatizadas e conquistar o maior número possível de prospectos. No entanto, a agência não está disponível a investir em máquinas virtuais, clusters Kubernetes ou instâncias no Databricks, pois acredita que não são necessários custos elevados para atingir seus objetivos.

Eles baixaram arquivos de empresas no formato CSV pelo site dados.gov.br. Contudo, não conseguem sequer abrir esses arquivos, pois estão compactados em `.zip`, possuem um formato interno incomum e, além disso, são grandes demais para manipular no Excel.

Diante disso, a agência contratou você para criar um processo de ingestão e tratamento simples desses dados, de forma a permitir melhores consultas utilizando ferramentas de BI, como Tableau, Metabase ou Power BI.

O detalhe importante: o único equipamento disponível é um notebook antigo, que eles acreditam ser suficiente para o serviço.

## 🎯 Objetivo da Competição

Criar o pipeline de ingestão e tratamento dos dados empresariais **mais eficiente possível**, operando sob rigorosas restrições de hardware (máximo de **2 GB de RAM** e **2 CPUs**).

Ao final, seu trabalho deve gerar uma **tabela padronizada e pronta para BI** no PostgreSQL. Você decide a arquitetura: pode usar MinIO/S3 como apoio (staging, Parquet, Delta Lake, Iceberg) ou ir direto ao Postgres — o que importa é **passar nos gates** e **vencer no ranking**.

Ao longo do processo, você deverá manipular múltiplos arquivos `.zip`, converter encodings e tipos de dados, além de aplicar regras rigorosas de qualidade de dados e filtros de negócio B2B — por exemplo, garantir `capital_social > 1000.00` e remover MEIs cujo nome termina com um CPF na razão social.

Todos os critérios serão verificados automaticamente. Apenas soluções que passem em **todos os gates** serão consideradas para o ranking.

Esse desafio testa sua habilidade em otimizar, manipular grandes volumes de dados e desenvolver soluções robustas, criativas e enxutas — uma simulação de cenário real, onde a infraestrutura é fornecida e **você escolhe a melhor abordagem**.

---

## 🏗️ Infraestrutura Fornecida

A competição disponibiliza **duas ferramentas**. Você escolhe como usá-las:

| Serviço | Papel | Obrigatório? |
| :--- | :--- | :--- |
| **PostgreSQL** (`db_empresas`) | Destino final da tabela de negócio para BI | **Sim** — tabela `{participante}_empresas` |
| **MinIO/S3** | Object storage para staging, intermediários ou lake | **Não** — uso opcional a seu critério |

### Entrega obrigatória (finish line)

```
db_empresas.public.{participante}_empresas
```

Onde `{participante}` é exatamente o valor do campo `participante` no seu JSON de submissão (ex.: `renan_python` → `renan_python_empresas`).

---

## 🏆 Como Funciona?

1. **Faça o Fork** deste repositório.
2. **Desenvolva seu código** de ingestão e tratamento no seu repositório público, com `Dockerfile` na raiz.
3. **Abra um Pull Request** contra a branch `main` com seu arquivo em `submissoes/seu_usuario.json`.
4. O servidor local (**Hardware Celeron**) enfileira seu PR, executa **preflight**, roda o pipeline no Docker isolado e coleta métricas.
5. Se passar em **todos os gates**, seu tempo, storage e pico de RAM entram no **Ranking Oficial**.

---

## 📚 Documentação Completa (`/docs`)

Para não travar no contrato de dados ou ser desclassificado por estouro de memória, leia os guias abaixo antes de codar:

* 📄 [**Regras de Negócio e Contrato de Dados**](./docs/REGRAS_E_CONTRATO.md) — Schema, filtros B2B, tipos de dados e encoding.
* 🏛️ [**Arquitetura do Projeto e Workflow**](./docs/ARCHITECTURE.md) — Componentes, fluxos, gates e diagramas.
* 💻 [**Stack do Servidor, Variáveis e Acesso na Avaliação**](./docs/STACK_E_LIMITES.md) — Como o PR conecta ao Postgres/MinIO, env vars e limites de hardware.
* 🚦 [**Gates, Ranking e Juiz Automático**](./docs/GATES_E_RANKING.md) — Gates de aprovação, métricas, timeout, fila e SQL de validação.
* 🐍 [**Juiz (`/juiz`)**](./juiz/README.md) — `validar.py` + SQL compartilhado executado pelo avaliador.
* 📑 [**Checklist Obrigatório para Pull Request**](./docs/CHECKLIST_PR.md) — Requisitos para garantir que seu PR seja avaliado sem erros.

---

## 🏎️ Critérios de Ranking

Entre soluções **classificadas** (todos os gates aprovados), a ordem é:

1. **Menor tempo de execução** (wall time, em segundos)
2. **Desempate:** menor espaço total consumido em storage (MB) — Postgres + MinIO do participante
3. **Segundo desempate:** menor pico de RAM (MB)

> *"Engenharia de dados de verdade não é sobre contratar o maior cluster da nuvem, é sobre escrever código otimizado."*

Detalhes completos em [Gates, Ranking e Juiz Automático](./docs/GATES_E_RANKING.md).

---

## 🚀 Como Submeter sua Solução

### Passo 1: Desenvolva sua solução

1. Crie um **novo repositório público** na sua conta do GitHub para o seu código.
2. Desenvolva na linguagem que desejar (Python, Rust, Go, C++, etc.).
3. **Requisito obrigatório:** `Dockerfile` na **raiz** do repositório que execute a ingestão automaticamente ao iniciar o container.
4. Grave a tabela final em `db_empresas.public.{participante}_empresas` conforme o [contrato de dados](./docs/REGRAS_E_CONTRATO.md).
5. MinIO é opcional; se usar, limite-se ao prefixo `s3://marketing-leads/{participante}/`.

### Passo 2: Envie sua submissão para a Rinha

1. Faça um **Fork** deste repositório (`mpraes/ingestao_no_limite`).
2. No seu fork, crie `submissoes/seu_usuario.json`.
3. Preencha o JSON exatamente com a estrutura abaixo:

```json
{
  "participante": "seu_usuario",
  "repositorio": "https://github.com/seu_usuario/seu-repo-da-solucao"
}
```

---

## ⏱️ Limites Operacionais

Para manter a competição divertida e o servidor saudável:

| Regra | Valor |
| :--- | :--- |
| RAM máxima do container | 2 GB |
| CPUs máximas | 2 |
| Timeout do pipeline | **~90 minutos** (dataset ~10 GB descompactados) |
| Build da imagem | **15 minutos** (separado; não conta no ranking) |
| Avaliações simultâneas | 1 (fila única — nunca em paralelo) |
| Intervalo entre avaliações | **15 minutos** de cooldown (fairness) |
| PRs duplicados | apenas o commit mais recente é avaliado |

Soluções que excederem o timeout ou forem mortas por OOM recebem status de erro e **não entram no ranking**.
