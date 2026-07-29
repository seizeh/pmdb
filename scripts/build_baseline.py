#!/usr/bin/env python3
"""
============================================================================
베이스라인 생성 — 마이그레이션 리플레이를 가능하게 만드는 조각.

이 저장소는 2026-06-08 부터 마이그레이션을 관리하기 시작했고, 그 이전의 기반
스키마(테이블 27개·함수·트리거·RLS)는 Supabase 프로젝트에 직접 적용되어
저장소 밖(out-of-band)에 있었다. 그래서 "빈 DB 에 마이그레이션만 적용해서
현재 스키마를 재현"하는 것이 불가능했고, CI 는 리플레이 대신 스냅샷
(supabase/schema/schema.sql) 복원으로 우회하고 있었다.

이 스크립트는 그 빠진 조각을 스냅샷에서 역산한다:

    baseline = schema.sql − (마이그레이션이 만드는 객체)

역산이 성립하는 근거(마이그레이션 175개 전수 확인):
  · 기반 테이블에 대한 add column 은 전부 `if not exists`   → 최종 컬럼이 있어도 무해
  · 제약 변경은 전부 `drop constraint` → `add constraint` 쌍 → 최종 상태에서 시작해도 통과
  · 함수 239개가 `create or replace`                        → 최종 정의가 있어도 덮어써짐
따라서 "마이그레이션이 새로 만드는(=이미 있으면 실패하는) 객체"만 빼내면
나머지는 최종 정의 그대로 두어도 리플레이가 같은 결과에 수렴한다.

그 등식은 추측이 아니라 CI(.github/workflows/db-tests.yml 의 replay 잡)가
매번 검증한다: 빈 DB → prelude+baseline+마이그레이션 → pg_dump → schema.sql 과 diff.
불일치면 실패하므로, 스냅샷과 마이그레이션이 어긋나는 드리프트도 같이 잡힌다.

사용:
    ./scripts/build_baseline.py            # supabase/schema/baseline.sql 생성
    ./scripts/build_baseline.py --report   # 제외된 객체 목록만 출력(적용 안 함)
============================================================================
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCHEMA = ROOT / "supabase" / "schema" / "schema.sql"
MIGRATIONS = ROOT / "supabase" / "migrations"
OUT = ROOT / "supabase" / "schema" / "baseline.sql"

# 스냅샷이 담는 스키마(dump_schema.sh 의 -n 인자와 일치). 그 밖(storage 등)을
# 건드리는 마이그레이션 문장은 애초에 스냅샷에 없으므로 충돌 판정에서 제외한다.
DUMPED_SCHEMAS = {"public", "app"}


# ---------------------------------------------------------------------------
# SQL 문장 분해 — 달러 인용($$, $tag$) 안의 세미콜론을 문장 끝으로 오인하지 않는다.
# ---------------------------------------------------------------------------
def split_statements(sql: str) -> list[str]:
    out: list[str] = []
    buf: list[str] = []
    i, n = 0, len(sql)
    tag: str | None = None  # 열려 있는 달러 인용 태그

    while i < n:
        ch = sql[i]

        if tag is None:
            # 줄 주석
            if sql.startswith("--", i):
                j = sql.find("\n", i)
                j = n if j < 0 else j + 1
                buf.append(sql[i:j])
                i = j
                continue
            # 블록 주석
            if sql.startswith("/*", i):
                j = sql.find("*/", i + 2)
                j = n if j < 0 else j + 2
                buf.append(sql[i:j])
                i = j
                continue
            # 작은따옴표 문자열
            if ch == "'":
                j = i + 1
                while j < n:
                    if sql[j] == "'":
                        if j + 1 < n and sql[j + 1] == "'":
                            j += 2
                            continue
                        j += 1
                        break
                    j += 1
                buf.append(sql[i:j])
                i = j
                continue
            # 큰따옴표 식별자
            if ch == '"':
                j = sql.find('"', i + 1)
                j = n if j < 0 else j + 1
                buf.append(sql[i:j])
                i = j
                continue
            # 달러 인용 시작
            m = re.match(r"\$[A-Za-z_0-9]*\$", sql[i:])
            if m:
                tag = m.group(0)
                buf.append(tag)
                i += len(tag)
                continue
            if ch == ";":
                out.append("".join(buf).strip())
                buf = []
                i += 1
                continue
            buf.append(ch)
            i += 1
        else:
            # 달러 인용 종료 지점까지 통째로
            j = sql.find(tag, i)
            if j < 0:
                buf.append(sql[i:])
                i = n
            else:
                buf.append(sql[i : j + len(tag)])
                i = j + len(tag)
                tag = None

    tail = "".join(buf).strip()
    if tail:
        out.append(tail)
    return out


def strip_comments(stmt: str) -> str:
    """객체 이름 정규식이 주석에 걸리지 않도록 주석만 걷어낸 사본."""
    stmt = re.sub(r"/\*.*?\*/", " ", stmt, flags=re.S)
    stmt = re.sub(r"--[^\n]*", " ", stmt)
    return stmt


def qname(raw: str) -> tuple[str, str]:
    """`public.users` / `"users"` → (schema, name). 스키마 생략 시 public."""
    parts = [p.strip().strip('"') for p in raw.strip().split(".")]
    if len(parts) == 1:
        return "public", parts[0].lower()
    return parts[0].lower(), parts[1].lower()


# ---------------------------------------------------------------------------
# 마이그레이션에서 객체 생성/삭제 동작 추출
# ---------------------------------------------------------------------------
IDENT = r'(?:"[^"]+"|[A-Za-z_][A-Za-z_0-9$]*)'
QUAL = rf"(?:{IDENT}\.)?{IDENT}"


def func_key(schema: str, name: str, argblob: str) -> tuple:
    """함수는 인자 타입까지 봐야 오버로드를 구분한다(RPC 오버로드 섀도잉 사례)."""
    args = []
    depth = 0
    cur = []
    for ch in argblob:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            args.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    if "".join(cur).strip():
        args.append("".join(cur))

    types = []
    for a in args:
        a = a.strip()
        if not a:
            continue
        # `p_user_id uuid default null` → 타입만. IN/OUT 접두와 기본값을 걷어낸다.
        a = re.sub(r"\bdefault\b.*$", "", a, flags=re.I).strip()
        a = re.sub(r"=.*$", "", a).strip()
        a = re.sub(r"^(in|out|inout|variadic)\s+", "", a, flags=re.I).strip()
        toks = a.split()
        # drop function 은 인자 이름 없이 타입만 적는다(`character varying`).
        # 첫 토큰이 타입어휘면 이름이 없는 것으로 보고 통째로 타입 취급한다.
        if len(toks) >= 2 and toks[0].lower().strip('"') not in TYPE_HEAD_WORDS:
            a = " ".join(toks[1:])
        types.append(normalize_type(a))
    return ("function", schema, name, tuple(types))


# 인자 이름 없이 타입만 오는 경우를 가려내기 위한 타입 선두 어휘.
TYPE_HEAD_WORDS = {
    "character", "timestamp", "time", "double", "bit", "numeric", "decimal",
    "integer", "int", "int2", "int4", "int8", "smallint", "bigint", "real",
    "boolean", "bool", "text", "uuid", "json", "jsonb", "date", "interval",
    "bytea", "money", "inet", "cidr", "macaddr", "xml", "tsvector", "varchar",
    "float4", "float8", "timestamptz", "timetz", "char", "serial", "bigserial",
    "geometry", "geography", "record", "anyelement", "anyarray", "void",
}


TYPE_ALIASES = {
    "int": "integer",
    "int4": "integer",
    "int2": "smallint",
    "int8": "bigint",
    "bool": "boolean",
    "varchar": "character varying",
    "char": "character",
    "timestamptz": "timestamp with time zone",
    "timestamp": "timestamp without time zone",
    "timetz": "time with time zone",
    "float8": "double precision",
    "float4": "real",
    "decimal": "numeric",
}


def normalize_type(t: str) -> str:
    t = re.sub(r"\s+", " ", t.strip().lower())
    t = re.sub(r"\(\s*\d+(\s*,\s*\d+)?\s*\)", "", t)  # 길이/정밀도는 시그니처와 무관
    t = t.replace('"', "")
    t = re.sub(r"^(public|pg_catalog)\.", "", t)
    arr = ""
    while t.endswith("[]"):
        arr += "[]"
        t = t[:-2].strip()
    return TYPE_ALIASES.get(t, t) + arr


def parse_migration_actions(statements: list[str]) -> list[tuple]:
    """(action, key, idempotent, cascade) 목록. action ∈ {create, drop}."""
    acts: list[tuple] = []

    for raw in statements:
        s = strip_comments(raw).strip()
        if not s:
            continue
        flat = re.sub(r"\s+", " ", s)
        casc = bool(re.search(r"\bcascade\b", flat, re.I))

        def add(action, key, idem=False):
            acts.append((action, key, idem, casc))

        # --- CREATE TABLE ---------------------------------------------------
        m = re.match(rf"create table (if not exists )?({QUAL})", flat, re.I)
        if m:
            tbl = qname(m.group(2))
            idem = bool(m.group(1))
            add("create", ("table",) + tbl, idem)
            # CREATE TABLE 안에 인라인으로 붙는 CHECK 제약도 이 시점에 생긴다
            # (뒤 마이그레이션이 drop constraint 로 건드리므로 상태에 반영해야 한다).
            for c in inline_constraints(s, tbl[1]):
                add("create", ("constraint",) + tbl + (c,), idem)
            continue

        # --- CREATE VIEW / MATERIALIZED VIEW --------------------------------
        m = re.match(
            rf"create (or replace )?(?:materialized )?view (if not exists )?({QUAL})",
            flat,
            re.I,
        )
        if m:
            add("create", ("view",) + qname(m.group(3)), bool(m.group(1) or m.group(2)))
            continue

        # --- CREATE TYPE ----------------------------------------------------
        m = re.match(rf"create type ({QUAL})", flat, re.I)
        if m:
            add("create", ("type",) + qname(m.group(1)))
            continue

        # --- CREATE FUNCTION ------------------------------------------------
        m = re.match(rf"create (or replace )?function ({QUAL})\s*\(", s, re.I)
        if m:
            schema, name = qname(m.group(2))
            argblob = extract_paren(s, s.index("(", m.end(2) - 1))
            add("create", func_key(schema, name, argblob), bool(m.group(1)))
            continue

        # --- CREATE INDEX ---------------------------------------------------
        m = re.match(
            rf"create (unique )?index (concurrently )?(if not exists )?({IDENT}) on ({QUAL})",
            flat,
            re.I,
        )
        if m:
            tbl = qname(m.group(5))
            add("create", ("index", tbl[0], m.group(4).strip('"').lower()), bool(m.group(3)))
            continue

        # --- CREATE TRIGGER -------------------------------------------------
        m = re.match(rf"create (or replace )?trigger ({IDENT})\b", flat, re.I)
        if m:
            mo = re.search(rf"\bon ({QUAL})", flat, re.I)
            if mo:
                tbl = qname(mo.group(1))
                trg = m.group(2).strip('"').lower()
                add("create", ("trigger",) + tbl + (trg,), bool(m.group(1)))
            continue

        # --- CREATE POLICY --------------------------------------------------
        m = re.match(rf"create policy ({IDENT}) on ({QUAL})", flat, re.I)
        if m:
            tbl = qname(m.group(2))
            add("create", ("policy",) + tbl + (m.group(1).strip('"').lower(),))
            continue

        # --- ALTER TABLE ... ADD/DROP CONSTRAINT ----------------------------
        m = re.match(rf"alter table (only )?(if exists )?({QUAL})", flat, re.I)
        if m:
            tbl = qname(m.group(3))
            for cm in re.finditer(rf"\badd constraint ({IDENT})", flat, re.I):
                add("create", ("constraint",) + tbl + (cm.group(1).strip('"').lower(),))
            # `add column … check (…)` 처럼 이름 없는 제약은 Postgres 가
            # <테이블>_<컬럼>_check 로 자동 명명한다(뒤에서 그 이름으로 drop 한다).
            # 컬럼이 `if not exists` 면 제약 생성도 같이 조건부다 — 베이스라인에
            # 이미 컬럼이 있으면 ALTER 자체가 no-op 이므로 제약을 빼면 안 된다.
            for cm in re.finditer(
                rf"\badd column (if not exists )?({IDENT})([^,;]*)", flat, re.I
            ):
                if depth0_has(cm.group(3), "check"):
                    col = cm.group(2).strip('"').lower()
                    add("create", ("constraint",) + tbl + (f"{tbl[1]}_{col}_check",), bool(cm.group(1)))
            for cm in re.finditer(rf"\bdrop constraint (if exists )?({IDENT})", flat, re.I):
                add(
                    "drop",
                    ("constraint",) + tbl + (cm.group(2).strip('"').lower(),),
                    bool(cm.group(1)),
                )
            continue

        # --- DROP ... -------------------------------------------------------
        m = re.match(rf"drop table (if exists )?({QUAL})", flat, re.I)
        if m:
            add("drop", ("table",) + qname(m.group(2)), bool(m.group(1)))
            continue

        m = re.match(rf"drop (?:materialized )?view (if exists )?({QUAL})", flat, re.I)
        if m:
            add("drop", ("view",) + qname(m.group(2)), bool(m.group(1)))
            continue

        m = re.match(rf"drop function (if exists )?({QUAL})\s*\(", s, re.I)
        if m:
            schema, name = qname(m.group(2))
            argblob = extract_paren(s, s.index("(", m.end(2) - 1))
            add("drop", func_key(schema, name, argblob), bool(m.group(1)))
            continue

        m = re.match(rf"drop index (if exists )?({QUAL})", flat, re.I)
        if m:
            sch, idx = qname(m.group(2))
            add("drop", ("index", sch, idx), bool(m.group(1)))
            continue

        m = re.match(rf"drop trigger (if exists )?({IDENT}) on ({QUAL})", flat, re.I)
        if m:
            tbl = qname(m.group(3))
            add("drop", ("trigger",) + tbl + (m.group(2).strip('"').lower(),), bool(m.group(1)))
            continue

        m = re.match(rf"drop policy (if exists )?({IDENT}) on ({QUAL})", flat, re.I)
        if m:
            tbl = qname(m.group(3))
            add("drop", ("policy",) + tbl + (m.group(2).strip('"').lower(),), bool(m.group(1)))
            continue

    return acts


def split_top_level(body: str) -> list[str]:
    """괄호 깊이 0 의 콤마로만 나눈다(CREATE TABLE 의 컬럼/제약 항목 분리)."""
    items, cur, depth = [], [], 0
    in_str = False
    i = 0
    while i < len(body):
        ch = body[i]
        if in_str:
            if ch == "'":
                if i + 1 < len(body) and body[i + 1] == "'":
                    cur.append("''")
                    i += 2
                    continue
                in_str = False
            cur.append(ch)
        elif ch == "'":
            in_str = True
            cur.append(ch)
        elif ch == "(":
            depth += 1
            cur.append(ch)
        elif ch == ")":
            depth -= 1
            cur.append(ch)
        elif ch == "," and depth == 0:
            items.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
        i += 1
    if "".join(cur).strip():
        items.append("".join(cur))
    return items


def table_body(stmt: str) -> tuple[int, int] | None:
    """CREATE TABLE 문에서 컬럼 목록 괄호의 (시작, 끝) 인덱스."""
    m = re.search(r"create table[^(]*", stmt, re.I)
    if not m:
        return None
    try:
        start = stmt.index("(", m.end() - 1)
    except ValueError:
        return None
    depth = 0
    for i in range(start, len(stmt)):
        if stmt[i] == "(":
            depth += 1
        elif stmt[i] == ")":
            depth -= 1
            if depth == 0:
                return start, i
    return None


CONSTRAINT_ITEM = re.compile(rf"^\s*constraint\s+({IDENT})", re.I)
TABLE_LEVEL_KW = re.compile(r"^\s*(check|unique|primary\s+key|foreign\s+key|exclude)\b", re.I)


def depth0_has(item: str, word: str) -> bool:
    """괄호 밖(깊이 0)에 해당 키워드가 있는지 — check (…) 안의 텍스트를 오인하지 않도록."""
    depth = 0
    for m in re.finditer(r"[()]|\b[a-z_]+\b", item, re.I):
        tok = m.group(0)
        if tok == "(":
            depth += 1
        elif tok == ")":
            depth -= 1
        elif depth == 0 and tok.lower() == word:
            return True
    return False


def inline_constraints(stmt: str, table: str | None = None) -> list[str]:
    """CREATE TABLE 안의 제약 이름. 이름을 안 붙인 CHECK/UNIQUE 도 Postgres 가
    자동으로 `<테이블>_<컬럼>_check` 식 이름을 붙이므로 같이 계산한다
    (뒤 마이그레이션이 그 자동 이름으로 drop constraint 를 건다)."""
    span = table_body(stmt)
    if not span:
        return []
    if table is None:
        m = re.search(rf"create table (?:if not exists )?({QUAL})", stmt, re.I)
        table = qname(m.group(1))[1] if m else ""

    names = []
    for item in split_top_level(stmt[span[0] + 1 : span[1]]):
        m = CONSTRAINT_ITEM.match(item)
        if m:
            names.append(m.group(1).strip('"').lower())
            continue
        if TABLE_LEVEL_KW.match(item):
            if depth0_has(item, "check"):
                names.append(f"{table}_check")
            elif re.match(r"^\s*primary\s+key", item, re.I):
                names.append(f"{table}_pkey")
            continue
        # 컬럼 정의 — 컬럼 이름 + 붙어 있는 제약
        cm = re.match(rf"^\s*({IDENT})", item)
        if not cm:
            continue
        col = cm.group(1).strip('"').lower()
        if depth0_has(item, "check"):
            names.append(f"{table}_{col}_check")
        if depth0_has(item, "unique"):
            names.append(f"{table}_{col}_key")
        if depth0_has(item, "primary"):
            names.append(f"{table}_pkey")
    return names


def strip_columns(stmt: str, cols: set) -> str:
    """CREATE TABLE 본문에서 지정 컬럼 정의를 제거한다.

    마이그레이션이 `add column if not exists` 로 붙이는 컬럼은 베이스라인에 남겨 두면
    ALTER 가 통째로 no-op 이 되어, 같은 문장에 달린 FK·CHECK·기본값까지 함께 사라진다
    (posts.photo_verification_id → posts_photo_verification_id_fkey 유실 사례).
    베이스라인은 '마이그레이션 이전 상태' 여야 하므로 빼는 게 원래 맞다.
    """
    span = table_body(stmt)
    if not span:
        return stmt
    kept = []
    for item in split_top_level(stmt[span[0] + 1 : span[1]]):
        if CONSTRAINT_ITEM.match(item) or TABLE_LEVEL_KW.match(item):
            kept.append(item)
            continue
        m = re.match(rf"^\s*({IDENT})", item)
        if m and m.group(1).strip('"').lower() in cols:
            continue
        kept.append(item)
    return stmt[: span[0] + 1] + ",".join(kept) + stmt[span[1] :]


def strip_inline_constraint(stmt: str, name: str) -> str:
    """CREATE TABLE 본문에서 지정 제약 항목만 제거한다(마이그레이션이 다시 붙인다)."""
    span = table_body(stmt)
    if not span:
        return stmt
    items = split_top_level(stmt[span[0] + 1 : span[1]])
    kept = []
    for item in items:
        m = CONSTRAINT_ITEM.match(item)
        if m and m.group(1).strip('"').lower() == name:
            continue
        kept.append(item)
    return stmt[: span[0] + 1] + ",".join(kept) + stmt[span[1] :]


def added_columns(statements: list[str]) -> dict:
    """마이그레이션이 `alter table … add column` 으로 붙이는 (스키마, 테이블) → 컬럼 집합."""
    out: dict = {}
    for raw in statements:
        s = strip_comments(raw).strip()
        flat = re.sub(r"\s+", " ", s)
        m = re.match(rf"alter table (?:only )?(?:if exists )?({QUAL})", flat, re.I)
        if not m:
            continue
        tbl = qname(m.group(1))
        for cm in re.finditer(rf"\badd column (?:if not exists )?({IDENT})", flat, re.I):
            out.setdefault(tbl, set()).add(cm.group(1).strip('"').lower())
    return out


def usage_order(files: list[Path]) -> tuple[dict, dict]:
    """마이그레이션 전체를 한 줄로 늘어놓고 각 객체의
    (처음 만들어지는 문장 번호, 처음 참조되는 문장 번호)를 잰다.

    `create or replace` 로 갱신되는 뷰·함수라도, 그 앞 마이그레이션이 이미 쓰고
    있으면 베이스라인에 있어야 한다(app.uid() 가 그렇다 — 두 번째 마이그레이션부터
    쓰는데 재정의는 한참 뒤다).
    """
    first_create: dict[tuple, int] = {}
    first_ref: dict[str, int] = {}
    idx = 0
    for f in files:
        for raw in split_statements(f.read_text()):
            s = strip_comments(raw).strip()
            if not s:
                continue
            idx += 1
            for action, key, _, _ in parse_migration_actions([raw]):
                if action == "create":
                    first_create.setdefault(key, idx)
            # DROP 은 '사용'이 아니고(재정의 직전 정리), COMMENT 는 설명문일 뿐이다.
            if re.match(r"(drop|comment)\b", s, re.I):
                continue
            # 문자열 리터럴 안의 이름도 사용이 아니다
            # (`comment … '… (app.has_license).'` 같은 설명에 걸린다).
            body = re.sub(r"'(?:[^']|'')*'", " ", s.lower())
            for m in re.finditer(r"\b([a-z_][a-z_0-9]*)\.([a-z_][a-z_0-9]*)\b", body):
                first_ref.setdefault(m.group(0), idx)
    return first_create, first_ref


def extract_paren(s: str, open_idx: int) -> str:
    depth = 0
    for i in range(open_idx, len(s)):
        if s[i] == "(":
            depth += 1
        elif s[i] == ")":
            depth -= 1
            if depth == 0:
                return s[open_idx + 1 : i]
    return ""


# ---------------------------------------------------------------------------
# 스냅샷(schema.sql) 블록 분해 — pg_dump 의 `-- Name: …; Type: …;` 헤더 기준
# ---------------------------------------------------------------------------
HEADER = re.compile(
    r"^--\n-- Name: (?P<name>.+?); Type: (?P<type>[A-Z ]+); Schema: (?P<schema>[^;]+);.*?\n--\n",
    re.M,
)


class Block:
    def __init__(self, header: str, name: str, typ: str, schema: str, body: str):
        self.header = header
        self.name = name
        self.type = typ
        self.schema = schema.strip()
        self.body = body
        self.key: tuple | None = None      # 이 블록이 정의하는 객체
        self.owner: tuple | None = None    # 이 블록이 딸린 릴레이션(있으면)
        self.inline: list[tuple] = []      # CREATE TABLE 안의 인라인 제약 키

    def text(self) -> str:
        return self.header + self.body


def parse_schema_blocks(sql: str) -> tuple[str, list[Block]]:
    matches = list(HEADER.finditer(sql))
    preamble = sql[: matches[0].start()] if matches else sql
    blocks: list[Block] = []
    for i, m in enumerate(matches):
        end = matches[i + 1].start() if i + 1 < len(matches) else len(sql)
        blocks.append(
            Block(m.group(0), m.group("name"), m.group("type").strip(), m.group("schema"), sql[m.end() : end])
        )
    return preamble, blocks


def classify(b: Block) -> None:
    """블록에 key(정의 객체)와 owner(딸린 테이블)를 붙인다."""
    body = strip_comments(b.body)
    flat = re.sub(r"\s+", " ", body).strip()
    sch = b.schema if b.schema != "-" else "public"

    if b.type == "TABLE":
        b.key = ("table", sch, b.name.lower())
        b.owner = b.key
        b.inline = [("constraint", sch, b.name.lower(), c)
                    for c in inline_constraints(body, b.name.lower())]
    elif b.type == "VIEW":
        b.key = ("view", sch, b.name.lower())
    elif b.type == "TYPE":
        b.key = ("type", sch, b.name.lower())
    elif b.type == "SEQUENCE":
        b.key = ("sequence", sch, b.name.lower())
        # identity 컬럼의 시퀀스는 `ALTER TABLE … ADD GENERATED …` 로 나온다.
        # 딸린 테이블이 제외 대상이면 이 블록도 같이 빠져야 한다.
        m = re.search(rf"alter table (?:only )?({QUAL})", flat, re.I)
        if not m:
            m = re.search(rf"owned by ({QUAL})\.", flat, re.I)
        if m:
            b.owner = ("table",) + qname(m.group(1))
    elif b.type == "FUNCTION":
        m = re.match(rf"({IDENT})\s*\(", b.name)
        if m:
            argblob = extract_paren(b.name, b.name.index("("))
            b.key = func_key(sch, m.group(1).strip('"').lower(), argblob)
    elif b.type == "INDEX":
        b.key = ("index", sch, b.name.lower())
        m = re.search(rf"\bon ({QUAL})", flat, re.I)
        if m:
            b.owner = ("table",) + qname(m.group(1))
    elif b.type == "POLICY":
        m = re.search(rf"create policy ({IDENT}) on ({QUAL})", flat, re.I)
        if m:
            tbl = qname(m.group(2))
            b.owner = ("table",) + tbl
            b.key = ("policy",) + tbl + (m.group(1).strip('"').lower(),)
    elif b.type == "TRIGGER":
        m = re.search(rf"create (?:or replace )?trigger ({IDENT})", flat, re.I)
        mo = re.search(rf"\bon ({QUAL})", flat, re.I)
        if m and mo:
            tbl = qname(mo.group(1))
            b.owner = ("table",) + tbl
            b.key = ("trigger",) + tbl + (m.group(1).strip('"').lower(),)
    elif b.type in ("CONSTRAINT", "FK CONSTRAINT"):
        m = re.search(rf"alter table (?:only )?({QUAL})", flat, re.I)
        mc = re.search(rf"add constraint ({IDENT})", flat, re.I)
        if m:
            tbl = qname(m.group(1))
            b.owner = ("table",) + tbl
            if mc:
                b.key = ("constraint",) + tbl + (mc.group(1).strip('"').lower(),)
    elif b.type == "ROW SECURITY":
        m = re.search(rf"alter table ({QUAL})", flat, re.I)
        if m:
            b.owner = ("table",) + qname(m.group(1))
    elif b.type in ("ACL", "COMMENT", "DEFAULT ACL"):
        # `TABLE users` / `FUNCTION uid()` / `COLUMN users.phone` 형태의 이름에서 대상 추론
        # 이름이 스키마 없이 오는 경우가 많다(`FUNCTION uid()`), 그때는 블록의 스키마를 쓴다.
        def q(raw: str) -> tuple:
            s2, n2 = qname(raw)
            return (sch, n2) if "." not in raw else (s2, n2)

        m = re.match(r"(TABLE|VIEW|SEQUENCE|COLUMN|FUNCTION|TYPE|SCHEMA)\s+(.+)", b.name)
        if m:
            kind, target = m.group(1), m.group(2).strip()
            if kind in ("TABLE", "VIEW", "SEQUENCE"):
                b.owner = ("table",) + q(target)
            elif kind == "COLUMN":
                b.owner = ("table",) + q(target.rsplit(".", 1)[0])
            elif kind == "TYPE":
                b.key = ("type",) + q(target)
            elif kind == "FUNCTION":
                fm = re.match(rf"({QUAL})\s*\(", target)
                if fm:
                    fs, fn = q(fm.group(1))
                    b.key = func_key(fs, fn, extract_paren(target, target.index("(")))
        else:
            # GRANT ... ON TABLE x / ON FUNCTION x(...) 본문에서 직접
            m = re.search(rf"on table ({QUAL})", flat, re.I)
            if m:
                b.owner = ("table",) + qname(m.group(1))


# ---------------------------------------------------------------------------
# 충돌 판정 — "마이그레이션이 만드는데 베이스라인에도 있으면 실패하는" 객체
# ---------------------------------------------------------------------------
def view_dependencies(blocks: list[Block]) -> dict[tuple, set]:
    """뷰 → 그 뷰가 참조하는 릴레이션. `drop … cascade` 파급을 재현하는 데 쓴다.

    (public_profiles 를 cascade 로 지우면 그걸 참조하는 피드 뷰 5개가 같이 사라지고,
     같은 마이그레이션이 다시 create view 한다 — 이걸 모르면 오탐이 난다.)
    """
    rels = {b.key for b in blocks if b.key and b.key[0] in ("table", "view")}
    by_name: dict[str, tuple] = {}
    for k in rels:
        by_name.setdefault(k[2], k)
        by_name[f"{k[1]}.{k[2]}"] = k

    deps: dict[tuple, set] = {}
    for b in blocks:
        if b.type != "VIEW" or not b.key:
            continue
        body = strip_comments(b.body).lower()
        found = set()
        for m in re.finditer(r"\b([a-z_][a-z_0-9]*)\.([a-z_][a-z_0-9]*)\b|\b([a-z_][a-z_0-9]*)\b", body):
            token = m.group(0)
            hit = by_name.get(token)
            if hit and hit != b.key:
                found.add(hit)
        deps[b.key] = found
    return deps


def cascade_targets(root: tuple, deps: dict[tuple, set]) -> set:
    """root 를 cascade 로 지웠을 때 함께 사라지는 뷰 집합(전이 폐포)."""
    gone = {root}
    changed = True
    while changed:
        changed = False
        for view, refs in deps.items():
            if view not in gone and refs & gone:
                gone.add(view)
                changed = True
    return gone - {root}


def simulate(
    acts: list[tuple],
    present: set,
    deps: dict[tuple, set],
    owner_of: dict[tuple, tuple],
) -> tuple[set, set, list[tuple]]:
    """마이그레이션을 순서대로 흘려 리플레이가 깨지는 지점을 찾는다.

    반환:
      soft  — 스냅샷에 이미 있어서 충돌하는 객체(= 베이스라인에서 빼면 해결)
      hard  — 마이그레이션끼리 충돌(= 베이스라인으로 해결 불가, 마이그레이션 결함)
      missing_drops — 없는 객체를 IF EXISTS 없이 drop (역시 마이그레이션 결함)
    """
    # 값은 출처: 'snapshot'(베이스라인이 만든 것) | 'migration'
    state = {k: "snapshot" for k in present}
    soft: set = set()
    hard: set = set()
    missing_drops: list[tuple] = []

    for action, key, idem, casc in acts:
        if key[1] not in DUMPED_SCHEMAS:
            continue  # storage.* 등 스냅샷 범위 밖은 판정하지 않는다
        if action == "create":
            if key in state and not idem:
                (soft if state[key] == "snapshot" else hard).add(key)
            state[key] = "migration"
        else:  # drop
            if key not in state and not idem:
                missing_drops.append(key)
            state.pop(key, None)
            if key[0] == "table":
                # 테이블을 지우면 딸린 제약·정책·트리거·인덱스도 같이 사라진다.
                for k in [k for k in state if _belongs_to(k, key, owner_of)]:
                    state.pop(k, None)
            if casc:
                for dep in cascade_targets(key, deps):
                    state.pop(dep, None)

    return soft, hard, missing_drops


def _belongs_to(key: tuple, table: tuple, owner_of: dict[tuple, tuple]) -> bool:
    if key[0] in ("constraint", "policy", "trigger"):
        return (key[1], key[2]) == (table[1], table[2])
    return owner_of.get(key) == table


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--report", action="store_true", help="제외 대상만 출력")
    args = ap.parse_args()

    schema_sql = SCHEMA.read_text()
    preamble, blocks = parse_schema_blocks(schema_sql)
    for b in blocks:
        classify(b)

    files = sorted(MIGRATIONS.glob("*.sql"))
    acts: list[tuple] = []
    for f in files:
        acts += parse_migration_actions(split_statements(f.read_text()))
    first_create, first_ref = usage_order(files)
    all_stmts = [st for f in files for st in split_statements(f.read_text())]
    mig_columns = added_columns(all_stmts)

    deps = view_dependencies(blocks)
    owner_of = {b.key: b.owner for b in blocks if b.key and b.owner and b.key != b.owner}
    present = {b.key for b in blocks if b.key}
    inline_of = {b.key: set(b.inline) for b in blocks if b.type == "TABLE" and b.key}
    for keys in inline_of.values():
        present |= keys

    # 제외 집합을 고정점까지 넓힌다: 테이블을 빼면 그 인라인 제약도 같이 없어지므로
    # 한 번의 시뮬레이션으로는 판정이 끝나지 않을 수 있다.
    excluded: set = set()
    hard: set = set()
    missing_drops: list[tuple] = []
    for _ in range(10):
        effective = present - excluded
        for tk in excluded & inline_of.keys():
            effective -= inline_of[tk]
        soft, hard, missing_drops = simulate(acts, effective, deps, owner_of)
        if soft <= excluded:
            break
        excluded |= soft

    # 제외를 의존성 방향으로 전파한다. 예: app.has_license 는 `create or replace`
    # 라 그 자체로는 충돌하지 않지만, 인자 타입 app.biz_license_type 이 마이그레이션
    # 소관이라 베이스라인 시점에는 아직 없다. 이런 블록은 어차피 마이그레이션이
    # 다시 만들어 주므로 같이 빼야 리플레이가 굴러간다.
    migration_creates = {key for action, key, _, _ in acts if action == "create"}
    unresolved: list[tuple] = []

    # 뷰·함수는 최종 정의를 두면 안 된다. `or replace` 가 제자리 갱신이라 옛 정의로
    # 되돌릴 수 없는 변경이 있기 때문이다:
    #   · 뷰   — 컬럼을 지우거나 순서를 바꿀 수 없다(cannot drop columns from view)
    #   · 함수 — 인자 이름을 바꿀 수 없다(cannot change name of input parameter)
    # 최종본 위에 옛 정의를 replace 하는 순간 깨지므로, 마이그레이션이 만드는
    # 뷰·함수는 전부 빼고 리플레이가 처음부터 쌓게 한다.
    # 단, 만들어지기 전에 이미 쓰이는 것은 베이스라인에 있어야 한다(app.uid()).
    # 참조는 이름만 보이고 시그니처는 안 보이므로(오버로드 구분 불가), 같은 이름의
    # 오버로드 중 가장 이른 생성 시점과 비교한다 — 안 그러면 4인자 버전의 생성을
    # 7인자 버전에 대한 '조기 사용' 으로 잘못 읽는다.
    earliest_create: dict[str, int] = {}
    for k, i in first_create.items():
        if k[0] in ("view", "function"):
            name = f"{k[1]}.{k[2]}"
            earliest_create[name] = min(earliest_create.get(name, i), i)

    # baseline-manual.sql 이 손으로 복원해 둔 객체는 자동 파트에서 뺀다(중복 정의 방지).
    manual_path = ROOT / "supabase" / "schema" / "baseline-manual.sql"
    manual_creates = set()
    if manual_path.exists():
        manual_creates = {
            key
            for action, key, _, _ in parse_migration_actions(
                split_statements(manual_path.read_text())
            )
            if action == "create"
        }
        excluded |= manual_creates

    kept_early = set()
    for k in migration_creates:
        if k in manual_creates:
            continue
        if k[0] not in ("view", "function"):
            continue
        name = f"{k[1]}.{k[2]}"
        if first_ref.get(name, 1 << 30) < earliest_create.get(name, 1 << 30):
            kept_early.add(k)
        else:
            excluded.add(k)
    for _ in range(10):
        names = set()
        for k in excluded:
            if k[0] in ("table", "view", "type", "function"):
                names.add(f"{k[1]}.{k[2]}")
        if not names:
            break
        pattern = re.compile(
            r"(?<![A-Za-z_0-9.])(" + "|".join(re.escape(n) for n in sorted(names)) + r")\b"
        )
        grew = False
        for b in blocks:
            if not b.key or b.key in excluded:
                continue
            if b.type not in ("FUNCTION", "VIEW", "TABLE"):
                continue
            if not pattern.search(b.name + " " + strip_comments(b.body)):
                continue
            if b.key in kept_early:
                # 만들어지기 전에 쓰이는 객체라 뺄 수 없다 — 빼면 앞 마이그레이션이 깨진다.
                if b.key not in [u[0] for u in unresolved]:
                    unresolved.append((b.key, b.type + " (조기 사용)"))
            elif b.key in migration_creates:
                excluded.add(b.key)
                grew = True
            elif b.key not in [u[0] for u in unresolved]:
                unresolved.append((b.key, b.type))
        if not grew:
            break

    # 제외된 테이블에 딸린 인덱스·정책·트리거·제약·GRANT·COMMENT 도 함께 뺀다
    # (테이블 자체가 마이그레이션 소관이면 부속물도 전부 그쪽에서 만들어진다).
    excluded_tables = {k for k in excluded if k[0] == "table"}
    restored_funcs: set = set()
    # 유지되는 테이블에 남은 인라인 제약 충돌은 CREATE TABLE 본문에서 잘라낸다.
    strip_targets: dict[tuple, set] = {}
    for k in excluded:
        if k[0] == "constraint":
            tk = ("table", k[1], k[2])
            if tk not in excluded_tables:
                strip_targets.setdefault(tk, set()).add(k[3])

    # 부속 블록(제약·FK·기본값·시퀀스·인덱스·GRANT…)이 제외 대상을 참조하면 같이 뺀다.
    # 남아 있는 테이블에서 마이그레이션 소관 테이블로 거는 FK 가 대표적인 경우다.
    # 테이블·뷰·타입만 본다. 함수는 여기 넣으면 안 된다 — 트리거 함수를 참조하는
    # CREATE TRIGGER 까지 같이 빠지는데, 그 트리거를 다시 만들어 주는 마이그레이션이
    # 없어서 통째로 유실된다(trg_users_after_insert 등 6개 사례).
    # 대신 아래에서 '남은 블록이 참조하는 함수' 를 베이스라인에 되살린다.
    attach_names = {
        f"{k[1]}.{k[2]}" for k in excluded if k[0] in ("table", "view", "type")
    }
    attach_re = (
        re.compile(r"(?<![A-Za-z_0-9.])(" + "|".join(re.escape(n) for n in sorted(attach_names)) + r")\b")
        if attach_names
        else None
    )
    ATTACH_TYPES = {
        "CONSTRAINT", "FK CONSTRAINT", "DEFAULT", "SEQUENCE",
        "INDEX", "TRIGGER", "POLICY", "ROW SECURITY", "ACL", "COMMENT",
    }

    # 남아 있는 트리거·인덱스·정책이 참조하는 함수는 베이스라인 시점에 있어야 한다.
    # (제외해 버리면 CREATE TRIGGER 가 function … does not exist 로 깨진다.)
    excluded_func_by_name: dict = {}
    for k in excluded:
        if k[0] == "function":
            excluded_func_by_name.setdefault(f"{k[1]}.{k[2]}", []).append(k)
    if excluded_func_by_name:
        need = re.compile(
            r"(?<![A-Za-z_0-9.])("
            + "|".join(re.escape(n) for n in sorted(excluded_func_by_name))
            + r")\s*\("
        )
        for b in blocks:
            if b.type not in ("TRIGGER", "INDEX", "POLICY", "CONSTRAINT"):
                continue
            if b.key and b.key in excluded:
                continue
            if b.owner and b.owner in excluded_tables:
                continue
            for m in need.finditer(strip_comments(b.body)):
                for k in excluded_func_by_name.get(m.group(1), []):
                    excluded.discard(k)
                    restored_funcs.add(k)

    kept: list[Block] = []
    removed: list[Block] = []
    for b in blocks:
        if (b.key and b.key in excluded) or (b.owner and b.owner in excluded_tables):
            removed.append(b)
            continue
        if attach_re and b.type in ATTACH_TYPES and attach_re.search(strip_comments(b.body)):
            removed.append(b)
            continue
        if b.type == "TABLE" and b.key:
            cols = mig_columns.get((b.key[1], b.key[2]))
            if cols:
                b.body = strip_columns(b.body, cols)
            for name in sorted(strip_targets.get(b.key, ())):
                b.body = strip_inline_constraint(b.body, name)
        kept.append(b)

    if args.report:
        print(f"마이그레이션 동작 {len(acts)}건 / 스냅샷 객체 {len(present)}개")
        print(f"\n== 베이스라인에서 제외 {len(excluded)}개 ==")
        for k in sorted(excluded, key=str):
            print("  ", k)
        if strip_targets:
            print(f"\n== CREATE TABLE 본문에서 잘라낸 인라인 제약 ==")
            for tk, names in sorted(strip_targets.items(), key=str):
                print("  ", tk[1] + "." + tk[2], sorted(names))
        print(f"\n== 마이그레이션끼리 충돌(베이스라인으로 해결 불가) {len(hard)}건 ==")
        for k in sorted(hard, key=str):
            print("  ", k)
        print(f"\n== 없는 객체를 drop(IF EXISTS 없음) {len(set(missing_drops))}건 ==")
        for k in sorted(set(missing_drops), key=str):
            print("  ", k)
        print(f"\n== 만들어지기 전에 쓰여 베이스라인에 남긴 뷰·함수 {len(kept_early)}개 ==")
        for k in sorted(kept_early, key=str):
            print("  ", k)
        print(f"\n== 남은 블록이 참조해 베이스라인에 되살린 함수 {len(restored_funcs)}개 ==")
        for k in sorted(restored_funcs, key=str):
            print("  ", k)
        print(f"\n== 베이스라인 테이블에서 뺀 컬럼(마이그레이션이 add column) ==")
        for t, cs in sorted(mig_columns.items()):
            print("  ", f"{t[0]}.{t[1]}", sorted(cs))
        print(f"\n== 제외 대상을 참조하는데 마이그레이션이 안 만드는 블록 {len(unresolved)}개 ==")
        for k, t in sorted(unresolved, key=str):
            print("  ", t, k)
        print(f"\n제외 블록 {len(removed)} / 유지 블록 {len(kept)}")
        return 0

    header = (
        "--\n"
        "-- baseline.sql — 마이그레이션 저장소 밖(out-of-band)에 있던 기반 스키마\n"
        "--\n"
        "-- 자동 생성물이다. 직접 수정하지 말고 ./scripts/build_baseline.py 를 다시 돌릴 것.\n"
        "-- prelude.sql → baseline.sql → migrations/*.sql 순서로 적용하면\n"
        "-- schema.sql 스냅샷과 같은 스키마가 나온다(CI replay 잡이 매번 검증).\n"
        "--\n\n"
    )
    manual = ROOT / "supabase" / "schema" / "baseline-manual.sql"
    tail = ""
    if manual.exists():
        tail = (
            "\n--\n-- 여기부터는 baseline-manual.sql — 스냅샷에서 역산할 수 없어\n"
            "-- 손으로 복원한 조각이다(이유는 그 파일 주석 참고).\n--\n\n"
            + manual.read_text()
        )
    OUT.write_text(header + preamble + "".join(b.text() for b in kept) + tail)
    print(f"written: {OUT} ({len(OUT.read_text().splitlines())} lines)")
    print(f"제외 {len(removed)} 블록 / 유지 {len(kept)} 블록")
    if missing_drops:
        print(f"경고: 없는 객체를 drop 하는 문장 {len(set(missing_drops))}건 — --report 로 확인", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
