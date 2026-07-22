// ============================================================================
// share-view — 공유 링크 뷰어: 토큰 → 로그인 없이 HTML 서빙 (0028 §3)
//   GET ?t=<token>            → 열람 페이지(HTML) + funnel 'share_view' 기록
//   GET ?t=<token>&go=store   → funnel 'store_click' 기록 후 스토어로 302
//
//   설치 전 가치 먼저(0028 원칙 2): 매장 미리보기(facility_preview)를 설치·가입
//   없이 보여주고, 설치 유도 버튼만 둔다. 후기 강요·가입 강제 없음.
//   kind='care_report' 는 P1(미용 전후 사진)에서 열린다 — 지금은 안내만.
//
//   디자인 = 앱 업체 프로필(user_profile_screen 업체 얼굴) 미러:
//   애플뮤직 스타일 헤더 카드(사진 풀블리드 + 점진 블러 + 상호·통계 2칸) →
//   '업체 정보' 타이틀 바 + 인증 카드 → '방문 후기' + 2열 사진 타일 그리드
//   (사진 없는 후기는 블롭 배경 + 본문, '업체 혜택' 코너 배지).
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

// 카테고리 라벨 — 앱과 동일.
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
/// 색·수치는 앱(app_palette 라이트, user_profile_screen)과 동일.
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
         background:var(--surface); color:var(--text); }
  .wrap { max-width:480px; margin:0 auto; padding:12px 0 40px; }
  .pad { padding-left:20px; padding-right:20px; }

  /* ── 헤더 카드 — 앱 업체 프로필의 애플뮤직 스타일(360px, radius 24) ── */
  .header-card { position:relative; height:360px; border-radius:24px; overflow:hidden;
                 margin:0 20px 4px; background:linear-gradient(160deg, var(--primary), var(--primary-dark)); }
  .header-card > img.photo { position:absolute; inset:0; width:100%; height:100%; object-fit:cover; }
  .header-card .blurband { position:absolute; inset:0;
    backdrop-filter:blur(22px); -webkit-backdrop-filter:blur(22px);
    mask-image:linear-gradient(transparent 50%, black 88%);
    -webkit-mask-image:linear-gradient(transparent 50%, black 88%); }
  .header-card .scrim { position:absolute; left:0; right:0; bottom:0; height:150px;
    background:linear-gradient(transparent, rgba(0,0,0,.3)); }
  .header-card .info { position:absolute; left:16px; right:16px; bottom:12px;
    color:#fff; text-align:center; }
  .header-card .info .bizname { font-size:20px; font-weight:800;
    white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
  .header-card .info .metaline { font-size:12.5px; color:rgba(255,255,255,.85); margin-top:3px; }
  .header-card .nophoto-name { position:absolute; inset:0; display:flex;
    align-items:center; justify-content:center; color:#fff;
    font-size:26px; font-weight:800; padding:0 24px; text-align:center; }
  .stats { display:flex; margin-top:10px; }
  .stats .col { flex:1; }
  .stats .div { width:1px; background:rgba(255,255,255,.35); margin:4px 0; }
  .stats .v { font-size:16px; font-weight:800; }
  .stats .k { font-size:11px; color:rgba(255,255,255,.7); margin-top:2px; }
  .stats .empty { flex:1; font-size:13px; font-weight:600; color:rgba(255,255,255,.8); padding:6px 0; }

  /* ── 섹션 타이틀 바 — 앱 _titleBar: 18 w800 + 카운트 15 w700 tertiary ── */
  .titlebar { height:44px; display:flex; align-items:center; gap:6px; padding:0 20px; margin-top:16px; }
  .titlebar b { font-size:18px; font-weight:800; color:var(--text); }
  .titlebar span { font-size:15px; font-weight:700; color:var(--text3); }

  /* ── 업체 정보 카드 — 앱 _businessInfoContent ── */
  .info-card { margin:10px 20px 0; padding:16px; background:var(--surface);
               border:.5px solid var(--border); border-radius:16px; }
  .verified { font-size:12.5px; font-weight:700; color:var(--primary-dark); margin-bottom:10px; }
  .irow { display:flex; gap:10px; padding:6px 0; font-size:14px; line-height:1.4; color:var(--text); }
  .irow .ic { color:var(--text2); flex:none; width:18px; text-align:center; }

  /* ── 방문 후기 — 앱 ReviewCardGrid: 2열 정방형 타일, radius 14, 0.5px 보더 ── */
  .rgrid { display:grid; grid-template-columns:1fr 1fr; gap:8px; margin:10px 20px 0; }
  .rtile { position:relative; aspect-ratio:1/1; border-radius:14px; overflow:hidden;
           border:.5px solid var(--border); background:var(--surface); }
  .rtile > img { position:absolute; inset:0; width:100%; height:100%; object-fit:cover; }
  .rtile .tscrim { position:absolute; left:0; right:0; bottom:0; height:56px;
    background:linear-gradient(transparent, rgba(0,0,0,.4)); }
  /* 사진 없는 후기 — 앱 블롭 배경의 정적 재현(프라이머리 톤 원형 그라데이션) */
  .rtile.noimg { background:
    radial-gradient(circle at 22% 26%, rgba(173,148,102,.20) 0 34%, transparent 35%),
    radial-gradient(circle at 78% 68%, rgba(173,148,102,.14) 0 30%, transparent 31%),
    radial-gradient(circle at 55% 90%, rgba(173,148,102,.10) 0 24%, transparent 25%),
    var(--surface); }
  .rtile.noimg .content { position:absolute; inset:14px 14px 40px;
    display:flex; align-items:center; justify-content:center; text-align:center;
    font-size:14px; font-weight:600; line-height:1.5; color:var(--text);
    overflow:hidden; }
  .rtile .badges { position:absolute; top:8px; left:8px; right:8px;
    display:flex; flex-wrap:wrap; gap:4px; }
  .rtile .badge { font-size:10.5px; font-weight:700; border-radius:100px; padding:2px 7px; }
  .rtile.hasimg .badge { background:rgba(0,0,0,.4); color:#fff; }
  .rtile.noimg .badge { background:var(--surface-muted); color:var(--text2);
    border:.5px solid var(--border); }
  .rtile .rate { position:absolute; left:10px; bottom:8px; display:flex; align-items:center;
    gap:3px; font-size:13px; font-weight:700; }
  .rtile.hasimg .rate { color:#fff; }
  .rtile.noimg .rate { color:var(--text); }
  .rtile .rate .star { color:var(--star); font-size:15px; }
  /* 더 보기 타일 — 그리드 마지막 칸 */
  .rtile.more { display:flex; align-items:center; justify-content:center; text-align:center;
    background:var(--surface-muted); text-decoration:none;
    font-size:13.5px; font-weight:700; color:var(--primary-dark); padding:14px; line-height:1.5; }

  .cta { display:block; text-align:center; background:var(--primary-dark); color:var(--on-primary);
         text-decoration:none; font-size:15px; font-weight:800; border-radius:14px;
         padding:16px; margin:20px 20px 0; }
  .cta.sub { background:transparent; color:var(--text3); font-weight:400; font-size:13px;
             padding:10px; margin-top:2px; }
  .notice { text-align:center; padding:56px 16px 32px; margin:8px 20px;
            background:var(--surface-muted); border-radius:16px; border:.5px solid var(--border); }
  .notice h1 { font-size:18px; font-weight:800; }
  .notice p { font-size:14px; color:var(--text2); margin-top:8px; line-height:1.6; }
  .brand { font-size:14px; font-weight:800; color:var(--primary); letter-spacing:.5px;
           padding:0 20px; margin-bottom:10px; }
</style></head>
<body><div class="wrap"><div class="brand">PawMate</div>${inner}</div></body></html>`;
}

function noticePage(title: string, msg: string, status: number): Response {
  return html(
    page(title, msg, `<div class="notice"><h1>${esc(title)}</h1><p>${esc(msg)}</p></div>`),
    status,
  );
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

  // ── 헤더 카드 — 앱 _fullHeaderCard(업체 얼굴) 미러 ──
  // 메타라인: 업종 · 주소 동(마지막 토큰) — 앱과 같은 요약 문법.
  const addr = String(fac.address ?? "");
  const dong = addr.split(" ").filter(Boolean).pop() ?? "";
  const metaline = [catLabel, dong].filter(Boolean).join(" · ");
  const statsHtml = reviewCount > 0
    ? `<div class="stats">
        <div class="col"><div class="v">${reviewCount}</div><div class="k">후기</div></div>
        <div class="div"></div>
        <div class="col"><div class="v">${rating.toFixed(1)}</div><div class="k">평점</div></div>
      </div>`
    : `<div class="stats"><div class="empty">아직 후기가 없어요</div></div>`;
  const photoUrl = fac.photo_url ? String(fac.photo_url) : null;
  const alignPct = Math.round(((Number(fac.photo_align_y ?? 0) + 1) / 2) * 100);
  const headerCard = `
  <div class="header-card">
    ${
    photoUrl
      ? `<img class="photo" src="${esc(photoUrl)}" alt="" style="object-position:center ${alignPct}%">
       <div class="blurband"></div><div class="scrim"></div>`
      : `<div class="nophoto-name">${esc(name)}</div>`
  }
    <div class="info">
      ${photoUrl ? `<div class="bizname">${esc(name)}</div>` : ""}
      <div class="metaline">${esc(metaline)}</div>
      ${statsHtml}
    </div>
  </div>`;

  // ── 업체 정보 — 앱 _businessInfoContent 미러 ──
  const hours = fac.business_hours ? String(fac.business_hours) : null;
  const infoRows = [
    `<div class="irow"><span class="ic">🏷</span><span>${esc(catLabel)}</span></div>`,
    addr ? `<div class="irow"><span class="ic">📍</span><span>${esc(addr)}</span></div>` : "",
    hours ? `<div class="irow"><span class="ic">🕐</span><span>${esc(hours)}</span></div>` : "",
    fac.phone
      ? `<div class="irow"><span class="ic">📞</span><span>${esc(String(fac.phone))}</span></div>`
      : "",
  ].join("");
  const infoCard = `
  <div class="titlebar"><b>업체 정보</b></div>
  <div class="info-card">
    ${fac.owner_verified ? `<div class="verified">✓ 사업자 인증을 완료한 업체예요</div>` : ""}
    ${infoRows}
  </div>`;

  // ── 방문 후기 — 앱 ReviewCardGrid 미러: 2열 정방형 타일 ──
  const reviews: Array<{
    rating: number;
    content: string | null;
    has_incentive?: boolean;
    photo_urls?: string[];
  }> = data.reviews ?? [];
  const starBar = (n: number) =>
    `<span class="star">★</span>${Math.max(0, Math.min(5, Math.round(n)))}`;
  const tiles = reviews.map((r) => {
    const photo = (r.photo_urls ?? [])[0];
    const badge = r.has_incentive ? `<div class="badges"><span class="badge">업체 혜택</span></div>` : "";
    if (photo) {
      return `<div class="rtile hasimg">
        <img src="${esc(String(photo))}" alt="" loading="lazy"><div class="tscrim"></div>
        ${badge}<div class="rate">${starBar(Number(r.rating))}</div>
      </div>`;
    }
    return `<div class="rtile noimg">
      ${badge}
      <div class="content">${esc(String(r.content ?? "내용 없는 후기")).slice(0, 120)}</div>
      <div class="rate">${starBar(Number(r.rating))}</div>
    </div>`;
  });
  // 더 보기 타일 — 숨긴 후기가 있음을 정직하게 알리고 앱 전환 유인으로(그리드 마지막 칸).
  const remaining = Math.max(0, reviewCount - reviews.length);
  if (remaining > 0) {
    tiles.push(
      `<a class="rtile more" href="?t=${token}&amp;go=store">후기 ${remaining}개<br>더 보기</a>`,
    );
  }
  const reviewSection = `
  <div class="titlebar"><b>방문 후기</b>${reviewCount > 0 ? `<span>${reviewCount}</span>` : ""}</div>
  ${
    reviews.length === 0
      ? `<div class="info-card" style="color:var(--text2);font-size:14px">아직 후기가 없어요. 첫 후기의 주인공이 되어 주세요!</div>`
      : `<div class="rgrid">${tiles.join("")}</div>`
  }`;

  const inner = `
  ${headerCard}
  ${infoCard}
  ${reviewSection}
  <a class="cta" href="?t=${token}&amp;go=store">PawMate 앱에서 동네 반려 소식 보기</a>
  <a class="cta sub" href="?t=${token}&amp;go=store">후기 작성도 앱에서 할 수 있어요</a>`;

  return html(page(name, ogDesc, inner));
});
