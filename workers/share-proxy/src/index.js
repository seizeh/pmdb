// ============================================================================
// pawmate-share-proxy — 공유 뷰어 도메인 프록시 (0028 §3)
//
// 배경: Supabase 게이트웨이는 *.supabase.co 공유 도메인에서 HTML 서빙을
// 차단한다(피싱 방지 — text/html 을 text/plain 으로 교체 + CSP sandbox).
// 이 Worker 가 자체 도메인(go.pawmate.kr)에서 share-view Edge Function 을
// 프록시하며 Content-Type 을 복원한다. QR·공유 링크에는 자체 도메인만
// 인쇄되므로 뒷단(Supabase)은 언제든 교체 가능하다.
//
// 라우트 (wrangler.toml custom_domain):
//   go.pawmate.kr/s?t=<token>[&go=store]  → share-view 프록시(HTML 복원)
//   pawmate.kr, www.pawmate.kr            → 임시 랜딩(출시 전 안내)
// ============================================================================

const UPSTREAM =
  "https://vyatppuxmpulqtxevfpk.supabase.co/functions/v1/share-view";

export default {
  async fetch(req) {
    const url = new URL(req.url);

    // ── go.pawmate.kr/s — 공유 뷰어 프록시 ──
    if (url.hostname.startsWith("go.") && url.pathname === "/s") {
      const up = new URL(UPSTREAM);
      for (const k of ["t", "go"]) {
        const v = url.searchParams.get(k);
        if (v) up.searchParams.set(k, v);
      }
      const res = await fetch(up, {
        // UA 는 스토어 분기(go=store)에 필요. 그 외 헤더는 전달하지 않는다.
        headers: { "user-agent": req.headers.get("user-agent") ?? "" },
        redirect: "manual", // 스토어 302 는 브라우저가 직접 따라가게 통과
      });
      if (res.status >= 300 && res.status < 400) {
        return new Response(null, {
          status: res.status,
          headers: { location: res.headers.get("location") ?? "/" },
        });
      }
      const headers = new Headers(res.headers);
      // 게이트웨이가 강제한 text/plain·sandbox 를 걷어내고 HTML 로 복원.
      headers.set("content-type", "text/html; charset=utf-8");
      headers.delete("content-security-policy");
      headers.delete("x-content-type-options");
      return new Response(res.body, { status: res.status, headers });
    }

    // ── 루트/기타 — 출시 전 임시 랜딩 (스토어 오픈 후 리다이렉트로 교체) ──
    return new Response(LANDING, {
      status: url.pathname === "/" ? 200 : 404,
      headers: { "content-type": "text/html; charset=utf-8" },
    });
  },
};

const LANDING = `<!doctype html>
<html lang="ko"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>PawMate — 우리 동네 반려 생활</title>
<style>
  * { margin:0; padding:0; box-sizing:border-box; }
  body { font-family:-apple-system,BlinkMacSystemFont,"Apple SD Gothic Neo","Malgun Gothic",sans-serif;
         background:#F5EFE3; color:#5A4E3A; display:flex; min-height:100vh;
         align-items:center; justify-content:center; text-align:center; padding:24px; }
  .brand { font-size:15px; font-weight:800; color:#AD9466; letter-spacing:.5px; }
  h1 { font-size:24px; font-weight:800; margin:14px 0 10px; }
  p { font-size:14px; line-height:1.7; color:#8C8273; }
</style></head>
<body><div>
  <div class="brand">PawMate</div>
  <h1>우리 동네 반려 생활, 포메이트</h1>
  <p>지금 출시를 준비하고 있어요.<br>곧 스토어에서 만나요!</p>
</div></body></html>`;
