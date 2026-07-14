// ============================================================================
// purge-business-docs — 업체 서류 보존기간 경과분 파기 (0025 §3.3·§8)
//   POST {}   header: x-purge-secret == BUSINESS_PURGE_SECRET
//   → { ok, purged, skipped }
//
//   app.business_doc_purge_queue 의 due 행(반려 6개월·탈퇴 30일·교체 30일)을 처리.
//   Storage 파일 삭제는 SQL 크론으로 불가(스토리지 API 필요) → 이 함수가 담당.
//   호출: pg_cron + pg_net(send-push 와 동일 패턴) 또는 수동. 큐 접근은 service_role
//   전용 RPC(business_doc_purge_take/done — app 스키마는 PostgREST 미노출).
//   재사용 중 파일 보호(pending/approved 참조분 파기 취소)는 take RPC 가 수행.
// ============================================================================
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders, json } from "../_shared/cors.ts";

const PURGE_SECRET = Deno.env.get("BUSINESS_PURGE_SECRET");

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (!PURGE_SECRET) return json({ error: "server_misconfigured" }, 500);
  if (req.headers.get("x-purge-secret") !== PURGE_SECRET) {
    return json({ error: "unauthorized" }, 401);
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data: due, error } = await supabase.rpc("business_doc_purge_take", {
    p_limit: 200,
  });
  if (error) {
    console.error("business_doc_purge_take failed", error);
    return json({ error: "internal_error" }, 500);
  }
  if (!due?.length) return json({ ok: true, purged: 0, skipped: 0 });

  const doneIds: number[] = [];
  let skipped = 0;
  // 개별 삭제 — 일부 실패해도 나머지 진행(실패분은 큐에 남아 다음 배치가 재시도)
  for (const row of due as { id: number; path: string }[]) {
    const { error: rmErr } = await supabase.storage.from("business-docs").remove([row.path]);
    if (rmErr) {
      console.error(`remove failed: ${row.path}`, rmErr);
      skipped++;
      continue;
    }
    doneIds.push(row.id);
  }

  if (doneIds.length) {
    const { error: doneErr } = await supabase.rpc("business_doc_purge_done", {
      p_ids: doneIds,
    });
    if (doneErr) {
      console.error("business_doc_purge_done failed", doneErr);
      return json({ error: "internal_error", purged: doneIds.length, skipped }, 500);
    }
  }

  return json({ ok: true, purged: doneIds.length, skipped });
});
