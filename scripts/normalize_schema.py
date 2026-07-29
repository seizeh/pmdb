#!/usr/bin/env python3
"""
덤프 비교용 정규화 — 의미가 같은데 표기만 다른 것을 한 가지 꼴로 맞춘다.
stdin → stdout.

`IN (…)` 목록의 표기가 두 갈래로 갈린다. varchar 컬럼에 대해

    check (status in ('a','b'))

를 파서가 어떻게 접었느냐에 따라 pg_dump 가

    (status)::text = ANY ((ARRAY['a'::character varying, 'b'::character varying])::text[])   -- 배열 통째 캐스트
    (status)::text = ANY (ARRAY[('a'::character varying)::text, ('b'::character varying)::text])  -- 원소별 캐스트

둘 중 하나로 뱉는다. 어느 쪽이 나오는지는 그 제약이 어떤 텍스트에서 만들어졌는지에
달려 있어서(원본 마이그레이션 문장 vs 덤프를 되먹인 문장) 리플레이 비교에서
가짜 차이를 만든다. 원소별 꼴을 배열 통째 꼴로 모아 준다.
"""

import re
import sys

# ARRAY[(x)::text, (y)::text] — 원소 안에 괄호가 없는 단순형만 다룬다(덤프가 뱉는 형태).
FOLDED = re.compile(r"\(ARRAY\[(\([^()]*\)::text(?:, \([^()]*\)::text)*)\]\)")


def unfold(m: re.Match) -> str:
    elems = [
        re.sub(r"^\((.*)\)::text$", r"\1", e.strip())
        for e in m.group(1).split(", ")
    ]
    return "((ARRAY[" + ", ".join(elems) + "])::text[])"


# 한 객체의 GRANT/REVOKE 나열 순서는 권한을 어떤 차례로 준 적 있는지에 따라 갈린다
# (ACL 배열 순서 그대로 덤프된다). 의미와 무관하므로 줄 단위로 정렬해 맞춘다.
ACL_LINE = re.compile(r"^(GRANT|REVOKE)\b")


def main() -> int:
    run: list[str] = []
    for line in sys.stdin:
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
