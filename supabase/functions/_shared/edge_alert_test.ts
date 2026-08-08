// alertAdmins 스로틀 — rate_limit_hit 규약(true=허용/false=초과)을 올바로 읽는가.
// 반전 회귀(첫 알림 삼킴 + 2회째부터 무제한) 방지.
//
// 실행: deno test supabase/functions/_shared/edge_alert_test.ts
import { assertEquals } from "jsr:@std/assert@1";
import { alertAdmins } from "./edge_alert.ts";

// admin 클라이언트 페이크 — rpc 결과를 주입하고 notifications insert 를 기록한다.
function fakeAdmin(rpcResult: { data?: unknown; error?: unknown }) {
  const inserted: unknown[] = [];
  return {
    inserted,
    rpc: () => Promise.resolve(rpcResult),
    from(table: string) {
      if (table === "users") {
        return {
          select: () => ({
            eq: () => ({
              eq: () => Promise.resolve({ data: [{ id: "admin-1" }], error: null }),
            }),
          }),
        };
      }
      // notifications
      return {
        insert(rows: unknown[]) {
          inserted.push(...rows);
          return Promise.resolve({ error: null });
        },
      };
    },
  };
}

Deno.test("허용(true) — 창의 첫 호출은 발송된다", async () => {
  const admin = fakeAdmin({ data: true, error: null });
  await alertAdmins(admin, "k", "t", "b");
  assertEquals(admin.inserted.length, 1);
});

Deno.test("초과(false) — 30분 내 재호출은 스킵된다", async () => {
  const admin = fakeAdmin({ data: false, error: null });
  await alertAdmins(admin, "k", "t", "b");
  assertEquals(admin.inserted.length, 0);
});

Deno.test("리미터 오류 — fail-open 으로 발송된다", async () => {
  const admin = fakeAdmin({ data: null, error: { message: "boom" } });
  await alertAdmins(admin, "k", "t", "b");
  assertEquals(admin.inserted.length, 1);
});
