#!/usr/bin/env python3
"""
Envia por e-mail o relatório da última avaliação do participante.

Uso:
  JUIZ_CONFIG=evaluator/judge/config.env \\
    python3 evaluator/judge/send_report.py \\
      --participante renan_python --to usuario@exemplo.com
"""

from __future__ import annotations

import argparse
import json
import os
import smtplib
import ssl
import sys
from email.message import EmailMessage
from pathlib import Path
from typing import Any

import psycopg2
import psycopg2.extras

ROOT = Path(__file__).resolve().parent


def _apply_env_file(config_path: Path) -> bool:
    if not config_path.is_file():
        return False
    for line in config_path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        value = value.strip().strip("'").strip('"')
        os.environ.setdefault(key.strip(), value)
    return True


def load_env_file() -> None:
    """Carrega JUIZ_CONFIG (servidor) e, se SMTP faltar, tenta judge/config.env local."""
    primary = Path(os.getenv("JUIZ_CONFIG", str(ROOT / "config.env")))
    _apply_env_file(primary)

    smtp_ready = all(os.getenv(k) for k in ("SMTP_HOST", "SMTP_USER", "SMTP_PASSWORD"))
    local = ROOT / "config.env"
    if not smtp_ready and local.resolve() != primary.resolve():
        if _apply_env_file(local):
            print(f"SMTP: complementado a partir de {local}", file=sys.stderr)


def fetch_ultima_avaliacao(participante: str) -> dict[str, Any] | None:
    conn = psycopg2.connect(
        host=os.getenv("PG_HOST", "localhost"),
        port=int(os.getenv("PG_PORT", "5432")),
        user=os.getenv("PG_USER", "homelab_postgres"),
        password=os.getenv("PG_PASSWORD", ""),
        dbname=os.getenv("PG_DB_RANKING", "db_ingestao"),
    )
    try:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                """
                SELECT
                    github_user,
                    repositorio,
                    status,
                    classificado,
                    tempo_segundos,
                    storage_postgres_mb,
                    storage_minio_mb,
                    storage_total_mb,
                    peak_ram_mb,
                    total_registros,
                    posicao_ranking,
                    gate_preflight,
                    gate_execucao,
                    gate_volume,
                    gate_dq,
                    gate_dq_detalhes,
                    commit_sha,
                    pr_numero,
                    criado_em
                FROM public.v_ultima_avaliacao
                WHERE github_user = %s
                """,
                (participante,),
            )
            row = cur.fetchone()
            return dict(row) if row else None
    finally:
        conn.close()


def _fmt(value: Any, suffix: str = "") -> str:
    if value is None:
        return "—"
    if isinstance(value, bool):
        return "sim" if value else "não"
    if hasattr(value, "isoformat"):
        return value.isoformat(sep=" ", timespec="seconds")
    return f"{value}{suffix}"


def build_message(row: dict[str, Any], to_email: str) -> EmailMessage:
    participante = row["github_user"]
    status = row["status"]
    classificado = bool(row["classificado"])
    assunto = (
        f"[Ingestão no Limite] {participante}: CLASSIFICADO"
        if classificado
        else f"[Ingestão no Limite] {participante}: {status}"
    )

    dq = row.get("gate_dq_detalhes")
    if isinstance(dq, str):
        try:
            dq = json.loads(dq)
        except json.JSONDecodeError:
            pass
    dq_txt = json.dumps(dq, ensure_ascii=False, indent=2) if dq else "—"

    lines = [
        f"Olá, {participante}!",
        "",
        "Segue o resultado da sua avaliação automática no desafio Ingestão no Limite.",
        "",
        "=== Resultado ===",
        f"Status          : {status}",
        f"Classificado    : {_fmt(classificado)}",
        f"Posição ranking : {_fmt(row.get('posicao_ranking'))}",
        f"Avaliado em     : {_fmt(row.get('criado_em'))}",
        "",
        "=== Indicadores principais ===",
        f"Tempo (s)           : {_fmt(row.get('tempo_segundos'))}",
        f"Storage Postgres MB : {_fmt(row.get('storage_postgres_mb'))}",
        f"Storage S3 MB       : {_fmt(row.get('storage_minio_mb'))}",
        f"Storage total MB    : {_fmt(row.get('storage_total_mb'))}",
        f"Pico de RAM MB      : {_fmt(row.get('peak_ram_mb'))}",
        f"Total de registros  : {_fmt(row.get('total_registros'))}",
        "",
        "=== Gates ===",
        f"Preflight : {_fmt(row.get('gate_preflight'))}",
        f"Execução  : {_fmt(row.get('gate_execucao'))}",
        f"Volume    : {_fmt(row.get('gate_volume'))}",
        f"Data Quality : {_fmt(row.get('gate_dq'))}",
        f"DQ detalhes  : {dq_txt}",
        "",
        "=== Rastreabilidade ===",
        f"Repositório : {_fmt(row.get('repositorio'))}",
        f"Commit SHA  : {_fmt(row.get('commit_sha'))}",
        f"PR número   : {_fmt(row.get('pr_numero'))}",
        "",
        "Este e-mail foi enviado automaticamente pelo avaliador.",
    ]

    msg = EmailMessage()
    smtp_from = os.getenv("SMTP_FROM") or os.getenv("SMTP_USER", "")
    msg["From"] = smtp_from
    msg["To"] = to_email
    msg["Subject"] = assunto
    msg.set_content("\n".join(lines))
    return msg


def send_email(msg: EmailMessage) -> None:
    host = os.getenv("SMTP_HOST", "").strip()
    port = int(os.getenv("SMTP_PORT", "465"))
    user = os.getenv("SMTP_USER", "").strip()
    password = os.getenv("SMTP_PASSWORD", "")
    use_ssl = os.getenv("SMTP_USE_SSL", "true").strip().lower() in ("1", "true", "yes")

    if not host or not user or not password:
        cfg = os.getenv("JUIZ_CONFIG", str(ROOT / "config.env"))
        raise RuntimeError(
            "SMTP_HOST, SMTP_USER e SMTP_PASSWORD devem estar definidos no "
            f"arquivo apontado por JUIZ_CONFIG ({cfg}). "
            "No servidor self-hosted, normalmente: /opt/ingestao-juiz/config.env"
        )

    context = ssl.create_default_context()
    if use_ssl or port == 465:
        with smtplib.SMTP_SSL(host, port, context=context, timeout=60) as smtp:
            smtp.login(user, password)
            smtp.send_message(msg)
    else:
        with smtplib.SMTP(host, port, timeout=60) as smtp:
            smtp.starttls(context=context)
            smtp.login(user, password)
            smtp.send_message(msg)


def main() -> int:
    parser = argparse.ArgumentParser(description="Envia relatório da avaliação por e-mail")
    parser.add_argument("--participante", required=True)
    parser.add_argument("--to", required=True, help="E-mail do participante")
    args = parser.parse_args()

    to_email = args.to.strip()
    if not to_email or "@" not in to_email:
        print(f"E-mail inválido: {to_email!r}", file=sys.stderr)
        return 1

    load_env_file()

    row = fetch_ultima_avaliacao(args.participante)
    if not row:
        print(
            f"Nenhuma avaliação encontrada para {args.participante!r} — e-mail não enviado.",
            file=sys.stderr,
        )
        return 1

    msg = build_message(row, to_email)
    try:
        send_email(msg)
    except Exception as exc:  # noqa: BLE001 — reporta e falha o passo
        print(f"Falha ao enviar e-mail: {exc}", file=sys.stderr)
        return 1

    print(f"Relatório enviado para {to_email} (participante={args.participante})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
