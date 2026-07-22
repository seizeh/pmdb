// ============================================================================
// share-view — 공유 링크 뷰어: 토큰 → 로그인 없이 HTML 서빙 (0028 §3)
//   GET ?t=<token>            → 열람 페이지(HTML) + funnel 'share_view' 기록
//   GET ?t=<token>&go=store   → funnel 'store_click' 기록 후 스토어로 302
//
//   설치 전 가치 먼저(0028 원칙 2): 매장 미리보기(facility_preview)를 설치·가입
//   없이 보여주고, 설치 유도 버튼만 둔다. 후기 강요·가입 강제 없음.
//   kind='care_report' 는 P1(미용 전후 사진)에서 열린다 — 지금은 안내만.
//
//   verify_jwt=false 배포(공개 링크 — 게이트웨이 JWT 검증 없음). DB 접근은
//   service_role 전용 public RPC(share_view_load/click)로만 — app 스키마는
//   PostgREST 미노출이라 직접 못 읽고, RPC 가 검증·데이터·계측을 원자 처리한다.
//   개인 식별 없음(쿠키 미사용, IP·UA 미저장).
//
//   외부 노출 주소는 반드시 go.pawmate.kr(Worker 프록시) 경유 — supabase.co
//   공유 도메인은 게이트웨이가 HTML 을 차단한다(0028 §3.1 4차 개정).
// ============================================================================
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
// 스토어 링크 — 출시 전엔 미설정(버튼이 준비 중 안내로 대체됨)
const STORE_URL_IOS = Deno.env.get("STORE_URL_IOS") ?? "";
const STORE_URL_ANDROID = Deno.env.get("STORE_URL_ANDROID") ?? "";

const CATEGORY_LABELS: Record<string, string> = {
  animal_hospital: "동물병원",
  grooming: "미용",
  pet_hotel: "위탁·호텔",
  pet_sales: "분양",
  pet_cafe: "애견카페",
};

function esc(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

function html(body: string, status = 200): Response {
  return new Response(body, {
    status,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      // 토큰별 내용이 다르고 열람 계측이 있어 캐시 금지
      "Cache-Control": "no-store",
    },
  });
}

/// 공통 페이지 골격 — 모바일 우선, 외부 리소스 없음(폰트·JS 미사용).
function page(title: string, ogDesc: string, inner: string): string {
  return `<!doctype html>
<html lang="ko"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta property="og:title" content="${esc(title)}">
<meta property="og:description" content="${esc(ogDesc)}">
<meta property="og:type" content="website">
<title>${esc(title)} — PawMate</title>
<style>
  :root { --brown:#5a4e3a; --gold:#ac9466; --bg:#faf7f2; --card:#ffffff; --muted:#8a8375; }
  * { margin:0; padding:0; box-sizing:border-box; }
  body { font-family:-apple-system,BlinkMacSystemFont,"Apple SD Gothic Neo","Malgun Gothic",sans-serif;
         background:var(--bg); color:var(--brown); }
  .wrap { max-width:480px; margin:0 auto; padding:24px 20px 40px; }
  .brand { font-size:13px; font-weight:800; color:var(--gold); letter-spacing:.5px; margin-bottom:16px; }
  .card { background:var(--card); border-radius:20px; padding:24px 20px; box-shadow:0 2px 12px rgba(90,78,58,.08); }
  .hero { width:calc(100% + 40px); margin:-24px -20px 18px; height:200px; object-fit:cover;
          border-radius:20px 20px 0 0; display:block; }
  h1 { font-size:22px; font-weight:800; line-height:1.3; }
  .tags { margin:10px 0 4px; }
  .tag { display:inline-block; font-size:12px; font-weight:700; color:var(--gold);
         border:1px solid var(--gold); border-radius:999px; padding:3px 10px; margin-right:6px; }
  .rating { font-size:16px; font-weight:800; margin:12px 0 2px; }
  .rating small { font-weight:400; color:var(--muted); }
  .meta { font-size:14px; color:var(--muted); line-height:1.7; margin-top:10px; }
  .review { border-top:1px solid #efe9de; padding:14px 0; }
  .review .stars { color:var(--gold); font-size:13px; font-weight:700; }
  .incent { font-size:11px; font-weight:600; color:var(--muted); border:1px solid #e2dccd;
            border-radius:999px; padding:2px 8px; margin-left:8px; vertical-align:1px; }
  .review p { font-size:14px; line-height:1.6; margin-top:6px; word-break:break-all; }
  .section { font-size:14px; font-weight:800; margin:24px 0 8px; }
  .cta { display:block; text-align:center; background:var(--brown); color:#fff; text-decoration:none;
         font-size:16px; font-weight:800; border-radius:14px; padding:16px; margin-top:24px; }
  .cta.sub { background:transparent; color:var(--muted); font-weight:400; font-size:13px; padding:10px; }
  .notice { text-align:center; padding:48px 0 24px; }
  .notice h1 { font-size:18px; }
  .notice p { font-size:14px; color:var(--muted); margin-top:8px; line-height:1.6; }
</style></head>
<body><div class="wrap"><div class="brand">PawMate</div>${inner}</div></body></html>`;
}

function noticePage(title: string, msg: string, status: number): Response {
  return html(
    page(title, msg, `<div class="card notice"><h1>${esc(title)}</h1><p>${esc(msg)}</p></div>`),
    status,
  );
}

function starBar(rating: number): string {
  const n = Math.max(0, Math.min(5, Math.round(rating)));
  return "★".repeat(n) + "☆".repeat(5 - n);
}

Deno.serve(async (req) => {
  if (req.method !== "GET") return new Response("method not allowed", { status: 405 });
  const url = new URL(req.url);
  const token = url.searchParams.get("t") ?? "";
  if (!/^[0-9a-f]{32}$/.test(token)) {
    return noticePage("잘못된 링크예요", "링크 주소를 다시 확인해 주세요.", 404);
  }

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE);

  // 스토어 이동 — 클릭 계측 후 302 (UA 로 스토어 분기, 미출시 시 안내 페이지)
  if (url.searchParams.get("go") === "store") {
    const { data: ok } = await admin.rpc("share_view_click", { p_token: token });
    if (!ok) {
      return noticePage("링크를 찾을 수 없어요", "만료되었거나 회수된 링크예요.", 404);
    }
    const ua = req.headers.get("user-agent") ?? "";
    const store = /iphone|ipad|ipod|macintosh/i.test(ua) ? STORE_URL_IOS : STORE_URL_ANDROID;
    if (!store) {
      return noticePage("앱 출시 준비 중이에요", "곧 스토어에서 만나요. 조금만 기다려 주세요!", 200);
    }
    return new Response(null, { status: 302, headers: { Location: store } });
  }

  const { data, error } = await admin.rpc("share_view_load", { p_token: token });
  if (error || !data) {
    return noticePage("잠시 후 다시 시도해 주세요", "페이지를 불러오지 못했어요.", 500);
  }
  if (data.status === "expired") {
    return noticePage("만료된 링크예요", "매장에 새 링크를 요청해 주세요.", 410);
  }
  if (data.status !== "ok") {
    return noticePage("링크를 찾을 수 없어요", "회수되었거나 존재하지 않는 링크예요.", 404);
  }
  if (data.kind !== "facility_preview") {
    // care_report 등 P1 kind — 링크는 유효하나 뷰어 본문은 P1 에서.
    return noticePage("준비 중인 콘텐츠예요", "앱에서 곧 만나볼 수 있어요.", 200);
  }

  const fac = data.facility ?? {};
  const catLabel = CATEGORY_LABELS[String(fac.category)] ?? String(fac.category ?? "");
  const rating = Number(fac.avg_rating ?? 0);
  const reviewCount = Number(fac.review_count ?? 0);
  const name = String(fac.name ?? "매장");
  const ogDesc = rating > 0
    ? `★${rating.toFixed(1)} · 후기 ${reviewCount}개 · ${catLabel}`
    : `우리 동네 ${catLabel} — PawMate 에서 확인하세요`;

  const reviews: Array<{ rating: number; content: string | null; has_incentive?: boolean }> =
    data.reviews ?? [];
  const reviewHtml = reviews.length === 0
    ? `<p class="meta">아직 후기가 없어요. 첫 후기의 주인공이 되어 주세요!</p>`
    : reviews.map((r) => `
      <div class="review">
        <span class="stars">${starBar(Number(r.rating))}</span>${
          r.has_incentive ? '<span class="incent">업체 혜택 받고 작성</span>' : ""
        }
        <p>${esc(String(r.content ?? "")).slice(0, 400)}</p>
      </div>`).join("");

  // 인증 업체 대표 사진 히어로 — 지도 상세와 동일한 세로 초점(alignY -1~1 → 0~100%).
  // 콜드스타트(후기 0개) 매장도 사진 한 장으로 명함 이상이 되게 (0028 §3).
  const photoUrl = fac.photo_url ? String(fac.photo_url) : null;
  const alignPct = Math.round(((Number(fac.photo_align_y ?? 0) + 1) / 2) * 100);
  const heroHtml = photoUrl
    ? `<img class="hero" src="${esc(photoUrl)}" alt="" style="object-position:center ${alignPct}%">`
    : "";
  const hours = fac.business_hours ? String(fac.business_hours) : null;

  const inner = `
  <div class="card">
    ${heroHtml}
    <h1>${esc(name)}</h1>
    <div class="tags"><span class="tag">${esc(catLabel)}</span>${fac.is_open === false ? '<span class="tag">휴업</span>' : ""}</div>
    ${rating > 0
      ? `<div class="rating">★ ${rating.toFixed(1)} <small>· 후기 ${reviewCount}개</small></div>`
      : ""}
    <div class="meta">
      ${fac.address ? `📍 ${esc(String(fac.address))}<br>` : ""}
      ${hours ? `🕐 ${esc(hours)}<br>` : ""}
      ${fac.phone ? `📞 ${esc(String(fac.phone))}` : ""}
    </div>
    <div class="section">방문 후기</div>
    ${reviewHtml}
  </div>
  <a class="cta" href="?t=${token}&amp;go=store">PawMate 앱에서 동네 반려 소식 보기</a>
  <a class="cta sub" href="?t=${token}&amp;go=store">후기 작성도 앱에서 할 수 있어요</a>`;

  return html(page(name, ogDesc, inner));
});
