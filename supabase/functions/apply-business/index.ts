// ============================================================================
// apply-business — 업체 등록 신청/재신청 (0025 §5)
//   POST { b_no, category, business_name, storefront_name?, prev_business_name?,
//          address_road, address_jibun?, region_code?, phone?, rep_name?,
//          email, license_path, extra_doc_path? }
//   Authorization: Bearer <login JWT>
//   → { ok, track, status, score }
//
//   국세청 상태를 서버가 직접 재조회(클라이언트 값 불신, 설계 원칙 1) 후
//   apply_business_profile RPC(service_role 전용)가 facilities 대조·점수·트랙 판정.
//   verify_jwt=false + 커스텀 JWT 수동 검증.
// ============================================================================
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders, json } from "../_shared/cors.ts";
import { bearer, rateLimited, verifyAccess } from "../_shared/auth.ts";
import { isValidBizNo, ntsStatus } from "../_shared/nts.ts";

const JWT_SECRET = Deno.env.get("JWT_SECRET");
const NTS_API_KEY = Deno.env.get("NTS_API_KEY");

const CATEGORIES = new Set([
  "pet_sales",
  "pet_hotel",
  "animal_hospital",
  "grooming",
  "other",
]);

// RPC 커스텀 에러 → HTTP 매핑 (signup 컨벤션)
const RPC_ERRORS: Record<string, number> = {
  extra_doc_required: 422,
  already_pending: 409,
  already_approved: 409,
  business_no_taken: 409,
  facility_taken: 409,
  nts_not_active: 403,
  user_not_found: 403,
  invalid_business_no: 400,
  invalid_category: 400,
  missing_fields: 400,
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (!JWT_SECRET || !NTS_API_KEY) return json({ error: "server_misconfigured" }, 500);

  const token = bearer(req);
  const claims = token ? await verifyAccess(token, JWT_SECRET) : null;
  const uid = typeof claims?.sub === "string" ? claims.sub : null;
  if (!uid) return json({ error: "unauthorized" }, 401);

  let p: Record<string, unknown>;
  try {
    p = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }
  const s = (k: string) => (typeof p[k] === "string" ? (p[k] as string).trim() : "");

  const bNo = s("b_no").replace(/\D/g, "");
  const category = s("category");
  const businessName = s("business_name");
  const email = s("email");
  const licensePath = s("license_path");
  const extraDocPath = s("extra_doc_path");

  if (!isValidBizNo(bNo)) return json({ error: "invalid_business_no" }, 400);
  if (!CATEGORIES.has(category)) return json({ error: "invalid_category" }, 400);
  if (!businessName || businessName.length > 100) {
    return json({ error: "invalid_business_name" }, 400);
  }
  if (!s("address_road")) return json({ error: "invalid_address" }, 400);
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return json({ error: "invalid_email" }, 400);
  // 서류 경로는 본인 폴더만 — 타인 파일 참조 시 승인·파기 흐름이 남의 파일을 다루게 됨
  if (!licensePath.startsWith(`${uid}/`)) return json({ error: "invalid_license_path" }, 400);
  if (extraDocPath && !extraDocPath.startsWith(`${uid}/`)) {
    return json({ error: "invalid_extra_doc_path" }, 400);
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );
  if (await rateLimited(supabase, `bizapply:${uid}`, 10, 3600)) {
    return json({ error: "rate_limited" }, 429);
  }

  // 국세청 서버측 재조회 — 계속사업자(01)만 진행 (0025 §3.1)
  const st = await ntsStatus(bNo, NTS_API_KEY);
  if (!st) return json({ error: "nts_unavailable" }, 502);
  if (!st.ok) {
    return json({
      error: "nts_not_active",
      status_code: st.statusCode,
      status_label: st.statusLabel,
      tax_type: st.taxType,
    }, 403);
  }

  const { data, error } = await supabase.rpc("apply_business_profile", {
    p_user: uid,
    p_b_no: bNo,
    p_category: category,
    p_business_name: businessName,
    p_storefront_name: s("storefront_name") || null,
    p_prev_name: s("prev_business_name") || null,
    p_address_road: s("address_road"),
    p_address_jibun: s("address_jibun") || null,
    p_region_code: s("region_code") || null,
    p_phone: s("phone") || null,
    p_rep_name: s("rep_name") || null,
    p_email: email,
    p_license_path: licensePath,
    p_extra_doc_path: extraDocPath || null,
    p_nts_status_code: st.statusCode,
  });

  if (error) {
    const msg = error.message ?? "";
    for (const [code, status] of Object.entries(RPC_ERRORS)) {
      if (msg.includes(code)) return json({ error: code }, status);
    }
    console.error("apply_business_profile failed", error);
    return json({ error: "internal_error" }, 500);
  }

  return json({ ok: true, ...data });
});
