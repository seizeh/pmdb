// juso 응답 분류 — deno test supabase/functions/_shared/juso_test.ts
import { assertEquals } from "jsr:@std/assert@1";
import { jusoSearch, parseJuso, validKeyword, validPage } from "./juso.ts";

const body = (code: string, message: string, juso: unknown[] | null = [], total = 0) =>
  JSON.stringify({
    results: {
      common: { errorCode: code, errorMessage: message, totalCount: String(total) },
      juso,
    },
  });

Deno.test("정상 응답은 주소 목록으로 바꾼다 — 도로명이 빈 행은 버린다", () => {
  const out = parseJuso(
    200,
    body("0", "정상", [
      { roadAddr: "경기도 화성시 동탄대로 537", jibunAddr: "경기도 화성시 오산동 1023", admCd: "4159012000", zipNo: "18471" },
      { roadAddr: "", jibunAddr: "x" },
    ], 1),
  );
  assertEquals(out, {
    kind: "ok",
    total: 1,
    results: [{
      road_addr: "경기도 화성시 동탄대로 537",
      jibun_addr: "경기도 화성시 오산동 1023",
      adm_cd: "4159012000",
      zip_no: "18471",
    }],
  });
});

Deno.test("결과 없음도 정상이다", () => {
  assertEquals(parseJuso(200, body("0", "정상", [], 0)), { kind: "ok", results: [], total: 0 });
});

Deno.test("검색어 문제(E0013)는 input — juso 문구를 그대로 넘긴다", () => {
  const msg = "SQL 예약어 또는 특수문자( %,=,>,<,[,] )는 검색이 불가능 합니다.";
  assertEquals(parseJuso(200, body("E0013", msg, null)), { kind: "input", code: "E0013", message: msg });
});

Deno.test("키 문제(E0001·E0014)와 시스템 오류(-999)는 config", () => {
  for (const code of ["E0001", "E0014", "-999"]) {
    assertEquals(parseJuso(200, body(code, "오류", null)).kind, "config");
  }
});

Deno.test("HTTP 오류·JSON 아님·형식 이상은 unavailable", () => {
  assertEquals(parseJuso(503, "busy").kind, "unavailable");
  assertEquals(parseJuso(200, "<html>").kind, "unavailable");
  assertEquals(parseJuso(200, JSON.stringify({ results: {} })).kind, "unavailable");
});

Deno.test("검색어는 공백을 걷고 2~80자만", () => {
  assertEquals(validKeyword("  동탄대로 537 "), "동탄대로 537");
  assertEquals(validKeyword("동"), null);
  assertEquals(validKeyword(" "), null);
  assertEquals(validKeyword("가".repeat(81)), null);
  assertEquals(validKeyword(123), null);
});

Deno.test("페이지는 1~50 정수, 그 밖은 1", () => {
  assertEquals(validPage(3), 3);
  assertEquals(validPage("2"), 2);
  assertEquals(validPage(0), 1);
  assertEquals(validPage(51), 1);
  assertEquals(validPage(1.5), 1);
  assertEquals(validPage(undefined), 1);
});

Deno.test("네트워크 실패는 unavailable — 키가 실린 URL 을 문구에 남기지 않는다", async () => {
  const failing = (() => Promise.reject(new TypeError("dns error for https://x/?confmKey=SECRET"))) as typeof fetch;
  const out = await jusoSearch("동탄대로", 1, "SECRET", failing);
  assertEquals(out.kind, "unavailable");
  assertEquals(JSON.stringify(out).includes("SECRET"), false);
});

Deno.test("요청에 키·검색어·페이지·건수가 실린다", async () => {
  let seen: URL | null = null;
  const fake = ((u: URL) => {
    seen = u;
    return Promise.resolve(new Response(body("0", "정상", [], 0), { status: 200 }));
  }) as unknown as typeof fetch;
  await jusoSearch("동탄대로 537", 2, "K", fake);
  const q = (seen as unknown as URL).searchParams;
  assertEquals(q.get("confmKey"), "K");
  assertEquals(q.get("keyword"), "동탄대로 537");
  assertEquals(q.get("currentPage"), "2");
  assertEquals(q.get("countPerPage"), "20");
  assertEquals(q.get("resultType"), "json");
});
