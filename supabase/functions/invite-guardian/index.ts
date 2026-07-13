// ============================================================================
// invite-guardian — 공동보호자 초대 (가입자: 인앱 알림 / 미가입 번호: 초대 SMS)
//   POST { petId: string, phone: string }   Authorization: Bearer <access JWT>
//
//   흐름: JWT 수동 검증 → 호출자 active + 펫 owner 확인 → 자기 초대 차단 →
//         pet_guardian_invites INSERT (BEFORE 트리거가 가입자면 invitee 연결,
//         AFTER 트리거가 인앱 알림) → 미가입 번호면 rate limit 후 Solapi 로
//         초대 안내 SMS 발송. 미가입자가 나중에 가입하면 tg_users_after_insert
//         가 대기 초대를 연결하고 알림을 만든다.
//
//   남용 방지: 초대자당 하루 10건, 동일 번호로는 하루 1건만 SMS.
//   verify_jwt=false 배포(수동 검증).
// ============================================================================
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders, json } from "../_shared/cors.ts";
import { bearer, rateLimited, verifyAccess } from "../_shared/auth.ts";
import { loadSolapiConfig, normalizePhone, sendSms } from "../_shared/solapi.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const SMS_PER_INVITER_PER_DAY = 10;
const SMS_PER_PHONE_PER_DAY = 1;

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const secret = Deno.env.get("JWT_SECRET");
  if (!secret) return json({ error: "server_misconfigured" }, 500);
  const token = bearer(req);
  const claims = token ? await verifyAccess(token, secret) : null;
  const uid = typeof claims?.sub === "string" ? claims.sub : null;
  if (!uid) return json({ error: "unauthorized" }, 401);

  let p: { petId?: string; phone?: string };
  try {
    p = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }
  const petId = typeof p.petId === "string" ? p.petId : "";
  const phone = normalizePhone(p.phone ?? "");
  if (!petId) return json({ error: "missing_pet" }, 400);
  if (!/^01\d{8,9}$/.test(phone)) return json({ error: "invalid_phone" }, 400);

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE);

  // 0) 호출자 상태(active) + 펫 owner 확인 — service_role 경유라 직접 검증한다.
  const { data: me } = await admin
    .from("users")
    .select("id, nickname, phone, status")
    .eq("id", uid)
    .maybeSingle();
  if (!me || me.status !== "active") return json({ error: "unauthorized" }, 401);
  const { data: role } = await admin
    .from("pet_guardians")
    .select("role")
    .eq("pet_id", petId)
    .eq("user_id", uid)
    .maybeSingle();
  if (role?.role !== "owner") return json({ error: "forbidden" }, 403);
  if (me.phone === phone) return json({ error: "self_invite" }, 400);

  // 1) 대상 가입 여부 (SMS 필요 여부 판단).
  const { data: target } = await admin
    .from("users")
    .select("id")
    .eq("phone", phone)
    .limit(1)
    .maybeSingle();

  // 2) 초대 INSERT — 가입자면 트리거가 invitee 연결 + 인앱 알림까지 처리.
  const { error: insErr } = await admin.from("pet_guardian_invites").insert({
    pet_id: petId,
    kind: "invite",
    inviter_id: uid,
    invitee_phone: phone,
  });
  if (insErr) {
    if (insErr.code === "23505") return json({ error: "already_invited" }, 409);
    console.error("invite insert failed", insErr);
    return json({ error: "internal_error" }, 500);
  }

  if (target) return json({ ok: true, registered: true });

  // 3) 미가입 번호 — rate limit 통과 시 초대 안내 SMS.
  const limited =
    (await rateLimited(admin, `ginv:u:${uid}`, SMS_PER_INVITER_PER_DAY, 86400)) ||
    (await rateLimited(admin, `ginv:p:${phone}`, SMS_PER_PHONE_PER_DAY, 86400));
  if (limited) {
    // 초대 자체는 저장됨 — 가입하면 연결된다. SMS 만 생략.
    return json({ ok: true, registered: false, sms: "rate_limited" });
  }
  try {
    const cfg = loadSolapiConfig();
    const { data: pet } = await admin
      .from("pets")
      .select("name")
      .eq("id", petId)
      .maybeSingle();
    const text =
      `[PawMate] ${me.nickname ?? ""}님이 반려동물 '${pet?.name ?? ""}'의 ` +
      `공동보호자로 초대했어요. PawMate 앱에서 이 번호로 가입하면 초대를 확인할 수 있어요.`;
    const res = await sendSms(cfg, phone, text);
    if (!res.ok) console.error("invite sms failed", res.status, res.body);
    return json({ ok: true, registered: false, sms: res.ok ? "sent" : "failed" });
  } catch (e) {
    console.error("invite sms error", e);
    return json({ ok: true, registered: false, sms: "failed" });
  }
});
