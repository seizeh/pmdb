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
//   남용 방지: **모든 초대 시도**가 초대자당 하루 20건(가입 여부와 무관) + SMS 는
//   초대자당 하루 10건·동일 번호 하루 1건. 직접 INSERT 는 20260804180000 이 회수했다.
//   verify_jwt=false 배포(수동 검증).
// ============================================================================
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders, json } from "../_shared/cors.ts";
import { bearer, rateLimited, verifyAccess } from "../_shared/auth.ts";
import { loadSolapiConfig, normalizePhone, sendSms } from "../_shared/solapi.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// 가입 여부와 **무관하게** 모든 초대 시도에 걸리는 상한. 이게 없으면 가입자 번호를
// 넣었을 때 아무 비용 없이 즉시 응답이 와서, 회원 여부를 무제한으로 캐낼 수 있다
// (미가입 경로에만 리밋이 있었다). 공동보호자를 하루 20명 넘게 초대할 일은 없다.
const INVITES_PER_INVITER_PER_DAY = 20;
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

  // 1) **분기 전에** 시도 자체를 센다. 가입자/미가입자 어느 쪽으로 갈리든 예산을
  //    쓰게 해야 열거가 묶인다. 형식 오류·권한 오류는 여기 오기 전에 걸러지므로
  //    정상 사용자가 오타 때문에 예산을 잃지는 않는다.
  if (await rateLimited(admin, `ginv:any:${uid}`, INVITES_PER_INVITER_PER_DAY, 86400)) {
    return json({ error: "rate_limited" }, 429);
  }

  // 2) 대상 가입 여부 (SMS 필요 여부 판단 — 응답에는 싣지 않는다).
  const { data: target } = await admin
    .from("users")
    .select("id")
    .eq("phone", phone)
    .limit(1)
    .maybeSingle();

  // 3) 초대 INSERT — 가입자면 트리거가 invitee 연결 + 인앱 알림까지 처리.
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

  // 응답은 **가입 여부와 무관하게 동일하다.** 예전에는 registered:true|false 를 그대로
  // 돌려줘서, 번호만 바꿔 부르면 회원 명부를 훑을 수 있었다. 초대자에게 필요한 정보는
  // "초대됐다" 뿐이고, 상대가 가입 전이면 문자로 안내가 간다는 사실은 문구로 덮인다.
  if (target) return json({ ok: true });

  // 4) 미가입 번호 — SMS 상한을 따로 본다(문자 비용·스팸 방지는 열거와 별개 문제).
  const limited =
    (await rateLimited(admin, `ginv:u:${uid}`, SMS_PER_INVITER_PER_DAY, 86400)) ||
    (await rateLimited(admin, `ginv:p:${phone}`, SMS_PER_PHONE_PER_DAY, 86400));
  if (limited) {
    // 초대 자체는 저장됨 — 가입하면 연결된다. SMS 만 생략.
    return json({ ok: true });
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
    return json({ ok: true });
  } catch (e) {
    console.error("invite sms error", e);
    return json({ ok: true });
  }
});
