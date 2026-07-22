// ============================================================================
// share-view — 공유 링크 뷰어: 토큰 → 로그인 없이 HTML 서빙 (0028 §3)
//   GET ?t=<token>            → 열람 페이지(HTML) + funnel 'share_view' 기록
//   GET ?t=<token>&go=store   → funnel 'store_click' 기록 후 스토어로 302
//
//   설치 전 가치 먼저(0028 원칙 2): 매장 미리보기(facility_preview)를 설치·가입
//   없이 보여주고, 설치 유도 버튼만 둔다. 후기 강요·가입 강제 없음.
//   kind='care_report' 는 P1(미용 전후 사진)에서 열린다 — 지금은 안내만.
//
//   디자인은 앱과 같은 언어 — app_palette 라이트 값, 시설 상세 히어로 문법
//   (라운드 18 + 하단 점진 블러 + 스크림 위 정보), 업종색 칩, ★ #FFB300.
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

// 카테고리 라벨·색 — 앱 지도 칩(_facilityCats)과 동일.
const CATEGORIES: Record<string, { label: string; color: string }> = {
  animal_hospital: { label: "동물병원", color: "#EF5350" },
  grooming: { label: "미용", color: "#AB47BC" },
  pet_hotel: { label: "위탁·호텔", color: "#42A5F5" },
  pet_sales: { label: "분양", color: "#66BB6A" },
  pet_cafe: { label: "애견카페", color: "#FF9800" },
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
/// 색은 앱 app_palette 라이트 값 그대로.
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
  :root { --primary:#AD9466; --primary-dark:#5A4E3A; --primary-soft:#D9CBA8;
          --cream:#F5EFE3; --surface:#FFFFFF; --surface-muted:#FAF6EC;
          --border:#E5DDD0; --text:#5A4E3A; --text2:#8C8273; --text3:#B6AC9A;
          --on-primary:#FFFBF1; --star:#FFB300; }
  * { margin:0; padding:0; box-sizing:border-box; }
  body { font-family:-apple-system,BlinkMacSystemFont,"Apple SD Gothic Neo","Malgun Gothic",sans-serif;
         background:var(--cream); color:var(--text); }
  .wrap { max-width:480px; margin:0 auto; padding:20px 20px 40px; }
  .brand { font-size:14px; font-weight:800; color:var(--primary); letter-spacing:.5px; margin-bottom:14px; }

  /* 히어로 — 앱 시설 상세와 같은 문법: 라운드 18, 하단 점진 블러 + 스크림 위 정보 */
  .hero { position:relative; border-radius:18px; overflow:hidden; height:230px; margin-bottom:14px; }
  .hero > img.photo { width:100%; height:100%; object-fit:cover; display:block; }
  .hero .blurband { position:absolute; inset:0;
    backdrop-filter:blur(14px); -webkit-backdrop-filter:blur(14px);
    mask-image:linear-gradient(transparent 45%, black 88%);
    -webkit-mask-image:linear-gradient(transparent 45%, black 88%); }
  .hero .scrim { position:absolute; left:0; right:0; bottom:0; height:120px;
    background:linear-gradient(transparent, rgba(0,0,0,.4)); }
  .hero .info { position:absolute; left:16px; right:16px; bottom:14px; color:#fff; }
  .hero .info h1 { font-size:22px; font-weight:800; line-height:1.25; margin-top:6px;
    text-shadow:0 1px 8px rgba(0,0,0,.35); }

  /* 히어로 없는 매장 — 이름 블록 */
  .plainhead { padding:6px 2px 14px; }
  .plainhead h1 { font-size:22px; font-weight:800; color:var(--text); line-height:1.25; margin-top:8px; }

  /* 카테고리 칩 — 앱과 동일: 업종색 14% 배경 + 업종색 텍스트, 라운드 100 */
  .chip { display:inline-block; font-size:12px; font-weight:700;
          border-radius:100px; padding:4px 10px; margin-right:6px; }

  /* 정보/후기 카드 — surface, radius 16, 0.5px 보더 (앱 카드 문법) */
  .card { background:var(--surface); border-radius:16px; padding:16px;
          border:.5px solid var(--border); margin-bottom:10px; }
  .rating-row { display:flex; align-items:center; gap:6px; font-size:16px; font-weight:800; }
  .rating-row .star { color:var(--star); font-size:17px; }
  .rating-row small { font-weight:400; font-size:13px; color:var(--text2); }
  .meta { font-size:14px; color:var(--text2); line-height:1.8; margin-top:8px; }

  .section { font-size:13px; font-weight:700; color:var(--text2); margin:18px 2px 8px; }

  /* 후기 카드 */
  .review .stars { color:var(--star); font-size:13px; letter-spacing:1px; }
  .incent { font-size:11px; font-weight:600; color:var(--text2);
            border:1px solid var(--border); background:var(--surface-muted);
            border-radius:100px; padding:2px 8px; margin-left:8px; vertical-align:1px; }
  .review p { font-size:14px; line-height:1.6; margin-top:6px; color:var(--text);
              word-break:break-all; }
  .rphotos { display:flex; gap:6px; margin-top:10px; }
  .rphotos img { width:72px; height:72px; object-fit:cover; border-radius:10px; }

  /* 더 보기 줄 — 숨긴 콘텐츠가 있음을 정직하게 + 앱 전환 유인 */
  .more { display:block; text-align:center; font-size:13.5px; font-weight:700;
          color:var(--primary-dark); background:var(--surface-muted);
          border:.5px solid var(--border); border-radius:14px; padding:13px;
          text-decoration:none; margin-bottom:4px; }

  .cta { display:block; text-align:center; background:var(--primary-dark); color:var(--on-primary);
         text-decoration:none; font-size:15px; font-weight:800; border-radius:14px;
         padding:16px; margin-top:14px; }
  .cta.sub { background:transparent; color:var(--text3); font-weight:400; font-size:13px; padding:10px; }
  .notice { text-align:center; padding:56px 16px 32px; background:var(--surface);
            border-radius:16px; border:.5px solid var(--border); }
  .notice h1 { font-size:18px; font-weight:800; }
  .notice p { font-size:14px; color:var(--text2); margin-top:8px; line-height:1.6; }
</style></head>
<body><div class="wrap"><div class="brand">PawMate</div>${inner}</div></body></html>`;
}

function noticePage(title: string, msg: string, status: number): Response {
  return html(
    page(title, msg, `<div class="notice"><h1>${esc(title)}</h1><p>${esc(msg)}</p></div>`),
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
  const cat = CATEGORIES[String(fac.category)] ??
    { label: String(fac.category ?? ""), color: "#AD9466" };
  const rating = Number(fac.avg_rating ?? 0);
  const reviewCount = Number(fac.review_count ?? 0);
  const name = String(fac.name ?? "매장");
  const ogDesc = rating > 0
    ? `★${rating.toFixed(1)} · 후기 ${reviewCount}개 · ${cat.label}`
    : `우리 동네 ${cat.label} — PawMate 에서 확인하세요`;

  // 업종색 칩 — 앱(시설 상세)과 동일: 업종색 14% 배경(#hex24 알파) + 업종색 텍스트.
  // 사진(스크림) 위에서는 흰 반투명으로 가독 확보.
  const chip = (onPhoto: boolean) =>
    `<span class="chip" style="${
      onPhoto
        ? "background:rgba(255,255,255,.22);color:#fff"
        : `background:${cat.color}24;color:${cat.color}`
    }">${esc(cat.label)}</span>`;

  // 히어로 — 대표 사진이 있으면 앱 히어로 문법(사진 + 하단 점진 블러 + 스크림 위 정보).
  const photoUrl = fac.photo_url ? String(fac.photo_url) : null;
  const alignPct = Math.round(((Number(fac.photo_align_y ?? 0) + 1) / 2) * 100);
  const head = photoUrl
    ? `<div class="hero">
        <img class="photo" src="${esc(photoUrl)}" alt="" style="object-position:center ${alignPct}%">
        <div class="blurband"></div><div class="scrim"></div>
        <div class="info">${chip(true)}<h1>${esc(name)}</h1></div>
      </div>`
    : `<div class="plainhead">${chip(false)}<h1>${esc(name)}</h1></div>`;

  const hours = fac.business_hours ? String(fac.business_hours) : null;
  const infoCard = `
  <div class="card">
    ${
    rating > 0
      ? `<div class="rating-row"><span class="star">★</span>${rating.toFixed(1)}
         <small>후기 ${reviewCount}개</small></div>`
      : ""
  }
    <div class="meta" ${rating > 0 ? "" : 'style="margin-top:0"'}>
      ${fac.address ? `📍 ${esc(String(fac.address))}<br>` : ""}
      ${hours ? `🕐 ${esc(hours)}<br>` : ""}
      ${fac.phone ? `📞 ${esc(String(fac.phone))}` : ""}
    </div>
  </div>`;

  const reviews: Array<{
    rating: number;
    content: string | null;
    has_incentive?: boolean;
    photo_urls?: string[];
  }> = data.reviews ?? [];
  const reviewHtml = reviews.length === 0
    ? `<div class="card"><p style="font-size:14px;color:var(--text2)">아직 후기가 없어요. 첫 후기의 주인공이 되어 주세요!</p></div>`
    : reviews.map((r) => {
      // 후기 사진 썸네일(최대 2장, 서버에서 제한) — 사진 후기가 가장 설득력 있다.
      const photos = (r.photo_urls ?? [])
        .map((u) => `<img src="${esc(String(u))}" alt="" loading="lazy">`)
        .join("");
      return `
      <div class="card review">
        <span class="stars">${starBar(Number(r.rating))}</span>${
        r.has_incentive ? '<span class="incent">업체 혜택 받고 작성</span>' : ""
      }
        <p>${esc(String(r.content ?? "")).slice(0, 400)}</p>
        ${photos ? `<div class="rphotos">${photos}</div>` : ""}
      </div>`;
    }).join("");

  // 더 보기 — 숨긴 후기가 있음을 정직하게 알리고 앱 전환 유인으로 쓴다.
  const remaining = Math.max(0, reviewCount - reviews.length);
  const moreHtml = remaining > 0
    ? `<a class="more" href="?t=${token}&amp;go=store">후기 ${remaining}개 더 있어요 — 앱에서 모두 보기</a>`
    : "";

  const inner = `
  ${head}
  ${infoCard}
  <div class="section">방문 후기</div>
  ${reviewHtml}
  ${moreHtml}
  <a class="cta" href="?t=${token}&amp;go=store">PawMate 앱에서 동네 반려 소식 보기</a>
  <a class="cta sub" href="?t=${token}&amp;go=store">후기 작성도 앱에서 할 수 있어요</a>`;

  return html(page(name, ogDesc, inner));
});
