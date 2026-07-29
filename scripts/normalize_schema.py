#!/usr/bin/env python3
"""
덤프 비교용 정규화 — 의미가 같은데 표기만 다른 것을 한 가지 꼴로 맞춘다.
stdin → stdout.

세 가지를 손본다.

1) DEFAULT ACL 블록 제거
   dump_schema.sh 는 `ALTER DEFAULT PRIVILEGES` 문을 걸러내지만(다른 롤의 기본권한은
   비수퍼유저 복원에서 실패한다) pg_dump 가 붙인 `-- Name: … Type: DEFAULT ACL` 머리말은
   남는다. 기본 권한이 걸린 쪽에만 이 껍데기가 생겨 가짜 차이가 된다.

2) IN 목록 표기 통일
   varchar 컬럼에 `check (status in ('a','b'))` 를 걸면 pg_dump 가

       (status)::text = ANY ((ARRAY['a'::character varying, …])::text[])        -- 배열 통째 캐스트
       (status)::text = ANY (ARRAY[('a'::character varying)::text, …])          -- 원소별 캐스트

   둘 중 하나로 뱉는다. 어느 쪽이 나오는지는 그 제약이 어떤 텍스트에서 만들어졌는지에
   달려 있어(원본 마이그레이션 문장 vs 덤프를 되먹인 문장) 리플레이 비교에서 가짜 차이를
   만든다. 원소별 꼴을 배열 통째 꼴로 모은다.

3) 빈 줄 압축 — 블록을 걷어내면 앞뒤 빈 줄 개수가 어긋난다. 의미가 없으므로
   연속 빈 줄은 한 줄로 모은다.

4) GRANT/REVOKE 나열 순서 정렬
   한 객체의 ACL 나열 순서는 권한을 어떤 차례로 준 적 있는지에 따라 갈린다(ACL 배열
   순서 그대로 덤프된다). 의미와 무관하므로 정렬해 맞춘다.
"""

import re
import sys

HEADER = re.compile(r"^-- Name: (?P<name>.+?); Type: (?P<type>[A-Z ]+); Schema: ")
FOLDED = re.compile(r"\(ARRAY\[(\([^()]*\)::text(?:, \([^()]*\)::text)*)\]\)")
ACL_LINE = re.compile(r"^(GRANT|REVOKE)\b")


def unfold(m: re.Match) -> str:
    elems = [
        re.sub(r"^\((.*)\)::text$", r"\1", e.strip())
        for e in m.group(1).split(", ")
    ]
    return "((ARRAY[" + ", ".join(elems) + "])::text[])"


def drop_default_acl_blocks(lines: list[str]) -> list[str]:
    """`--` / `-- Name: … DEFAULT ACL` / `--` 머리말과 뒤따르는 빈 줄을 통째로 버린다."""
    out: list[str] = []
    i = 0
    while i < len(lines):
        m = HEADER.match(lines[i])
        if m and m.group("type").strip() == "DEFAULT ACL":
            # 바로 앞의 `--` 구분선까지 되감는다
            while out and out[-1].strip() in ("--", ""):
                out.pop()
            i += 1
            if i < len(lines) and lines[i].strip() == "--":
                i += 1
            while i < len(lines) and lines[i].strip() == "":
                i += 1
            continue
        out.append(lines[i])
        i += 1
    return out


def main() -> int:
    lines = drop_default_acl_blocks(sys.stdin.readlines())
    run: list[str] = []
    blank = False
    for line in lines:
        if line.strip() == "":
            if blank:
                continue
            blank = True
        else:
            blank = False
        line = FOLDED.sub(unfold, line)
        if ACL_LINE.match(line):
            run.append(line)
            continue
        if run:
            sys.stdout.writelines(sorted(run))
            run = []
        sys.stdout.write(line)
    if run:
        sys.stdout.writelines(sorted(run))
    return 0


if __name__ == "__main__":
    sys.exit(main())
