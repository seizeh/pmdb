// ============================================================================
// check-business-no — 사업자등록번호 국세청 상태 사전 확인 (0025 §3.2)
//   POST { b_no }   Authorization: Bearer <login JWT>
//   → { ok, status_code, status_label, tax_type }
//
//   업체등록 화면 1단계의 즉시 피드백용. 조회만 하고 DB 기록 없음(기록은 apply-business
//   가 서버측 재조회 값으로). verify_jwt=false + 커스텀 JWT 수동 검증(resolve-region 패턴).
// ============================================================================
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders, json } from "../_shared/cors.ts";
import { bearer, rateLimited, verifyAccess } from "../_shared/auth.ts";
import { isValidBizNo, ntsStatus } from "../_shared/nts.ts";

const JWT_SECRET = Deno.env.get("JWT_SECRET");
const NTS_API_KEY = Deno.env.get("NTS_API_KEY");

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (!JWT_SECRET || !NTS_API_KEY) return json({ error: "server_misconfigured" }, 500);

  const token = bearer(req);
  const claims = token ? await verifyAccess(token, JWT_SECRET) : null;
  const uid = typeof claims?.sub === "string" ? claims.sub : null;
  if (!uid) return json({ error: "unauthorized" }, 401);

  let p: { b_no?: string };
  try {
    p = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }
  const bNo = (p.b_no ?? "").replace(/\D/g, "");
  if (!isValidBizNo(bNo)) return json({ error: "invalid_business_no" }, 400);

  // 남용 방지: 계정당 30회/시간 (국세청 쿼터 보호)
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );
  if (await rateLimited(supabase, `ntscheck:${uid}`, 30, 3600)) {
    return json({ error: "rate_limited" }, 429);
  }

  const st = await ntsStatus(bNo, NTS_API_KEY);
  if (!st) return json({ error: "nts_unavailable" }, 502);

  return json({
    ok: st.ok,
    status_code: st.statusCode,
    status_label: st.statusLabel,
    tax_type: st.taxType,
  });
});
