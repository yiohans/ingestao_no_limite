# 📄 Regras de Negócio e Contrato de Dados

Para sua submissão ser **classificada**, a tabela final no PostgreSQL deve cumprir rigorosamente o schema abaixo e **zerar todas as métricas de erro** do Juiz Automático.

As queries executadas pelo juiz estão em [`evaluator/judge/sql/gates/`](../evaluator/judge/sql/gates/) e [`evaluator/judge/sql/metrics/`](../evaluator/judge/sql/metrics/).

---

## 1. Origem dos Dados

* Diretório de dados brutos no container: `/data/`
* **10 arquivos** compactados (`.zip`) — `Empresas0.zip` … `Empresas9.zip` (~1,26 GB comprimidos, ~5,0 GB descompactados)
* Um arquivo interno `.EMPRECSV` por `.zip` (ex: `K3241.K03200Y1.D60613.EMPRECSV`)
* Codificação original: `ISO-8859-1` (Latin-1) ➔ deve ser convertido para `UTF-8`
* Separador: `;` (ponto e vírgula) com aspas duplas `"`. **Sem cabeçalho**
* **68.629.148 linhas** no total (1 arquivo de ~28,2M + 9 de ~4,5M)

> ⚠️ **Cuidado com parsing ingênuo.** O perfil medido em [`PERFIL_DATASET.md`](./PERFIL_DATASET.md) mostra **323 linhas com `;` dentro de campos entre aspas** e **6.933 linhas com bytes não-ASCII**. Um `split(";")` cru **quebra** essas linhas, e ler como UTF-8/ASCII **corrompe** acentos. Use um parser CSV que respeite aspas + decodifique `ISO-8859-1`.

---

## 2. Destino Final (Obrigatório)

| Item | Valor |
| :--- | :--- |
| Banco | `db_empresas` |
| Schema | `public` |
| Tabela | `{participante}_empresas` |
| Exemplo | participante `renan_python` → `public.renan_python_empresas` |
| Hífen no ID | Permitido (ex.: `dataforma-hub`). Ao criar a tabela no SQL/client, use identificador entre aspas: `public."dataforma-hub_empresas"` — senão o Postgres interpreta `-` como minus. |

A tabela deve existir e estar populada ao final da execução do container.

### Uso opcional de object storage S3-compatível

Você pode usar storage S3-compatível (na avaliação: MinIO dockerizado como alvo de laboratório) livremente para staging ou formatos intermediários (Parquet, Delta Lake, Iceberg), desde que:

* Use apenas o prefixo `s3://marketing-leads/{participante}/`
* A tabela final em Postgres permaneça a **fonte de verdade** para validação e BI
* Projete o código contra a **API S3 genérica** — não acople à marca MinIO; em produção, escolha o backend S3 que fizer sentido para o seu contexto (ver [licença e alternativas](./STACK_E_LIMITES.md#-object-storage-s3-compatível-opcional))

---

## 3. Schema da Tabela Final

| Coluna | Tipo Postgres | Regra de Transformação |
| :--- | :--- | :--- |
| `cnpj_basico` | `VARCHAR(8)` | Exatamente 8 dígitos numéricos com zeros à esquerda |
| `razao_social` | `VARCHAR` | Uppercase, sem espaços nas extremidades |
| `natureza_juridica` | `VARCHAR(4)` | Código numérico de 4 dígitos |
| `qualificacao_responsavel` | `VARCHAR` | Código de qualificação (NOT NULL) |
| `capital_social` | `DOUBLE PRECISION` | Vírgula BR → ponto (`5000.00`) |
| `porte_codigo` | `VARCHAR(2)` | `"00"`, `"01"`, `"03"` ou `"05"` |
| `porte_descricao` | `VARCHAR` | Mapeamento: `00`→`NÃO INFORMADO`, `01`→`MICRO EMPRESA`, `03`→`EMPRESA DE PEQUENO PORTE`, `05`→`DEMAIS` |
| `ente_federativo` | `VARCHAR` | Strings vazias `""` → `NULL` |

> **Achados reais que exigem tratamento** (ver [`PERFIL_DATASET.md`](./PERFIL_DATASET.md)):
> - `porte_codigo`: distribuição real é `01` (75,4%), `05` (21,6%), `03` (3,0%) e **4.063 valores vazios** (`""`). O código `00` **não aparece** no dataset, mas é válido. Normalize o vazio (ex.: `""` → `00`/`NÃO INFORMADO`) para não reprovar em **DQ-06/07**.
> - `capital_social`: **100%** usam vírgula decimal BR (ex.: `5000,00`); ~25,6% valem `0,00`.
> - `ente_federativo`: **99,9%** vazios → viram `NULL`.
> - `razao_social`: casos de espaços nas extremidades, caixa baixa e **1 valor vazio** — trate antes dos gates.

---

## 4. Data Quality (Gates)

Todas as **10 regras** abaixo devem ter **0 erros**. Qualquer valor acima de zero reprova a submissão — não há pontuação parcial.

| Gate | Regra | Tolerância |
| :--- | :--- | :--- |
| DQ-01 | `cnpj_basico` com exatamente 8 dígitos numéricos | **0** |
| DQ-02 | `razao_social` em UPPER e sem espaços nas extremidades | **0** |
| DQ-03 | `natureza_juridica` com exatamente 4 dígitos **numéricos** (`^[0-9]{4}$`) | **0** |
| DQ-04 | `qualificacao_responsavel` preenchido (NOT NULL **e não vazio**) | **0** |
| DQ-05 | `capital_social` maior que `1000.00` e não nulo | **0** |
| DQ-06 | `porte_codigo` em `00`, `01`, `03` ou `05` | **0** |
| DQ-07 | `porte_descricao` **exatamente igual** ao mapeamento de `porte_codigo` (consistência linha a linha) | **0** |
| DQ-08 | `razao_social` não termina com 11 dígitos (CPF de MEI) | **0** |
| DQ-09 | `cnpj_basico` **único** na tabela (`COUNT(*) = COUNT(DISTINCT cnpj_basico)`) | **0** |
| DQ-10 | `razao_social` não vazia e com **encoding correto** (sem caractere de substituição `U+FFFD` nem bytes de controle) | **0** |

**Novidades desta rodada (gates mais rígidos):**

- **DQ-03** agora exige dígitos *numéricos* — `"20A2"` reprova.
- **DQ-07** virou consistência **linha a linha**: mapear `01`→`DEMAIS` (antes passava por estar "no conjunto") agora **reprova**. Cada `porte_codigo` deve casar exatamente com sua `porte_descricao`.
- **DQ-09** (novo): duplicar `cnpj_basico` (carga dupla, join errado, falta de dedup) **reprova**. No dataset oficial as faixas de `cnpj_basico` são contíguas e sem sobreposição — a tabela final deve ser 1 linha por empresa.
- **DQ-10** (novo): ler os bytes `ISO-8859-1` como UTF-8/ASCII gera `�` (U+FFFD) ou lixo — agora é **reprovação direta**, além de barrar `razao_social` vazia.

Arquivos SQL por gate: `evaluator/judge/sql/gates/dq-01_*.sql` … `dq-10_*.sql`  
Validação manual de todos: `evaluator/judge/sql/gates/run_all_dq_manual.sql`

---

## 5. Filtros de Negócio B2B

1. **Capital Social Mínimo:** apenas empresas com `capital_social > 1000.00`
2. **Filtro de MEI com CPF:** remover registros onde `razao_social` termina com 11 dígitos numéricos (CPF do titular)

**Impacto medido** (68,6M linhas de entrada):

| Filtro | Linhas removidas | % do total |
| :--- | ---: | ---: |
| `capital_social ≤ 1000` (inclui 17,5M com `0,00`) | 33.716.612 | 49,1% |
| `razao_social` termina em 11 dígitos (MEI/CPF) | 18.907.005 | 27,5% |
| **Sobrevivem aos filtros (tabela final estimada)** | **25.031.418** | **36,5%** |

> Os filtros descartam ~63% das linhas. Você **lê 68,6M** e **grava ~25M** — planeje o pipeline para essa assimetria.

---

## 6. Sanidade de Volume

Os filtros são **determinísticos**: uma solução correta produz **exatamente 25.031.418 registros**. A faixa aceita é **estreita** (±~0,5%) — não há espaço para "quase certo".

| Situação | Faixa | Status |
| :--- | :--- | :--- |
| Zero registros | `total = 0` | `ERRO_TABELA_VAZIA` |
| Abaixo do mínimo | `total < 24.900.000` | `ERRO_POUCOS_REGISTROS` |
| Acima do máximo | `total > 25.150.000` | `ERRO_REGISTROS_DEMAIS` |
| Dentro da faixa | `24,9M ≤ total ≤ 25,15M` | aprovado |

Os limites exatos (`limite_min` = `VOLUME_MIN`, `limite_max` = `VOLUME_MAX`) ficam em `evaluator/judge/config.env` e em `evaluator/judge/sql/metrics/volume_sanity.sql`. Erros comuns que a faixa apertada agora pega:

| Erro de pipeline | Total resultante | Status |
| :--- | ---: | :--- |
| Esqueceu o filtro `capital > 1000` | ~51M | `ERRO_REGISTROS_DEMAIS` |
| Esqueceu o filtro MEI/CPF | ~44M | `ERRO_REGISTROS_DEMAIS` |
| Carga dupla / sem dedup | ~50M | `ERRO_REGISTROS_DEMAIS` (+ DQ-09) |
| Perdeu o arquivo grande (`Empresas0`) | ~12M | `ERRO_POUCOS_REGISTROS` |
| Parser ingênuo perde linhas com `;` em aspas | varia | pode cair fora da faixa |
