// 공용 CORS 헤더 (앱/브라우저에서 직접 호출).
// 운영 시 ALLOW_ORIGIN 환경변수로 특정 오리진만 허용하도록 좁힐 수 있다.
export const corsHeaders = {
  "Access-Control-Allow-Origin": Deno.env.get("ALLOW_ORIGIN") ?? "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
