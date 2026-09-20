// 공용 CORS — 허용 목록 에코 방식 (2026-09-21, 종전 정적 `*` 에서 전환)
//
// ALLOW_ORIGIN: 콤마 구분 오리진 목록(예: "https://app.pawmate.kr").
//   · 요청 Origin 이 목록에 있으면 그 값을 에코하고 `Vary: Origin` 을 단다.
//   · 목록 밖이면 ACAO 를 아예 싣지 않는다 — 브라우저가 응답을 읽지 못하고,
//     preflight 대상 요청(JSON POST)은 본요청 자체가 나가지 않는다.
//   · 미설정이면 종전과 같은 `*` — 테스트 서버 호환. 운영에는 값이 설정돼 있다.
//
// 왜: 이 시스템에서 CORS 는 인증 방어가 아니라(Bearer 헤더 + 무쿠키) **레이트리밋
// 보조선**이다 — `*` 는 임의 사이트가 방문자 브라우저로 무인증 엔드포인트를 두드려
// IP 버킷을 방문자 IP 로 분산시키는 것을 허용한다. 또한 향후 쿠키(credentials)
// 전환 시 브라우저가 `*` 를 거부하므로 에코 방식이 선행 조건이다.
//
// enforceOrigin: CORS 는 preflight 없는 simple request(text/plain POST)의 **발사**
// 자체는 못 막는다(응답만 가린다) — req.json() 은 content-type 을 보지 않고 파싱
// 하므로 서버는 처리해 버린다. 비용·크리덴셜 엔드포인트(전화 OTP·가입·로그인 계열)는
// 이 옵션으로 서버측에서 Origin 을 검사해 그 구멍까지 닫는다. Origin 헤더가 없는
// 요청(네이티브 앱·pg_net 크론·curl)은 통과 — 브라우저에서 온 것만 판정한다.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const ALLOWED = (Deno.env.get("ALLOW_ORIGIN") ?? "")
  .split(",")
  .map((s) => s.trim())
  .filter(Boolean);

const BASE_HEADERS = {
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-client-refresh",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function corsFor(req: Request): Record<string, string> {
  if (ALLOWED.length === 0) {
    return { ...BASE_HEADERS, "Access-Control-Allow-Origin": "*" };
  }
  const origin = req.headers.get("origin");
  if (origin && ALLOWED.includes(origin)) {
    return { ...BASE_HEADERS, "Access-Control-Allow-Origin": origin, "Vary": "Origin" };
  }
  return { ...BASE_HEADERS }; // 허용 외/무 Origin: ACAO 없음
}

/// JSON 응답 — CORS 헤더는 withCors 래퍼가 응답에 일괄 주입하므로 여기 없다.
/// (종전에는 여기서 corsHeaders 를 섞었다 — 래퍼 미적용 함수가 생기면 CORS 가
/// 조용히 빠지는 부분 적용이 되므로, 주입 지점을 래퍼 하나로 모았다.)
export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

/// Deno.serve 핸들러 래퍼 — OPTIONS 응답 + 모든 응답에 CORS 헤더 주입.
/// enforceOrigin: 허용 목록이 설정돼 있고 요청에 Origin 이 있는데 목록 밖이면 403.
export function withCors(
  handler: (req: Request) => Promise<Response> | Response,
  opts?: { enforceOrigin?: boolean },
): (req: Request) => Promise<Response> {
  return async (req: Request): Promise<Response> => {
    const cors = corsFor(req);
    if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
    if (opts?.enforceOrigin && ALLOWED.length > 0) {
      const origin = req.headers.get("origin");
      if (origin && !ALLOWED.includes(origin)) {
        return new Response(JSON.stringify({ error: "origin_not_allowed" }), {
          status: 403,
          headers: { ...cors, "Content-Type": "application/json" },
        });
      }
    }
    const res = await handler(req);
    const headers = new Headers(res.headers);
    for (const [k, v] of Object.entries(cors)) headers.set(k, v);
    return new Response(res.body, { status: res.status, headers });
  };
}
