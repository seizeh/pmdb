// alertAdmins — 원장 위임(2026-09-21 통합) 이후의 계약.
//
// 종전 테스트는 로컬 스로틀(rate_limit_hit 판정 방향)을 재는 것이었다 — 그 로직은
// public.edge_alert_fire → app.ops_alarm_fire 로 이관되어 pgTAP(t21 §7)이 잰다.
// 여기 남는 계약은 둘: ① 올바른 인자로 정확히 한 번 위임한다 ② 어떤 실패에도
// throw 하지 않는다(알림 실패가 본 흐름을 깨면 안 된다).
//
// 실행: deno test supabase/functions/_shared/edge_alert_test.ts
import { assertEquals } from "jsr:@std/assert@1";
import { alertAdmins } from "./edge_alert.ts";

function fakeAdmin(rpcResult: { data?: unknown; error?: unknown }) {
  const calls: { fn: string; args: unknown }[] = [];
  return {
    calls,
    rpc(fn: string, args: unknown) {
      calls.push({ fn, args });
      return Promise.resolve(rpcResult);
    },
  };
}

Deno.test("edge_alert_fire 에 키·제목·본문으로 정확히 한 번 위임한다", async () => {
  const admin = fakeAdmin({ data: 1, error: null });
  await alertAdmins(admin, "k", "t", "b");
  assertEquals(admin.calls.length, 1);
  assertEquals(admin.calls[0].fn, "edge_alert_fire");
  assertEquals(admin.calls[0].args, { p_key: "k", p_title: "t", p_body: "b" });
});

Deno.test("rpc 오류 응답에도 던지지 않는다", async () => {
  const admin = fakeAdmin({ data: null, error: { message: "boom" } });
  await alertAdmins(admin, "k", "t", "b"); // throw 시 테스트 실패
  assertEquals(admin.calls.length, 1);
});

Deno.test("rpc reject 에도 던지지 않는다", async () => {
  const admin = { rpc: () => Promise.reject(new Error("net")) };
  await alertAdmins(admin, "k", "t", "b"); // throw 시 테스트 실패
});
