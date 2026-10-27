// webPushLink — 웹 알림이 열 주소를 맞게 만들고, 못 만들 때는 null 로 물러서는가.
//
// 실행: deno test supabase/functions/_shared/push_link_test.ts
import { assertEquals } from "jsr:@std/assert@1";
import { webPushLink } from "./push_link.ts";

const BASE = "https://app.pawmate.kr";
const ID = "ebac80fd-5d1a-4505-a8ef-373f25761caa";

Deno.test("게시글 알림 — /p/<id>", () => {
  assertEquals(webPushLink(BASE, "post", ID), `${BASE}/p/${ID}`);
});

Deno.test("사용자 알림(팔로우) — /u/<id>", () => {
  assertEquals(webPushLink(BASE, "user", ID), `${BASE}/u/${ID}`);
});

Deno.test("웹 화면이 없는 알림 — 채팅·공지·보안·초대는 링크 없음", () => {
  assertEquals(webPushLink(BASE, "chat_room", ID), null);
  assertEquals(webPushLink(BASE, null, null), null);
  assertEquals(webPushLink(BASE, "", ""), null);
  assertEquals(webPushLink(BASE, "facility", ID), null);
});

Deno.test("기준 주소 끝의 / 는 하나로 접는다", () => {
  assertEquals(webPushLink(`${BASE}/`, "post", ID), `${BASE}/p/${ID}`);
  assertEquals(webPushLink(`  ${BASE}//  `, "post", ID), `${BASE}/p/${ID}`);
});

Deno.test("하위 경로 배포도 그대로 이어 붙인다", () => {
  assertEquals(webPushLink("https://example.com/app", "post", ID), `https://example.com/app/p/${ID}`);
});

Deno.test("https 가 아니거나 비어 있으면 링크를 만들지 않는다 — FCM 이 발송을 거절하지 않게", () => {
  assertEquals(webPushLink("http://app.pawmate.kr", "post", ID), null);
  assertEquals(webPushLink("", "post", ID), null);
  assertEquals(webPushLink(undefined, "post", ID), null);
  assertEquals(webPushLink("app.pawmate.kr", "post", ID), null);
});

Deno.test("id 가 uuid 가 아니면 링크를 만들지 않는다", () => {
  assertEquals(webPushLink(BASE, "post", "not-a-uuid"), null);
  assertEquals(webPushLink(BASE, "post", `${ID}/../x`), null);
});
