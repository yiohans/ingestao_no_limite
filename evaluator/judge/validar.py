#!/usr/bin/env python3
"""
Juiz automático — gates, métricas e gravação no ranking.

Uso:
  python3 juiz/validar.py preflight --participante renan_python
  python3 juiz/validar.py registrar --participante renan_python --status ERRO_CLONE_GIT
  python3 juiz/validar.py avaliar --participante renan_python --repositorio URL \\
      --tempo 120.5 --exit-code 0 --peak-ram-mb 512 --timed-out false
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass, field
from decimal import Decimal
from pathlib import Path

import boto3
import psycopg2
from botocore.config import Config as BotoConfig
from botocore.exceptions import BotoCoreError, ClientError
from psycopg2.extras import Json

ROOT = Path(__file__).resolve().parent

PARTICIPANTE_RE = re.compile(r"^[a-zA-Z0-9_-]+$")

GATE_FILES = [
    ("DQ-01", "dq-01_cnpj_basico.sql"),
    ("DQ-02", "dq-02_razao_social.sql"),
    ("DQ-03", "dq-03_natureza_juridica.sql"),
    ("DQ-04", "dq-04_qualificacao_responsavel.sql"),
    ("DQ-05", "dq-05_capital_social.sql"),
    ("DQ-06", "dq-06_porte_codigo.sql"),
    ("DQ-07", "dq-07_porte_descricao.sql"),
    ("DQ-08", "dq-08_mei_cpf.sql"),
]


@dataclass
class Config:
    pg_host: str = "localhost"
    pg_port: int = 5432
    pg_user: str = "homelab_postgres"
    pg_password: str = ""
    pg_db_ranking: str = "db_ingestao"
    pg_db_empresas: str = "db_empresas"
    minio_endpoint: str = "http://localhost:9000"
    minio_access_key: str = "admin"
    minio_secret_key: str = "minio_password"
    minio_bucket: str = "marketing-leads"
    volume_min: int = 500_000
    volume_max: int = 15_000_000
    juiz_sql_dir: str = ""


@dataclass
class AvaliacaoResult:
    participante: str
    repositorio: str | None = None
    tempo_segundos: Decimal = Decimal("0")
    exit_code: int = 1
    peak_ram_mb: Decimal = Decimal("0")
    timed_out: bool = False
    gate_preflight: bool = False
    gate_execucao: bool = False
    gate_volume: bool = False
    gate_dq: bool = False
    gate_dq_detalhes: dict[str, int] = field(default_factory=dict)
    storage_postgres_mb: Decimal = Decimal("0")
    storage_minio_mb: Decimal = Decimal("0")
    total_registros: int = 0
    status: str = "ERRO_EXECUCAO"
    classificado: bool = False
    commit_sha: str | None = None
    pr_numero: int | None = None


def sql_base_dir(cfg: Config) -> Path:
    """Diretório dos SQL do juiz (gates/metrics). Fora do repo em produção."""
    if cfg.juiz_sql_dir:
        return Path(cfg.juiz_sql_dir)
    return ROOT / "sql"


def sql_gates_dir(cfg: Config) -> Path:
    return sql_base_dir(cfg) / "gates"


def sql_metrics_dir(cfg: Config) -> Path:
    return sql_base_dir(cfg) / "metrics"


def load_config() -> Config:
    config_path = Path(os.getenv("JUIZ_CONFIG", str(ROOT / "config.env")))
    if config_path.exists():
        for line in config_path.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            os.environ.setdefault(key.strip(), value.strip())

    return Config(
        pg_host=os.getenv("PG_HOST", "localhost"),
        pg_port=int(os.getenv("PG_PORT", "5432")),
        pg_user=os.getenv("PG_USER", "homelab_postgres"),
        pg_password=os.getenv("PG_PASSWORD", ""),
        pg_db_ranking=os.getenv("PG_DB_RANKING", "db_ingestao"),
        pg_db_empresas=os.getenv("PG_DB_EMPRESAS", "db_empresas"),
        minio_endpoint=os.getenv("MINIO_ENDPOINT", "http://localhost:9000"),
        minio_access_key=os.getenv("MINIO_ACCESS_KEY", "admin"),
        minio_secret_key=os.getenv("MINIO_SECRET_KEY", "minio_password"),
        minio_bucket=os.getenv("MINIO_BUCKET", "marketing-leads"),
        volume_min=int(os.getenv("VOLUME_MIN", "500000")),
        volume_max=int(os.getenv("VOLUME_MAX", "15000000")),
        juiz_sql_dir=os.getenv("JUIZ_SQL_DIR", ""),
    )


def validate_participante(participante: str) -> str:
    if not PARTICIPANTE_RE.match(participante):
        raise ValueError(f"participante inválido: {participante!r}")
    return participante


def table_name(participante: str) -> str:
    return f"{validate_participante(participante)}_empresas"


def table_fqn(participante: str) -> str:
    return f"public.{table_name(participante)}"


def table_regclass(participante: str) -> str:
    return f"'{table_fqn(participante)}'"


def connect(db: str, cfg: Config):
    return psycopg2.connect(
        host=cfg.pg_host,
        port=cfg.pg_port,
        user=cfg.pg_user,
        password=cfg.pg_password,
        dbname=db,
    )


def load_sql(path: Path, participante: str) -> str:
    sql = path.read_text()
    sql = sql.replace("{table}", table_fqn(participante))
    sql = sql.replace("{table_regclass}", table_regclass(participante))
    return sql


def scalar_query(conn, sql: str) -> int | bool | None:
    with conn.cursor() as cur:
        cur.execute(sql)
        row = cur.fetchone()
        return row[0] if row else None


def run_preflight(cfg: Config, participante: str) -> tuple[bool, str]:
    validate_participante(participante)
    try:
        with connect(cfg.pg_db_empresas, cfg) as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT 1")
    except psycopg2.Error as exc:
        return False, f"ERRO_PREFLIGHT_PG: {exc}"

    return True, "OK"


def measure_minio_mb(cfg: Config, participante: str) -> Decimal:
    prefix = f"{participante}/"
    try:
        client = boto3.client(
            "s3",
            endpoint_url=cfg.minio_endpoint,
            aws_access_key_id=cfg.minio_access_key,
            aws_secret_access_key=cfg.minio_secret_key,
            config=BotoConfig(s3={"addressing_style": "path"}),
        )
        paginator = client.get_paginator("list_objects_v2")
        total_bytes = 0
        for page in paginator.paginate(Bucket=cfg.minio_bucket, Prefix=prefix):
            for obj in page.get("Contents", []):
                total_bytes += obj.get("Size", 0)
        return Decimal(total_bytes) / Decimal(1024 * 1024)
    except (BotoCoreError, ClientError, OSError):
        # MinIO opcional — falha de conexão não reprova por si só
        return Decimal("0")


def avaliar_execucao(
    cfg: Config,
    participante: str,
    exit_code: int,
    timed_out: bool,
) -> tuple[str, bool]:
    if timed_out:
        return "ERRO_TIMEOUT", False
    if exit_code == 137:
        return "ERRO_OOM", False
    if exit_code != 0:
        return "ERRO_EXECUCAO", False
    return "OK", True


def avaliar_tabela(conn, cfg: Config, participante: str) -> tuple[str, bool, int]:
    metrics = sql_metrics_dir(cfg)
    existe = scalar_query(conn, load_sql(metrics / "table_exists.sql", participante))
    if not existe:
        return "ERRO_TABELA_AUSENTE", False, 0

    total = int(scalar_query(conn, load_sql(metrics / "row_count.sql", participante)) or 0)
    if total == 0:
        return "ERRO_TABELA_VAZIA", False, total
    if total < cfg.volume_min:
        return "ERRO_POUCOS_REGISTROS", False, total
    if total > cfg.volume_max:
        return "ERRO_REGISTROS_DEMAIS", False, total
    return "OK", True, total


def avaliar_dq(conn, cfg: Config, participante: str) -> tuple[bool, dict[str, int]]:
    gates = sql_gates_dir(cfg)
    detalhes: dict[str, int] = {}
    for gate_id, filename in GATE_FILES:
        erros = int(scalar_query(conn, load_sql(gates / filename, participante)) or 0)
        if erros > 0:
            detalhes[gate_id] = erros
    return len(detalhes) == 0, detalhes


def measure_postgres_mb(conn, cfg: Config, participante: str) -> Decimal:
    bytes_size = int(
        scalar_query(
            conn, load_sql(sql_metrics_dir(cfg) / "storage_postgres.sql", participante)
        )
        or 0
    )
    return Decimal(bytes_size) / Decimal(1024 * 1024)


def insert_result(cfg: Config, result: AvaliacaoResult) -> None:
    with connect(cfg.pg_db_ranking, cfg) as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO ranking_ingestao (
                    github_user, repositorio, tempo_segundos,
                    storage_postgres_mb, storage_minio_mb, peak_ram_mb,
                    total_registros, status, classificado,
                    gate_preflight, gate_execucao, gate_volume, gate_dq,
                    gate_dq_detalhes, commit_sha, pr_numero
                ) VALUES (
                    %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s
                )
                """,
                (
                    result.participante,
                    result.repositorio,
                    result.tempo_segundos,
                    result.storage_postgres_mb,
                    result.storage_minio_mb,
                    result.peak_ram_mb,
                    result.total_registros,
                    result.status,
                    result.classificado,
                    result.gate_preflight,
                    result.gate_execucao,
                    result.gate_volume,
                    result.gate_dq,
                    Json(result.gate_dq_detalhes) if result.gate_dq_detalhes else None,
                    result.commit_sha,
                    result.pr_numero,
                ),
            )
        conn.commit()

    try:
        with connect(cfg.pg_db_ranking, cfg) as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT recalcular_posicoes_ranking()")
            conn.commit()
    except psycopg2.Error as exc:
        print(f"AVISO: recalcular_posicoes_ranking falhou: {exc}", file=sys.stderr)


def cmd_preflight(args: argparse.Namespace) -> int:
    cfg = load_config()
    ok, msg = run_preflight(cfg, args.participante)
    if ok:
        print("PREFLIGHT_OK")
        return 0
    print(msg, file=sys.stderr)
    return 1


def cmd_registrar(args: argparse.Namespace) -> int:
    cfg = load_config()
    result = AvaliacaoResult(
        participante=validate_participante(args.participante),
        repositorio=args.repositorio,
        status=args.status,
        classificado=False,
    )
    insert_result(cfg, result)
    print(f"REGISTRADO: {args.status}")
    return 0


def cmd_avaliar(args: argparse.Namespace) -> int:
    cfg = load_config()
    participante = validate_participante(args.participante)
    timed_out = args.timed_out.lower() in ("true", "1", "yes")

    result = AvaliacaoResult(
        participante=participante,
        repositorio=args.repositorio,
        tempo_segundos=Decimal(str(args.tempo)),
        exit_code=args.exit_code,
        peak_ram_mb=Decimal(str(args.peak_ram_mb)),
        timed_out=timed_out,
        commit_sha=args.commit_sha,
        pr_numero=args.pr_numero,
    )

    preflight_ok, preflight_msg = run_preflight(cfg, participante)
    result.gate_preflight = preflight_ok
    if not preflight_ok:
        result.status = preflight_msg.split(":")[0] if ":" in preflight_msg else "ERRO_PREFLIGHT_PG"
        insert_result(cfg, result)
        print(json.dumps({"status": result.status, "classificado": False}, indent=2))
        return 1

    exec_status, exec_ok = avaliar_execucao(cfg, participante, args.exit_code, timed_out)
    result.gate_execucao = exec_ok
    if not exec_ok:
        result.status = exec_status
        insert_result(cfg, result)
        print(json.dumps({"status": result.status, "classificado": False}, indent=2))
        return 1

    try:
        with connect(cfg.pg_db_empresas, cfg) as conn:
            vol_status, vol_ok, total = avaliar_tabela(conn, cfg, participante)
            result.total_registros = total
            result.gate_volume = vol_ok
            if not vol_ok:
                result.status = vol_status
                insert_result(cfg, result)
                print(json.dumps({"status": result.status, "classificado": False}, indent=2))
                return 1

            dq_ok, dq_detalhes = avaliar_dq(conn, cfg, participante)
            result.gate_dq = dq_ok
            result.gate_dq_detalhes = dq_detalhes
            if not dq_ok:
                result.status = "ERRO_DATA_QUALITY"
                insert_result(cfg, result)
                print(
                    json.dumps(
                        {
                            "status": result.status,
                            "classificado": False,
                            "gate_dq_detalhes": dq_detalhes,
                        },
                        indent=2,
                    )
                )
                return 1

            result.storage_postgres_mb = measure_postgres_mb(conn, cfg, participante)
    except psycopg2.Error as exc:
        result.status = "ERRO_TABELA_AUSENTE"
        insert_result(cfg, result)
        print(f"ERRO: {exc}", file=sys.stderr)
        return 1

    result.storage_minio_mb = measure_minio_mb(cfg, participante)
    result.status = "CLASSIFICADO"
    result.classificado = True
    insert_result(cfg, result)

    output = {
        "status": result.status,
        "classificado": True,
        "tempo_segundos": float(result.tempo_segundos),
        "storage_postgres_mb": float(result.storage_postgres_mb),
        "storage_minio_mb": float(result.storage_minio_mb),
        "storage_total_mb": float(result.storage_postgres_mb + result.storage_minio_mb),
        "peak_ram_mb": float(result.peak_ram_mb),
        "total_registros": result.total_registros,
    }
    print(json.dumps(output, indent=2))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Juiz automático — Ingestão no Limite")
    sub = parser.add_subparsers(dest="command", required=True)

    p_preflight = sub.add_parser("preflight", help="Gate G1 — conectividade Postgres")
    p_preflight.add_argument("--participante", required=True)

    p_registrar = sub.add_parser("registrar", help="Registra falha antecipada (G0)")
    p_registrar.add_argument("--participante", required=True)
    p_registrar.add_argument("--status", required=True)
    p_registrar.add_argument("--repositorio", default=None)

    p_avaliar = sub.add_parser("avaliar", help="Gates G2–G4 + métricas + ranking")
    p_avaliar.add_argument("--participante", required=True)
    p_avaliar.add_argument("--repositorio", default=None)
    p_avaliar.add_argument("--tempo", type=float, required=True)
    p_avaliar.add_argument("--exit-code", type=int, required=True)
    p_avaliar.add_argument("--peak-ram-mb", type=float, default=0)
    p_avaliar.add_argument("--timed-out", default="false")
    p_avaliar.add_argument("--commit-sha", default=None)
    p_avaliar.add_argument("--pr-numero", type=int, default=None)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    handlers = {
        "preflight": cmd_preflight,
        "registrar": cmd_registrar,
        "avaliar": cmd_avaliar,
    }
    return handlers[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
