// ============================================================================
// juso-search — 업체 등록의 사업장 주소 검색 (0025 §4.2)
//   POST { keyword, page? }   Authorization: Bearer <login JWT>
//   → 200 { results: [{ road_addr, jibun_addr, adm_cd, zip_no }], total }
//     400 invalid_keyword            검색어가 2~80자가 아님(juso 를 부르지 않는다)
//     401 unauthorized
//     422 keyword_rejected {message} juso 가 검색어를 거절(문구는 사용자용 그대로)
//     429 rate_limited
//     502 juso_unavailable           juso 오류·키 문제 — 키 문제는 관리자 알림
//     500 server_misconfigured
//
//   승인키(JUSO_API_KEY)는 함수 시크릿에만 둔다 — 클라이언트에 실리면 공개
//   저장소·웹 JS 에서 꺼내 쓸 수 있다(배경은 _shared/juso.ts). 조회만 하고 DB 기록
//   없음. verify_jwt=false + 커스텀 JWT 수동 검증(check-business-no 패턴).
// ============================================================================
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { json, withCors } from "../_shared/cors.ts";
import { activeUid, rateLimited } from "../_shared/auth.ts";
import { alertAdmins } from "../_shared/edge_alert.ts";
import { jusoSearch, validKeyword, validPage } from "../_shared/juso.ts";

const JWT_SECRET = Deno.env.get("JWT_SECRET");
const JUSO_API_KEY = Deno.env.get("JUSO_API_KEY");

Deno.serve(withCors(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (!JWT_SECRET || !JUSO_API_KEY) return json({ error: "server_misconfigured" }, 500);

  // 서명·만료만 보면 정지된 계정과 회수된 토큰이 통과한다 — status/tv/lite 까지 본다.
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );
  const uid = await activeUid(req, JWT_SECRET, supabase);
  if (!uid) return json({ error: "unauthorized" }, 401);

  let p: { keyword?: unknown; page?: unknown };
  try {
    p = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }
  const keyword = validKeyword(p.keyword);
  if (!keyword) return json({ error: "invalid_keyword" }, 400);

  // 남용 방지: 계정당 60회/시간 (juso 쿼터 보호 — 검색은 버튼·엔터로만 나간다)
  if (await rateLimited(supabase, `juso:${uid}`, 60, 3600)) {
    return json({ error: "rate_limited" }, 429);
  }

  const out = await jusoSearch(keyword, validPage(p.page), JUSO_API_KEY);
  switch (out.kind) {
    case "ok":
      return json({ results: out.results, total: out.total });
    case "input":
      return json({ error: "keyword_rejected", message: out.message }, 422);
    case "config":
      // 키 만료·미승인 등 — 운영자가 고칠 일이다. 원장이 30분 쿨다운을 건다.
      await alertAdmins(
        supabase,
        "juso_config",
        "주소 검색(juso) 키 오류",
        `juso 가 ${out.code} 를 돌려줬습니다: ${out.message || "(문구 없음)"} — 함수 시크릿 JUSO_API_KEY 를 확인하세요.`,
      );
      return json({ error: "juso_unavailable" }, 502);
    case "unavailable":
      console.error("juso unavailable", out.detail);
      return json({ error: "juso_unavailable" }, 502);
  }
}));
