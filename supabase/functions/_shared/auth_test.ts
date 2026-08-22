// clientIpKey — 레이트리밋 키에 **원본 IP 가 절대 실리지 않는가.**
//
// 이 파일이 지키는 건 성능이나 정확도가 아니라 **약속**이다. 개인정보처리방침이
// "IP 주소(SHA-256 해시 후 저장)" 라고 단서 없이 적고 있는데, 종전에는
// app.rate_limits.bucket 이 `login:ip:139.178.129.10:29787996` 처럼 평문이었다.
//
// 실행: deno test supabase/functions/_shared/auth_test.ts
import { assertEquals, assertNotEquals, assertStringIncludes } from "jsr:@std/assert@1";
import { clientIpKey, sha256Hex } from "./auth.ts";

const reqWith = (headers: Record<string, string>) => new Request("https://x.test/", { headers });

Deno.test("헤더가 있으면 sha256 16진 64자를 돌려준다", async () => {
  const key = await clientIpKey(reqWith({ "cf-connecting-ip": "139.178.129.10" }));
  assertEquals(key?.length, 64);
  assertEquals(/^[0-9a-f]{64}$/.test(key!), true);
});

Deno.test("돌려준 값에 원본 IP 가 들어 있지 않다", async () => {
  // 이 단언이 이 파일의 존재 이유다. 버킷 키는 이 값을 그대로 문자열에 박으므로,
  // 여기에 원본이 섞이면 그대로 app.rate_limits 에 평문으로 남는다.
  const ip = "139.178.129.10";
  const key = await clientIpKey(reqWith({ "cf-connecting-ip": ip }));
  assertEquals(key!.includes(ip), false);
  assertEquals(key!.includes("139"), false, "옥텟 조각도 남으면 안 된다");
  assertNotEquals(key, ip);
});

Deno.test("auth_logs 와 같은 해시다 — 두 곳을 맞대 볼 수 있어야 한다", async () => {
  // record_auth_log 는 이 값을 그대로 p_ip_hash 로 받는다. 알고리즘이 갈리면
  // 같은 접속인지 대조할 수 없고, 종전 auth_logs 행과도 이어지지 않는다.
  const ip = "115.91.115.38";
  assertEquals(await clientIpKey(reqWith({ "cf-connecting-ip": ip })), await sha256Hex(ip));
});

Deno.test("같은 IP 는 같은 키 — 레이트리밋이 성립하려면 결정적이어야 한다", async () => {
  const a = await clientIpKey(reqWith({ "cf-connecting-ip": "1.2.3.4" }));
  const b = await clientIpKey(reqWith({ "cf-connecting-ip": "1.2.3.4" }));
  assertEquals(a, b);
});

Deno.test("다른 IP 는 다른 키 — 한 버킷으로 뭉치면 상한이 무의미해진다", async () => {
  const a = await clientIpKey(reqWith({ "cf-connecting-ip": "1.2.3.4" }));
  const b = await clientIpKey(reqWith({ "cf-connecting-ip": "1.2.3.5" }));
  assertNotEquals(a, b);
});

Deno.test("공백은 다듬는다 — 같은 출처가 다른 버킷으로 갈리면 안 된다", async () => {
  const a = await clientIpKey(reqWith({ "cf-connecting-ip": " 1.2.3.4 " }));
  const b = await clientIpKey(reqWith({ "cf-connecting-ip": "1.2.3.4" }));
  assertEquals(a, b);
});

Deno.test("헤더가 없으면 null — 폴백하지 않는다", async () => {
  // 폴백이 곧 우회로다(ADR-0011 증상 4). null 이면 호출부가 IP 버킷을 건너뛰고
  // 스푸핑 불가한 1차 버킷과 전역 상한이 받는다.
  assertEquals(await clientIpKey(reqWith({})), null);
  assertEquals(await clientIpKey(reqWith({ "cf-connecting-ip": "" })), null);
  assertEquals(await clientIpKey(reqWith({ "cf-connecting-ip": "   " })), null);
});

Deno.test("x-forwarded-for / x-real-ip 는 쳐다보지 않는다", async () => {
  // 위조 가능한 헤더다. 종전 폴백을 지운 이유이기도 하다(0031 §3.7).
  const key = await clientIpKey(reqWith({
    "x-forwarded-for": "9.9.9.9",
    "x-real-ip": "8.8.8.8",
  }));
  assertEquals(key, null);
});

Deno.test("버킷 키에 박아도 평문이 남지 않는다(실사용 형태)", async () => {
  const ip = "139.178.129.10";
  const bucket = `login:ip:${await clientIpKey(reqWith({ "cf-connecting-ip": ip }))}`;
  assertStringIncludes(bucket, "login:ip:");
  assertEquals(bucket.includes(ip), false);
});
