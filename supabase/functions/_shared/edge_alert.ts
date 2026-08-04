// ============================================================================
// edge_alert — 엣지 함수 실패를 관리자에게 인앱+푸시로 알림 (pmdart#157 베타 관측성)
//
// 기존 파이프라인 재사용: notifications INSERT → trg_notifications_push(pg_net)
// → send-push → FCM. notification_type 은 기존 'system_notice'(앱 표기 '공지')를
// 재사용한다 — 새 타입은 CHECK 제약·클라 매핑 동시 수정이 필요해 실수 여지가
// 크다(새 타입 추가 시 CHECK 미수정이면 트리거가 조용히 삼킨 전례).
//
// 같은 key 는 30분 1회로 스로틀(rate_limit_hit RPC 재사용) — Gemini 장애 등
// 폭주가 알림 폭주로 번지지 않게. 알림 실패가 본 흐름을 깨면 안 되므로
// 절대 throw 하지 않는다(전부 console.error 후 무시).
// ============================================================================
const ALERT_WINDOW_SECONDS = 1800; // 같은 key 30분 1회

// `ReturnType<typeof createClient>` 이었는데, 타입 인자를 안 준 createClient 의
// 스키마 제네릭이 never 로 굳어 **rpc/from 호출이 전부 타입 오류**가 났다(3건).
// 호출부마다 캐스팅을 뿌리는 대신 _shared/auth.ts 의 rateLimited·activeUid 와
// 같은 방식으로 맞춘다 — 이 저장소는 생성 타입을 쓰지 않으므로 여기서 얻을
// 타입 안전성이 애초에 없었다.
// deno-lint-ignore no-explicit-any
export async function alertAdmins(
  admin: any,
  key: string,
  title: string,
  body: string,
): Promise<void> {
  try {
    const { data: limited, error: rlErr } = await admin.rpc("rate_limit_hit", {
      p_key: `edgealert:${key}`,
      p_max: 1,
      p_window_seconds: ALERT_WINDOW_SECONDS,
    });
    if (rlErr) {
      console.error("edge_alert rate_limit failed", rlErr); // fail-open — 알림은 보낸다
    } else if (limited === true) {
      return; // 30분 내 같은 key 이미 발송됨
    }

    const { data: admins, error: selErr } = await admin
      .from("users")
      .select("id")
      .eq("user_type", "admin")
      .eq("status", "active");
    if (selErr) {
      console.error("edge_alert admin select failed", selErr);
      return;
    }
    if (!admins?.length) return;

    const rows = admins.map((a: { id: string }) => ({
      user_id: a.id,
      notification_type: "system_notice",
      is_system: true,
      priority: "high",
      notification_group_key: `edge_alert:${key}`,
      title,
      body,
    }));
    const { error: insErr } = await admin.from("notifications").insert(rows);
    if (insErr) console.error("edge_alert insert failed", insErr);
  } catch (e) {
    console.error("edge_alert failed", e);
  }
}
