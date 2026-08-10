#!/usr/bin/env python3
"""LOCALDATA 시설 CSV → sync-facilities 배치 전송.

사용법:
    export SYNC_SECRET=...            # Supabase 함수 시크릿과 같은 값
    export SUPABASE_FUNCTIONS_URL=https://<ref>.supabase.co/functions/v1
    ./scripts/sync_facilities.py ~/Desktop/localdata_폴더 [--dry-run]

⚠️ 폐업·휴업 행을 걸러내지 말 것. 전부 보내야 문 닫은 업소의 기존 행이
   is_open=false 로 내려간다(upsert_facilities 주석 참고).

⚠️ CSV 를 Excel 로 열지 말 것. 18자리 관리번호가 부동소수점으로 바뀌어 끝자리가
   유실되고('3.0000000492023002E+17'), '+' 로 시작하는 상호가 '#NAME?' 가 된다.
   이 스크립트는 원본 CSV(CP949)를 그대로 읽는다.
"""
from __future__ import annotations

import csv, io, json, os, sys, unicodedata, urllib.request, collections

# 파일명 조각 → facilities.category. LOCALDATA 배포본 이름이 조금씩 달라서
# 정확 일치가 아니라 포함으로 고른다.
CATEGORY_BY_KEYWORD = [
    ("동물병원",       "animal_hospital"),
    ("동물미용",       "grooming"),
    ("동물위탁",       "pet_hotel"),
    ("동물판매",       "pet_sales"),
]
BATCH = 500          # 함수 상한은 1000. 절반으로 둬서 타임아웃 여유를 남긴다.
COLS = ("관리번호", "사업장명", "도로명주소", "지번주소", "전화번호",
        "영업상태명", "인허가일자", "좌표정보(X)", "좌표정보(Y)")


def category_of(filename: str) -> str | None:
    # macOS 는 압축 해제 경로에 따라 파일명을 NFD 로 남긴다("동물" 이 자모로 분해된다).
    # 정규화하지 않으면 같은 글자인데 `in` 매칭이 조용히 실패한다 — 실제로 겪었다.
    name = unicodedata.normalize("NFC", filename)
    for kw, cat in CATEGORY_BY_KEYWORD:
        if kw in name:
            return cat
    return None


def read_rows(path: str, category: str) -> list[dict]:
    raw = open(path, "rb").read()
    for enc in ("cp949", "utf-8-sig", "utf-8"):
        try:
            text = raw.decode(enc)
            break
        except UnicodeDecodeError:
            continue
    else:
        raise SystemExit(f"{path}: 인코딩을 판별하지 못했습니다")

    rd = csv.reader(io.StringIO(text))
    header = next(rd)
    missing = [c for c in COLS if c not in header]
    if missing:
        raise SystemExit(f"{path}: 필요한 열이 없습니다 — {missing}")
    idx = {c: header.index(c) for c in COLS}

    out = []
    for r in rd:
        if len(r) <= max(idx.values()):
            continue
        ext = r[idx["관리번호"]].strip()
        if not ext:
            continue
        # 도로명주소가 없는 오래된 업소는 지번주소로 대체한다(초기 적재와 같은 규칙).
        addr = r[idx["도로명주소"]].strip() or r[idx["지번주소"]].strip()
        out.append({
            "category": category,
            "ext_id": ext,
            "name": r[idx["사업장명"]].strip(),
            "address": addr,
            "phone": r[idx["전화번호"]].strip(),
            "biz_status": r[idx["영업상태명"]].strip(),
            "license_date": r[idx["인허가일자"]].strip(),
            "x": r[idx["좌표정보(X)"]].strip(),
            "y": r[idx["좌표정보(Y)"]].strip(),
        })
    return out


def post(url: str, secret: str, rows: list[dict]) -> dict:
    req = urllib.request.Request(
        url,
        data=json.dumps({"rows": rows}).encode(),
        headers={"content-type": "application/json", "x-sync-secret": secret},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=120) as res:
        return json.loads(res.read())


def main() -> None:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    dry = "--dry-run" in sys.argv
    if not args:
        raise SystemExit(__doc__)
    folder = args[0]

    secret = os.environ.get("SYNC_SECRET", "")
    base = os.environ.get("SUPABASE_FUNCTIONS_URL", "").rstrip("/")
    if not dry and (not secret or not base):
        raise SystemExit("SYNC_SECRET / SUPABASE_FUNCTIONS_URL 환경변수가 필요합니다")
    url = f"{base}/sync-facilities"

    files = [f for f in sorted(os.listdir(folder)) if f.lower().endswith(".csv")]
    if not files:
        raise SystemExit(f"{folder}: CSV 가 없습니다")

    total = collections.Counter()
    for fn in files:
        cat = category_of(fn)
        if cat is None:
            print(f"  건너뜀(카테고리 미상): {fn}")
            continue
        rows = read_rows(os.path.join(folder, fn), cat)
        status = collections.Counter(r["biz_status"] for r in rows)
        print(f"\n{fn} → {cat}: {len(rows)}행  {dict(status.most_common(4))}")
        if not any("폐업" in s or "휴업" in s for s in status):
            print("  ⚠️ 폐업·휴업 행이 없습니다 — 필터링된 파일이면 기존 행이 안 내려갑니다")
        if dry:
            continue
        for i in range(0, len(rows), BATCH):
            chunk = rows[i:i + BATCH]
            res = post(url, secret, chunk)
            if "error" in res:
                raise SystemExit(f"  실패({i}~): {res}")
            for k, v in res.items():
                total[k] += v
            print(f"  {i + len(chunk):>6}/{len(rows)}  {res}", flush=True)

    print(f"\n합계: {dict(total)}" if not dry else "\n(dry-run — 전송하지 않음)")


if __name__ == "__main__":
    main()
