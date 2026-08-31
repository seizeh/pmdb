// ============================================================================
// sync-facilities — LOCALDATA 시설 배치 적재 (0021 §4)
//   POST { rows: [...] }   헤더: x-sync-secret
//   → public.upsert_facilities RPC(service_role). verify_jwt=false.
//
//   0021 은 이 함수가 CSV 를 직접 내려받는 그림이었다. 그렇게 하지 않는 이유:
//   LOCALDATA 배포본은 카테고리당 3~4 MB CP949 CSV 이고 4종을 합치면 6만 행이다.
//   엣지 런타임에서 내려받아 디코딩·파싱하면 메모리·실행시간 한계에 걸리고,
//   실패해도 어디까지 처리됐는지 알 수 없다. 그래서 **파싱은 호출자(로컬 스크립트)
//   가 하고 이 함수는 검증된 배치만 받는다.** 재시도·부분 진행이 호출자 쪽에서
//   자연스럽게 처리된다.
//
//   ⚠️ 폐업·휴업 행을 걸러서 보내지 말 것. 전부 보내야 문 닫은 업소의 기존 행이
//   is_open=false 로 내려간다(자세한 이유는 upsert_facilities 주석).
// ============================================================================
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders, json } from "../_shared/cors.ts";
import { secretEq } from "../_shared/auth.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SYNC_SECRET = Deno.env.get("SYNC_SECRET");

// 한 요청당 행 수 상한. 초과분은 호출자가 나눠 보낸다 — 한 번에 다 넣으려다
// 타임아웃으로 통째 실패하는 것보다 낫다.
const MAX_ROWS = 1000;

const CATEGORIES = new Set([
  "animal_hospital",
  "grooming",
  "pet_hotel",
  "pet_sales",
]);

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (!SYNC_SECRET) return json({ error: "server_misconfigured" }, 500);

  const given = req.headers.get("x-sync-secret") ?? "";
  if (!secretEq(given, SYNC_SECRET)) return json({ error: "unauthorized" }, 401);

  let body: { rows?: unknown };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  const rows = body.rows;
  if (!Array.isArray(rows)) return json({ error: "rows_required" }, 400);
  if (rows.length === 0) return json({ inserted: 0, updated: 0, skipped: 0 });
  if (rows.length > MAX_ROWS) {
    return json({ error: "too_many_rows", max: MAX_ROWS, got: rows.length }, 400);
  }

  // 카테고리는 enum 이라 잘못 오면 RPC 가 통째로 실패한다 — 여기서 먼저 거른다.
  const bad = rows.findIndex((r: any) => !r || !CATEGORIES.has(r.category));
  if (bad >= 0) {
    return json({ error: "bad_category", index: bad, value: (rows[bad] as any)?.category }, 400);
  }
  const missing = rows.findIndex((r: any) => !String(r.ext_id ?? "").trim());
  if (missing >= 0) return json({ error: "ext_id_required", index: missing }, 400);

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE);
  const { data, error } = await admin.rpc("upsert_facilities", { p_rows: rows });
  if (error) {
    console.error("upsert_facilities failed", error);
    return json({ error: "upsert_failed", detail: String(error.message ?? error).slice(0, 200) }, 500);
  }
  return json(data ?? {});
});
