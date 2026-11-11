#!/usr/bin/env python3
"""
============================================================================
테스트 서버 권한 정렬 — 운영의 API 롤 권한을 테스트 DB 의 같은 객체에 옮긴다.

왜 필요한가
  pg_dump 는 GRANT 만 내보내고 REVOKE 는 내보내지 않는다. 그런데 Supabase 프로젝트의
  public 스키마에는 "postgres 가 만드는 테이블·함수·시퀀스는 anon·authenticated·
  service_role 에 ALL" 이라는 기본 권한이 걸려 있다. 그래서 스냅샷(schema.sql)을
  호스팅 프로젝트에 복원하면 객체가 만들어지는 순간 그 기본 권한이 붙고, 운영에서
  회수해 둔 권한이 전부 되살아난다. pgTAP 스냅샷 DB 에서 두 번 겪은 것(0032 §6.4)과
  같은 원인인데, 테스트 서버는 인터넷에 열려 있다는 점이 다르다.
  2026-11-11 실측: 스냅샷으로 세운 테스트 서버에서 서버 전용 함수가 anon 에게 실행
  가능했고, 테이블 수준 권한이 컬럼 권한을 덮고 있었다.

무엇을 맞추는가 — 양쪽에 모두 있는 객체만(public·app 스키마, 확장 소속 제외)
  · 함수 EXECUTE
  · 테이블·뷰·시퀀스의 테이블 수준 권한과 컬럼 권한
  · RLS 스위치(켜는 방향만 — 대상이 더 좁으면 그대로 둔다)
  · postgres 롤의 기본 권한(전역·public·app) — 앞으로 만들 객체가 다시 풀리지 않게
  · spatial_ref_sys 쓰기 가드 트리거(20260915100000) — 스냅샷에는 함수만 실린다
  대상 롤은 PUBLIC·anon·authenticated·service_role 이다.

무엇을 하지 않는가
  · 스키마 차이(대상에 없는 객체, 옛 본문·정책)는 세어서 보여 주기만 한다 —
    그건 마이그레이션을 적용해서 메울 일이다.
  · 기준(운영)에는 읽기 전용 트랜잭션으로만 붙는다. 방향은 고정이다 — 운영을
    대상으로 삼는 경로는 없다.

사용
  ./scripts/align_test_privs.py            대조만. 권한 차이가 있으면 exit 1
  ./scripts/align_test_privs.py -v         차이를 전부 나열
  ./scripts/align_test_privs.py --apply    리허설(롤백) → 읽기 점검이 기준과 같으면
                                           적용 → 재대조

  접속 정보는 scripts/backup.env 의 SUPABASE_DB_URL(기준)과 scripts/test-server.env 의
  TEST_SUPABASE_DB_URL(대상)에서 읽는다. --apply 는 적용한 SQL(sync.sql)과 되돌리는
  SQL(undo.sql)을 backups/test-privs/<UTC 시각>/ 에 남긴다(--out 으로 바꿀 수 있다).

  종료 코드: 0 일치 · 1 권한 차이 있음 · 2 리허설에서 멈춤(적용 안 함) · 3 실행 오류

  ALIGN_SOURCE_DB_URL / ALIGN_TARGET_DB_URL 로 접속 정보를 덮어쓸 수 있다 — CI 의
  자체 검증(align_test_privs_selftest.sh)이 쓰는 경로이고, 평소에는 쓸 일이 없다.
============================================================================
"""
from __future__ import annotations

import argparse, collections, datetime, json, os, re, subprocess, sys
from urllib.parse import urlsplit

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

API_ROLES = ["PUBLIC", "anon", "authenticated", "service_role"]
OWNER = "postgres"                       # 우리 객체의 소유자이자 기본 권한의 주체
GUARD_TRIGGER = "spatial_ref_sys_guard"
GUARD_MIGRATION = os.path.join(ROOT, "supabase", "migrations",
                               "20260915100000_spatial_ref_sys_write_guard.sql")

# ACL 한 글자 표기(pg 의 aclitem 과 같은 글자) — 차이를 한 줄로 보여 줄 때 쓴다.
ABBR = {"SELECT": "r", "INSERT": "a", "UPDATE": "w", "DELETE": "d", "TRUNCATE": "D",
        "REFERENCES": "x", "TRIGGER": "t", "MAINTAIN": "m", "USAGE": "U", "EXECUTE": "X"}
ABBR_ORDER = "arwdDxtmUX"

# ── 카탈로그 추출(읽기 전용) ────────────────────────────────────────────────
# search_path 를 비워 형 이름·함수 시그니처가 양쪽에서 같은 꼴(스키마 한정)로 나오게 한다.
# NULL ACL 은 '기본값' 이라는 뜻이므로 acldefault 로 풀어서 비교한다.
EXTRACT_SQL = r"""
set search_path = '';
with ext as (select classid, objid from pg_catalog.pg_depend where deptype = 'e'),
nsp as (select oid, nspname, nspowner, nspacl from pg_catalog.pg_namespace where nspname in ('public', 'app')),
fn as (
  select n.nspname as schema, p.proname as name,
         (select coalesce(string_agg(pg_catalog.format_type(a.t, null), ',' order by a.ord), '')
            from unnest(p.proargtypes::oid[]) with ordinality as a(t, ord)) as argtypes,
         p.oid::regprocedure::text as regproc,
         pg_catalog.pg_get_userbyid(p.proowner) as owner,
         md5(p.prosrc) as src_md5,
         (select coalesce(jsonb_agg(jsonb_build_object(
                   'grantee', case when a.grantee = 0 then 'PUBLIC' else pg_catalog.pg_get_userbyid(a.grantee) end,
                   'priv', a.privilege_type, 'grantable', a.is_grantable)), '[]'::jsonb)
            from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a) as acl
    from pg_catalog.pg_proc p join nsp n on n.oid = p.pronamespace
   where not exists (select 1 from ext e where e.classid = 'pg_catalog.pg_proc'::regclass and e.objid = p.oid)
),
rel as (
  select n.nspname as schema, c.relname as name, c.relkind::text as kind,
         pg_catalog.pg_get_userbyid(c.relowner) as owner,
         c.relrowsecurity as rls, c.relforcerowsecurity as force_rls,
         (select coalesce(jsonb_agg(jsonb_build_object(
                   'grantee', case when a.grantee = 0 then 'PUBLIC' else pg_catalog.pg_get_userbyid(a.grantee) end,
                   'priv', a.privilege_type, 'grantable', a.is_grantable)), '[]'::jsonb)
            from aclexplode(coalesce(c.relacl, acldefault(case when c.relkind = 'S' then 's'::"char" else 'r'::"char" end, c.relowner))) a) as acl,
         (select coalesce(jsonb_agg(jsonb_build_object(
                   'col', at.attname,
                   'grantee', case when a.grantee = 0 then 'PUBLIC' else pg_catalog.pg_get_userbyid(a.grantee) end,
                   'priv', a.privilege_type, 'grantable', a.is_grantable)), '[]'::jsonb)
            from pg_catalog.pg_attribute at, aclexplode(at.attacl) a
           where at.attrelid = c.oid and at.attnum > 0 and not at.attisdropped and at.attacl is not null) as col_acl,
         (select coalesce(jsonb_agg(at.attname order by at.attnum), '[]'::jsonb)
            from pg_catalog.pg_attribute at where at.attrelid = c.oid and at.attnum > 0 and not at.attisdropped) as cols,
         (select coalesce(jsonb_agg(jsonb_build_object(
                   'name', pol.polname, 'cmd', pol.polcmd::text, 'permissive', pol.polpermissive,
                   'roles', (select coalesce(jsonb_agg(case when r = 0 then 'PUBLIC' else pg_catalog.pg_get_userbyid(r) end order by r), '[]'::jsonb) from unnest(pol.polroles) r),
                   'qual', pg_catalog.pg_get_expr(pol.polqual, pol.polrelid),
                   'check', pg_catalog.pg_get_expr(pol.polwithcheck, pol.polrelid))), '[]'::jsonb)
            from pg_catalog.pg_policy pol where pol.polrelid = c.oid) as policies,
         case when c.relkind in ('v', 'm') then md5(pg_catalog.pg_get_viewdef(c.oid)) end as view_md5
    from pg_catalog.pg_class c join nsp n on n.oid = c.relnamespace
   where c.relkind in ('r', 'p', 'v', 'm', 'S', 'f')
     and not exists (select 1 from ext e where e.classid = 'pg_catalog.pg_class'::regclass and e.objid = c.oid)
),
sch as (
  select n.nspname as schema,
         (select coalesce(jsonb_agg(jsonb_build_object(
                   'grantee', case when a.grantee = 0 then 'PUBLIC' else pg_catalog.pg_get_userbyid(a.grantee) end,
                   'priv', a.privilege_type, 'grantable', a.is_grantable)), '[]'::jsonb)
            from aclexplode(coalesce(n.nspacl, acldefault('n', n.nspowner))) a) as acl
    from nsp n
),
dacl as (
  select pg_catalog.pg_get_userbyid(d.defaclrole) as role,
         coalesce((select nspname from pg_catalog.pg_namespace where oid = d.defaclnamespace), '') as schema,
         d.defaclobjtype::text as objtype,
         (select coalesce(jsonb_agg(jsonb_build_object(
                   'grantee', case when a.grantee = 0 then 'PUBLIC' else pg_catalog.pg_get_userbyid(a.grantee) end,
                   'priv', a.privilege_type, 'grantable', a.is_grantable)), '[]'::jsonb)
            from aclexplode(d.defaclacl) a) as acl
    from pg_catalog.pg_default_acl d
),
trg as (
  select n.nspname as schema, c.relname as rel, t.tgname as name
    from pg_catalog.pg_trigger t
    join pg_catalog.pg_class c on c.oid = t.tgrelid
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
   where not t.tgisinternal and n.nspname in ('public', 'app')
)
select jsonb_build_object(
  'functions',   (select coalesce(jsonb_agg(to_jsonb(fn)), '[]'::jsonb) from fn),
  'relations',   (select coalesce(jsonb_agg(to_jsonb(rel)), '[]'::jsonb) from rel),
  'schemas',     (select coalesce(jsonb_agg(to_jsonb(sch)), '[]'::jsonb) from sch),
  'default_acl', (select coalesce(jsonb_agg(to_jsonb(dacl)), '[]'::jsonb) from dacl),
  'triggers',    (select coalesce(jsonb_agg(to_jsonb(trg)), '[]'::jsonb) from trg),
  'has_srs',     pg_catalog.to_regclass('public.spatial_ref_sys') is not null
);
"""

# ── 읽기 점검(데이터 무변화) ────────────────────────────────────────────────
# anon / authenticated 로 public 의 모든 테이블·뷰를 '부여된 컬럼만' 골라 읽어 보고,
# 결과(ok / SELECT 권한 없음 / 오류 문구)를 모은다. 권한을 좁힌 뒤 RLS 정책이나 뷰
# 안쪽에서 permission denied 가 새로 생기는지 — 즉 기준에는 없는 실패가 대상에만
# 생기는지 — 보려는 것이다. 행 내용은 밖으로 나가지 않는다.
#
# 임시 테이블을 쓰지 않는 이유: 기준 쪽은 읽기 전용 트랜잭션이라 CREATE 가 안 된다.
# 결과는 트랜잭션-로컬 설정값에 실어 꺼낸다.
SMOKE_SQL = r"""
do $smoke$
declare
  r record; v_uid uuid; v_tv integer; v_cols text; v_who text; v_n bigint;
  v_out jsonb := '{}'::jsonb;
begin
  -- authenticated 는 실제 계정 하나의 클레임으로 흉내 낸다(계정이 없으면 클레임 없이).
  begin
    execute $q$select id, token_version from public.users where status = 'active' order by created_at limit 1$q$
       into v_uid, v_tv;
  exception when others then
    v_uid := null;
  end;
  foreach v_who in array array['anon', 'authenticated'] loop
    for r in
      select c.oid, c.oid::regclass::text as rel
        from pg_class c join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public' and c.relkind in ('r', 'p', 'v', 'm')
         and not exists (select 1 from pg_depend d
                          where d.classid = 'pg_class'::regclass and d.objid = c.oid and d.deptype = 'e')
       order by 2
    loop
      select string_agg(quote_ident(a.attname), ', ' order by a.attnum) into v_cols
        from pg_attribute a
       where a.attrelid = r.oid and a.attnum > 0 and not a.attisdropped
         and has_column_privilege(v_who, r.oid, a.attnum, 'SELECT');
      if v_cols is null then
        v_out := v_out || jsonb_build_object(v_who || ' ' || r.rel, 'SELECT 권한 없음');
        continue;
      end if;
      begin
        if v_who = 'authenticated' and v_uid is not null then
          perform set_config('request.jwt.claims',
            json_build_object('sub', v_uid, 'role', 'authenticated', 'tv', v_tv)::text, true);
        else
          perform set_config('request.jwt.claims', json_build_object('role', v_who)::text, true);
        end if;
        execute format('set local role %I', v_who);
        execute format('select count(*) from (select %s from %s limit 200) s', v_cols, r.rel) into v_n;
        reset role;
        v_out := v_out || jsonb_build_object(v_who || ' ' || r.rel, 'ok');
      exception when others then
        reset role;
        v_out := v_out || jsonb_build_object(v_who || ' ' || r.rel, '오류 ' || sqlstate || ' ' || left(sqlerrm, 120));
      end;
    end loop;
  end loop;
  perform set_config('align.smoke', v_out::text, true);
end $smoke$;
select current_setting('align.smoke');
"""


def die(msg: str, code: int = 3):
    print(f"❌ {msg}", file=sys.stderr)
    sys.exit(code)


def scrub(s: str) -> str:
    """오류 문구에 연결문자열이 섞여 나가지 않게 가린다."""
    return re.sub(r"postgres(?:ql)?://\S+", "<연결문자열>", s)


def env_or_file(name: str, path: str) -> str | None:
    """환경 변수가 있으면 그것을, 없으면 env 파일의 `export NAME="…"` 줄에서 읽는다."""
    v = os.environ.get(name)
    if v:
        return v
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                m = re.match(r"\s*(?:export\s+)?" + re.escape(name) + r"=(.*)$", line.rstrip("\n"))
                if m:
                    v = m.group(1).strip()
                    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                        v = v[1:-1]
                    return v or None
    except OSError:
        return None
    return None


def label(url: str) -> str:
    """화면에 찍을 이름 — 프로젝트 ref(풀러 사용자명 postgres.<ref>) 또는 호스트/DB. 비밀번호는 싣지 않는다."""
    u = urlsplit(url)
    user = u.username or ""
    if "." in user:
        return user.split(".", 1)[1]
    return f"{u.hostname or '?'}:{u.port or 5432}{u.path or ''}"


def psql(url: str, sql: str, what: str, tolerate: bool = False) -> str | None:
    """sql 을 한 세션에서 실행하고 stdout 을 돌려준다."""
    env = dict(os.environ, PGCONNECT_TIMEOUT="20", PGAPPNAME="align_test_privs")
    p = subprocess.run(["psql", url, "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1", "-f", "-"],
                       input=sql, capture_output=True, text=True, env=env)
    if p.returncode != 0:
        if tolerate:
            return None
        die(f"{what} 실패:\n{scrub(p.stderr.strip())}")
    return p.stdout


def read_only(sql: str) -> str:
    return "begin transaction read only;\n" + sql + "\nrollback;\n"


def last_json(out: str, what: str):
    lines = [l for l in out.splitlines() if l.strip()]
    if not lines:
        die(f"{what}: 결과가 비어 있다")
    try:
        return json.loads(lines[-1])
    except ValueError:
        die(f"{what}: 결과를 해석할 수 없다 — {lines[-1][:200]}")


def extract(url: str, what: str, readonly: bool) -> dict:
    return last_json(psql(url, read_only(EXTRACT_SQL) if readonly else EXTRACT_SQL, f"{what} 카탈로그 추출"),
                     f"{what} 카탈로그 추출")


def fingerprint(url: str) -> str | None:
    out = psql(url, "select system_identifier::text || '/' || current_database() from pg_control_system();",
               "DB 식별", tolerate=True)
    return out.strip() if out else None


# ── 비교 ────────────────────────────────────────────────────────────────────
def qi(s: str) -> str:
    return '"' + s.replace('"', '""') + '"'


def role_sql(g: str) -> str:
    return "public" if g == "PUBLIC" else qi(g)


def fkey(f): return (f["schema"], f["name"], f["argtypes"])
def rkey(r): return (r["schema"], r["name"])
def tabset(acl, g): return frozenset((a["priv"], a["grantable"]) for a in acl if a["grantee"] == g)
def colset(acl, g): return frozenset((a["priv"], a["col"], a["grantable"]) for a in acl if a["grantee"] == g)


def brief(tab, col) -> str:
    """권한 집합을 'arwd+컬럼(r8,w6)' 꼴로."""
    letters = sorted({ABBR.get(p, "?") + ("*" if gr else "") for p, gr in tab}, key=lambda x: ABBR_ORDER.find(x[0]))
    s = "".join(letters)
    if col:
        per = collections.Counter(ABBR.get(p, "?") for p, _c, _g in col)
        s += ("+" if s else "") + "컬럼(" + ",".join(
            f"{k}{v}" for k, v in sorted(per.items(), key=lambda x: ABBR_ORDER.find(x[0]))) + ")"
    return s or "-"


def grant_stmts(kw: str, obj: str, g: str, tab, col) -> list[str]:
    out = []
    for grantable in (False, True):
        tail = " with grant option" if grantable else ""
        privs = sorted(p for p, gr in tab if gr == grantable)
        if privs:
            out.append(f"grant {', '.join(privs)} on {kw} {obj} to {role_sql(g)}{tail};")
        by_priv = collections.defaultdict(list)
        for p, c, gr in sorted(col):
            if gr != grantable:
                continue
            by_priv[p].append(c)
        for p, cs in sorted(by_priv.items()):
            out.append(f"grant {p} ({', '.join(qi(c) for c in cs)}) on {kw} {obj} to {role_sql(g)}{tail};")
    return out


class Plan:
    def __init__(self):
        self.sync: list[str] = []          # 대상에 적용할 문장
        self.undo: list[str] = []          # 적용 전 상태로 되돌리는 문장
        self.notes: list[str] = []         # 사람이 봐야 할 것
        self.items: list[tuple[str, str]] = []   # (분류, 한 줄 설명) — 권한 차이 목록
        self.count = collections.Counter()
        self.need_guard = False
        self.lag: list[tuple[str, int, list[str]]] = []   # 스키마 차이(참고)

    @property
    def differs(self) -> bool:
        return bool(self.items) or self.need_guard


TYPE_KW = {"f": "functions", "r": "tables", "S": "sequences", "T": "types", "n": "schemas"}


def build_plan(src: dict, tgt: dict) -> Plan:
    p = Plan()
    SF = {fkey(f): f for f in src["functions"]}; TF = {fkey(f): f for f in tgt["functions"]}
    SR = {rkey(r): r for r in src["relations"]}; TR = {rkey(r): r for r in tgt["relations"]}

    # 함수 EXECUTE
    p.sync.append("-- ── 함수 EXECUTE ──"); p.undo.append("-- ── 함수 EXECUTE ──")
    for k in sorted(set(SF) & set(TF)):
        s, t = SF[k], TF[k]
        if t["owner"] != OWNER:
            if any(tabset(s["acl"], g) != tabset(t["acl"], g) for g in API_ROLES):
                p.notes.append(f"함수 {t['regproc']}: 소유자가 {t['owner']} 라 건드리지 않음(권한은 다름)")
            continue
        for g in API_ROLES:
            a, b = tabset(s["acl"], g), tabset(t["acl"], g)
            if a == b:
                continue
            obj = t["regproc"]
            p.sync.append(f"revoke all privileges on routine {obj} from {role_sql(g)};")
            p.sync += grant_stmts("routine", obj, g, a, frozenset())
            p.undo.append(f"revoke all privileges on routine {obj} from {role_sql(g)};")
            p.undo += grant_stmts("routine", obj, g, b, frozenset())
            p.items.append(("함수", f"{obj}  {g}: {brief(b, ())} → {brief(a, ())}"))
            p.count["함수"] += 1

    # 테이블·뷰·시퀀스
    p.sync.append("\n-- ── 테이블·뷰·시퀀스 ──"); p.undo.append("\n-- ── 테이블·뷰·시퀀스 ──")
    for k in sorted(set(SR) & set(TR)):
        s, t = SR[k], TR[k]
        kind = "시퀀스" if t["kind"] == "S" else "뷰" if t["kind"] in "vm" else "테이블"
        kw = "sequence" if t["kind"] == "S" else "table"
        obj = f"{qi(k[0])}.{qi(k[1])}"
        have = set(t["cols"])
        for g in API_ROLES:
            a, b = tabset(s["acl"], g), tabset(t["acl"], g)
            ca, cb = colset(s["col_acl"], g), colset(t["col_acl"], g)
            # 대상에 없는 컬럼의 컬럼 권한은 맞출 수 없다 — 비교에서 빼고 알리기만 한다
            # (빼지 않으면 적용 뒤에도 영영 차이로 남는다). 컬럼은 마이그레이션이 채울 일이다.
            for priv, c, _gr in sorted(ca):
                if c not in have:
                    p.notes.append(f"{k[0]}.{k[1]}.{c}: 대상에 없는 컬럼 — {g} 의 {priv} 컬럼 권한은 건너뜀")
            ca = frozenset(x for x in ca if x[1] in have)
            if a == b and ca == cb:
                continue
            if t["owner"] != OWNER:
                p.notes.append(f"{kind} {k[0]}.{k[1]}: 소유자가 {t['owner']} 라 건드리지 않음({g} 권한은 다름)")
                continue
            p.sync.append(f"revoke all privileges on {kw} {obj} from {role_sql(g)};")
            p.sync += grant_stmts(kw, obj, g, a, ca)
            p.undo.append(f"revoke all privileges on {kw} {obj} from {role_sql(g)};")
            p.undo += grant_stmts(kw, obj, g, b, cb)
            p.items.append((kind, f"{k[0]}.{k[1]}  {g}: {brief(b, cb)} → {brief(a, ca)}"))
            p.count[kind] += 1

    # RLS 스위치 — 켜는 방향만
    p.sync.append("\n-- ── RLS ──"); p.undo.append("\n-- ── RLS ──")
    for k in sorted(set(SR) & set(TR)):
        s, t = SR[k], TR[k]
        if s["kind"] not in ("r", "p"):
            continue
        obj = f"{qi(k[0])}.{qi(k[1])}"
        if s["rls"] and not t["rls"]:
            p.sync.append(f"alter table {obj} enable row level security;")
            p.undo.append(f"alter table {obj} disable row level security;")
            p.items.append(("RLS", f"{k[0]}.{k[1]}  꺼짐 → 켜짐")); p.count["RLS"] += 1
        elif t["rls"] and not s["rls"]:
            p.notes.append(f"{k[0]}.{k[1]}: 대상은 RLS 켜짐·기준은 꺼짐 — 좁은 쪽을 그대로 둠")
        if s["force_rls"] and not t["force_rls"]:
            p.sync.append(f"alter table {obj} force row level security;")
            p.undo.append(f"alter table {obj} no force row level security;")
            p.items.append(("RLS", f"{k[0]}.{k[1]}  force 꺼짐 → 켜짐")); p.count["RLS"] += 1

    # 스키마 USAGE — 고치지 않고 알리기만(여기가 다르면 사람이 봐야 한다)
    for s in src["schemas"]:
        t = next((x for x in tgt["schemas"] if x["schema"] == s["schema"]), None)
        if t is None:
            p.notes.append(f"스키마 {s['schema']}: 대상에 없음")
            continue
        for g in API_ROLES:
            if tabset(s["acl"], g) != tabset(t["acl"], g):
                p.notes.append(f"스키마 {s['schema']}: {g} 권한이 다름({brief(tabset(t['acl'], g), ())} ↔ "
                               f"{brief(tabset(s['acl'], g), ())}) — 수동 확인")

    # 기본 권한(postgres 가 앞으로 만드는 객체)
    def dmap(j):
        return {(x["schema"], x["objtype"]): x["acl"] for x in j["default_acl"]
                if x["role"] == OWNER and x["schema"] in ("", "public", "app")}
    DS, DT = dmap(src), dmap(tgt)
    p.sync.append("\n-- ── 기본 권한 ──"); p.undo.append("\n-- ── 기본 권한 ──")
    for key in sorted(set(DS) | set(DT)):
        sch, typ = key
        if sch == "":
            # 전역 항목은 내장 기본값을 통째로 대체한다. 항목이 없으면 내장값 —
            # 함수라면 PUBLIC 에 EXECUTE 가 있다는 뜻이다. 스키마 항목으로는 이 내장값을
            # 못 걷어낸다(더해질 뿐) — 20260929050613 주석 참고.
            if typ != "f":
                p.notes.append(f"전역 기본 권한({TYPE_KW.get(typ, typ)}) 항목이 있음 — 수동 확인")
                continue
            s_pub = any(a["grantee"] == "PUBLIC" for a in DS[key]) if key in DS else True
            t_pub = any(a["grantee"] == "PUBLIC" for a in DT[key]) if key in DT else True
            if t_pub and not s_pub:
                p.sync.append(f"alter default privileges for role {qi(OWNER)} revoke execute on functions from public;")
                p.undo.append(f"alter default privileges for role {qi(OWNER)} grant execute on functions to public;")
                p.items.append(("기본 권한", "전역/functions  PUBLIC: X → -")); p.count["기본 권한"] += 1
            elif s_pub and not t_pub:
                p.notes.append("전역 함수 기본 권한: 대상이 기준보다 좁음 — 그대로 둠")
            continue
        sa, ta = DS.get(key, []), DT.get(key, [])
        head = f"alter default privileges for role {qi(OWNER)} in schema {qi(sch)}"
        for g in API_ROLES:
            a = {x["priv"] for x in sa if x["grantee"] == g}; b = {x["priv"] for x in ta if x["grantee"] == g}
            if a == b:
                continue
            what = TYPE_KW.get(typ, typ)
            if b - a:
                p.sync.append(f"{head} revoke {', '.join(sorted(b - a))} on {what} from {role_sql(g)};")
                p.undo.append(f"{head} grant {', '.join(sorted(b - a))} on {what} to {role_sql(g)};")
            if a - b:
                p.sync.append(f"{head} grant {', '.join(sorted(a - b))} on {what} to {role_sql(g)};")
                p.undo.append(f"{head} revoke {', '.join(sorted(a - b))} on {what} from {role_sql(g)};")
            fmt = lambda x: "".join(sorted((ABBR.get(v, "?") for v in x), key=ABBR_ORDER.find)) or "-"
            p.items.append(("기본 권한", f"{sch}/{what}  {g}: {fmt(b)} → {fmt(a)}")); p.count["기본 권한"] += 1

    # 확장 테이블 쓰기 가드
    s_trg = {t["name"] for t in src["triggers"] if (t["schema"], t["rel"]) == ("public", "spatial_ref_sys")}
    t_trg = {t["name"] for t in tgt["triggers"] if (t["schema"], t["rel"]) == ("public", "spatial_ref_sys")}
    if GUARD_TRIGGER in s_trg and GUARD_TRIGGER not in t_trg:
        if tgt.get("has_srs"):
            p.need_guard = True
            p.count["가드 트리거"] += 1
        else:
            p.notes.append("대상에 public.spatial_ref_sys 가 없음 — 가드 트리거는 건너뜀")
    for name in sorted(s_trg - t_trg - {GUARD_TRIGGER}):
        p.notes.append(f"spatial_ref_sys 의 트리거 {name}: 기준에만 있음 — 이 도구가 모르는 트리거라 수동 확인")

    # 스키마 차이(참고) — 고치지 않는다
    def names(keys, f=lambda k: ".".join(k[:2])): return sorted({f(k) for k in keys})
    lag = p.lag
    lag.append(("대상에 없는 함수", len(set(SF) - set(TF)), names(set(SF) - set(TF))))
    lag.append(("대상에 없는 테이블·뷰·시퀀스", len(set(SR) - set(TR)), names(set(SR) - set(TR))))
    strg = {(t["schema"], t["rel"], t["name"]) for t in src["triggers"]}
    ttrg = {(t["schema"], t["rel"], t["name"]) for t in tgt["triggers"]}
    miss_trg = {k for k in strg - ttrg if k[2] != GUARD_TRIGGER}
    lag.append(("대상에 없는 트리거", len(miss_trg), sorted(f"{k[1]}.{k[2]}" for k in miss_trg)))
    body = [k for k in set(SF) & set(TF) if SF[k]["src_md5"] != TF[k]["src_md5"]]
    lag.append(("본문이 다른 함수", len(body), names(body)))
    def polsig(r): return {x["name"]: (x["cmd"], x["permissive"], tuple(x["roles"]), x["qual"], x["check"]) for x in r["policies"]}
    pol = []
    for k in set(SR) & set(TR):
        a, b = polsig(SR[k]), polsig(TR[k])
        pol += [f"{k[1]}.{n}" for n in set(a) | set(b) if a.get(n) != b.get(n)]
    lag.append(("다른 RLS 정책", len(pol), sorted(pol)))
    views = [k for k in set(SR) & set(TR) if SR[k]["kind"] in "vm" and SR[k]["view_md5"] != TR[k]["view_md5"]]
    lag.append(("정의가 다른 뷰", len(views), names(views)))
    cols = [k for k in set(SR) & set(TR) if set(SR[k]["cols"]) != set(TR[k]["cols"])]
    lag.append(("컬럼 구성이 다른 테이블", len(cols), names(cols)))
    only_t = (set(TF) - set(SF)) | (set(TR) - set(SR))
    lag.append(("대상에만 있는 객체", len(only_t), names(only_t)))
    return p


def print_report(plan: Plan, src_label: str, tgt_label: str, n_fn: int, n_rel: int, verbose: bool):
    print(f"기준 {src_label}  →  대상 {tgt_label}")
    print(f"── 권한 (양쪽에 모두 있는 함수 {n_fn}개 · 테이블/뷰/시퀀스 {n_rel}개)")
    if not plan.differs:
        print("   차이 없음")
    else:
        parts = [f"{k} {v}건" for k, v in plan.count.items()]
        print("   " + " · ".join(parts))
        shown = plan.items if verbose else plan.items[:12]
        for kind, line in shown:
            print(f"   [{kind}] {line}")
        if len(plan.items) > len(shown):
            print(f"   … 외 {len(plan.items) - len(shown)}건 (-v 로 전부)")
        if plan.need_guard:
            print(f"   [가드 트리거] public.spatial_ref_sys 에 {GUARD_TRIGGER} 없음")
    lag = [(t, n, names) for t, n, names in plan.lag if n]
    print("── 스키마 차이 (참고 — 이 도구는 고치지 않는다)")
    if not lag:
        print("   없음")
    for title, n, names in lag:
        sample = ", ".join(names if verbose else names[:6]) + ("" if verbose or len(names) <= 6 else " …")
        print(f"   {title} {n}: {sample}")
    if plan.notes:
        print("── 확인이 필요한 것")
        for n in dict.fromkeys(plan.notes):      # 같은 문구는 한 번만
            print(f"   · {n}")


def guard_sql() -> str:
    try:
        with open(GUARD_MIGRATION, encoding="utf-8") as f:
            return f.read()
    except OSError:
        die(f"가드 마이그레이션 파일이 없다: {os.path.relpath(GUARD_MIGRATION, ROOT)}")


def smoke(url: str, what: str, prefix: str = "", readonly: bool = False) -> dict:
    """prefix(적용할 문장)를 같은 트랜잭션에서 먼저 실행한 뒤 읽기 점검을 하고 전부 롤백한다."""
    head = "begin transaction read only;\n" if readonly else "begin;\n"
    out = psql(url, head + prefix + "\n" + SMOKE_SQL + "\nrollback;\n", what)
    return last_json(out, what)


def main():
    ap = argparse.ArgumentParser(description="테스트 DB 의 API 롤 권한을 운영과 대조·정렬한다.")
    ap.add_argument("--apply", action="store_true", help="리허설 후 대상에 적용한다(없으면 대조만)")
    ap.add_argument("-v", "--verbose", action="store_true", help="차이를 전부 나열한다")
    ap.add_argument("--out", metavar="DIR", help="sync.sql·undo.sql 을 남길 폴더")
    ap.add_argument("--force", action="store_true",
                    help="리허설의 읽기 점검이 기준과 달라도 적용한다(차이를 직접 확인한 뒤에만)")
    args = ap.parse_args()

    src_url = os.environ.get("ALIGN_SOURCE_DB_URL") or env_or_file("SUPABASE_DB_URL", os.path.join(HERE, "backup.env"))
    tgt_url = os.environ.get("ALIGN_TARGET_DB_URL") or env_or_file("TEST_SUPABASE_DB_URL", os.path.join(HERE, "test-server.env"))
    if not src_url:
        die("기준 접속 정보가 없다 — scripts/backup.env 의 SUPABASE_DB_URL")
    if not tgt_url:
        die("대상 접속 정보가 없다 — scripts/test-server.env 의 TEST_SUPABASE_DB_URL")

    # 기준과 대상이 같은 DB 면 멈춘다 — 연결문자열과 서버 식별자 둘 다 본다.
    def where(u):
        s = urlsplit(u)
        return (s.username, s.hostname, s.port or 5432, s.path)
    if where(src_url) == where(tgt_url):
        die("기준과 대상의 접속 정보가 같다 — 대상은 테스트 DB 여야 한다")
    fs, ft = fingerprint(src_url), fingerprint(tgt_url)
    if fs and ft and fs == ft:
        die("기준과 대상이 같은 DB 다(서버 식별자·DB 이름 일치) — 대상은 테스트 DB 여야 한다")

    src = extract(src_url, "기준", readonly=True)
    tgt = extract(tgt_url, "대상", readonly=True)
    plan = build_plan(src, tgt)
    n_fn = len({fkey(f) for f in src["functions"]} & {fkey(f) for f in tgt["functions"]})
    n_rel = len({rkey(r) for r in src["relations"]} & {rkey(r) for r in tgt["relations"]})
    print_report(plan, label(src_url), label(tgt_url), n_fn, n_rel, args.verbose)

    if not args.apply:
        if plan.differs:
            print("❌ 권한이 기준과 다르다 — --apply 로 맞춘다")
            sys.exit(1)
        print("✅ 권한 일치")
        return
    if not plan.differs:
        print("✅ 권한 일치 — 적용할 것이 없다")
        return

    # ── 적용 ──────────────────────────────────────────────────────────────
    body = "\n".join(plan.sync) + "\n"
    if plan.need_guard:
        body += "\n-- ── 확장 테이블 쓰기 가드 (20260915100000) ──\n" + guard_sql() + "\n"
    out_dir = args.out or os.path.join(ROOT, "backups", "test-privs",
                                       datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ"))
    os.makedirs(out_dir, exist_ok=True)
    head = f"-- align_test_privs.py — 기준 {label(src_url)} → 대상 {label(tgt_url)}\n\\set ON_ERROR_STOP on\n"
    with open(os.path.join(out_dir, "sync.sql"), "w", encoding="utf-8") as f:
        f.write(head + body)
    with open(os.path.join(out_dir, "undo.sql"), "w", encoding="utf-8") as f:
        f.write(head.replace("align_test_privs.py", "align_test_privs.py 의 되돌리기(적용 전 상태로)")
                + "\n".join(plan.undo) + "\n"
                + ("\n-- 가드 트리거는 테이블 소유자만 뗄 수 있다. 끄려면 app.spatial_ref_sys_guard() 의\n"
                   "-- 본문을 `return null` 만 남기게 교체한다(20260915100000 주석 참고).\n" if plan.need_guard else ""))
    print(f"── 적용할 문장 {sum(1 for l in body.splitlines() if l.strip() and not l.startswith('--'))}줄 → {os.path.relpath(out_dir, os.getcwd())}/sync.sql")

    print("── 리허설: 대상에서 적용 → 읽기 점검 → 롤백")
    after = smoke(tgt_url, "대상 리허설", prefix="\\set ON_ERROR_STOP on\n" + body)
    ref = smoke(src_url, "기준 읽기 점검", readonly=True)
    common = sorted(set(after) & set(ref))
    bad = [(k, ref[k], after[k]) for k in common if ref[k] != after[k]]
    print(f"   읽기 점검 {len(common)}건 중 기준과 다른 것 {len(bad)}건")
    for k, a, b in bad[:20]:
        print(f"   · {k}: 기준 {a} / 대상 {b}")
    if bad and not args.force:
        print("❌ 적용하지 않았다 — 권한을 맞춘 뒤의 읽기 결과가 기준과 다르다.")
        print("   대상 스키마가 기준보다 뒤처져 있으면 생길 수 있다. 위 차이를 확인하고, 괜찮으면 --force.")
        sys.exit(2)

    print("── 적용")
    psql(tgt_url, "\\set ON_ERROR_STOP on\nbegin;\n" + body + "\ncommit;\n", "대상 적용")

    again = build_plan(src, extract(tgt_url, "대상", readonly=True))
    if again.differs:
        print_report(again, label(src_url), label(tgt_url), n_fn, n_rel, True)
        print("❌ 적용했지만 차이가 남았다 — 다른 롤이 준 권한이거나 소유자가 다른 객체일 수 있다")
        sys.exit(1)
    print(f"✅ 적용 완료 — 권한 일치. 되돌리기: {os.path.relpath(out_dir, os.getcwd())}/undo.sql")


if __name__ == "__main__":
    main()
