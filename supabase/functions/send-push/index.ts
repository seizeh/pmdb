// ============================================================================
// send-push — pending 알림을 FCM(HTTP v1)로 발송
//   POST { notification_id? }   header: x-push-secret == PUSH_TRIGGER_SECRET
//   호출: notifications 트리거(단건) + pg_cron 스윕(배치). service_role 로 RPC 사용.
//   env: PUSH_TRIGGER_SECRET(트리거/크론과 공유), FCM_SERVICE_ACCOUNT(Google 서비스계정 JSON).
//   흐름: push_dispatch_batch 로 클레임 → FCM v1 발송 → push_report 로 sent/failed + 죽은토큰 비활성.
//   notification 페이로드 포함 → 앱이 꺼져있어도 OS 가 표시(백그라운드/종료), data 로 탭 라우팅.
// ============================================================================
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": Deno.env.get("ALLOW_ORIGIN") ?? "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-push-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...corsHeaders, "Content-Type": "application/json" } });

function b64urlStr(s: string): string {
  return btoa(String.fromCharCode(...new TextEncoder().encode(s)))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function b64urlBytes(bytes: Uint8Array): string {
  let bin = ""; for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function pemToDer(pem: string): ArrayBuffer {
  const b64 = pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const bin = atob(b64); const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out.buffer;
}

// deno-lint-ignore no-explicit-any
let cachedToken: string | null = null, cachedExp = 0;
// deno-lint-ignore no-explicit-any
async function getAccessToken(sa: any): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedToken && cachedExp - 60 > now) return cachedToken;
  const header = b64urlStr(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claim = b64urlStr(JSON.stringify({
    iss: sa.client_email, scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token", iat: now, exp: now + 3600,
  }));
  const data = `${header}.${claim}`;
  const key = await crypto.subtle.importKey(
    "pkcs8", pemToDer(sa.private_key), { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(data)));
  const jwt = `${data}.${b64urlBytes(sig)}`;
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: `grant_type=${encodeURIComponent("urn:ietf:params:oauth:grant-type:jwt-bearer")}&assertion=${jwt}`,
  });
  const j = await res.json();
  if (!j.access_token) throw new Error("oauth_failed: " + JSON.stringify(j).slice(0, 200));
  cachedToken = j.access_token; cachedExp = now + (j.expires_in ?? 3600);
  return cachedToken!;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const triggerSecret = Deno.env.get("PUSH_TRIGGER_SECRET");
  if (!triggerSecret) return json({ error: "not_configured" }, 503);
  if (req.headers.get("x-push-secret") !== triggerSecret) return json({ error: "unauthorized" }, 401);

  const saRaw = Deno.env.get("FCM_SERVICE_ACCOUNT");
  if (!saRaw) return json({ ok: true, skipped: "fcm_not_configured" }); // pending 유지(설정 후 발송)
  // deno-lint-ignore no-explicit-any
  let sa: any;
  try { sa = JSON.parse(saRaw); } catch { return json({ error: "bad_service_account" }, 500); }

  let body: { notification_id?: string } = {};
  try { body = await req.json(); } catch { /* 배치(빈 바디) */ }
  const onlyId = body.notification_id ?? null;

  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data: items, error } = await supabase.rpc("push_dispatch_batch", { p_only_id: onlyId, p_limit: 100 });
  if (error) { console.error("dispatch failed", error); return json({ error: "dispatch_failed" }, 500); }
  const list = (items as Array<{ notification_id: string; ntype: string; title: string; body: string; resource_type: string; resource_id: string; tokens: Array<{ token: string; platform: string }> }>) ?? [];
  if (list.length === 0) return json({ ok: true, sent: 0 });

  let accessToken: string;
  try { accessToken = await getAccessToken(sa); }
  catch (e) {
    console.error("oauth", e);
    await supabase.rpc("push_report", { p_results: list.map((it) => ({ notification_id: it.notification_id, ok: false, error: "oauth_failed" })) });
    return json({ error: "oauth_failed" }, 502);
  }

  const url = `https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`;
  const results: Array<{ notification_id: string; ok: boolean; error: string | null; dead_tokens: string[] }> = [];
  for (const it of list) {
    let anyOk = false; let lastErr: string | null = null; const dead: string[] = [];
    for (const t of (it.tokens ?? [])) {
      const msg = {
        message: {
          token: t.token,
          notification: { title: it.title ?? "알림", body: it.body ?? "" },
          data: {
            type: String(it.ntype ?? ""), notification_id: String(it.notification_id),
            resource_type: String(it.resource_type ?? ""), resource_id: String(it.resource_id ?? ""),
          },
          android: { priority: "high" },
          apns: { headers: { "apns-priority": "10" }, payload: { aps: { sound: "default" } } },
        },
      };
      const r = await fetch(url, {
        method: "POST",
        headers: { "Authorization": `Bearer ${accessToken}`, "Content-Type": "application/json" },
        body: JSON.stringify(msg),
      });
      if (r.ok) { anyOk = true; }
      else {
        const err = await r.json().catch(() => ({}));
        const code = err?.error?.details?.[0]?.errorCode ?? err?.error?.status ?? String(r.status);
        lastErr = code;
        if (code === "UNREGISTERED" || code === "INVALID_ARGUMENT" || r.status === 404) dead.push(t.token);
      }
    }
    results.push({ notification_id: it.notification_id, ok: anyOk, error: anyOk ? null : lastErr, dead_tokens: dead });
  }
  await supabase.rpc("push_report", { p_results: results });
  return json({ ok: true, processed: list.length });
});
