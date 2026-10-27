// ============================================================================
// edge_alert — 엣지 함수 실패를 관리자에게 알림 (pmdart#157 베타 관측성)
//
// 2026-09-21 원장 통합: 종전에는 스로틀(rate_limit_hit 30분 1회)과 notifications
// insert 를 여기서 직접 했고, ops_alarms 원장에는 **발송 시에도 남지 않았다** —
// DB 경로(app.ops_alarm_fire)와 이중 구현이었고, 2026-08-08 의 스로틀 판정 반전
// 사고(각 창의 첫 알림 삼킴 + 2회째부터 무제한)가 정확히 이 별도 구현에서 났다.
//
// 이제 public.edge_alert_fire(service_role 전용 definer 래퍼) 한 줄로 위임한다 —
// 쿨다운(30분)·관리자 알림(priority high·그룹키)·억제 기록(fire_count /
// last_seen_at) 전부 원장이 담당하고, 엣지발 알람도 'edge:<key>' 로 이력이 남는다.
// 억제도 발생이다 — 관측 손실이 되지 않게 원장에 횟수·시각이 쌓인다.
//
// 알림 실패가 본 흐름을 깨면 안 되므로 절대 throw 하지 않는다.
// ============================================================================

// deno-lint-ignore no-explicit-any
export async function alertAdmins(
  admin: any,
  key: string,
  title: string,
  body: string,
): Promise<void> {
  try {
    const { error } = await admin.rpc("edge_alert_fire", {
      p_key: key,
      p_title: title,
      p_body: body,
    });
    if (error) console.error("edge_alert fire failed", error);
  } catch (e) {
    console.error("edge_alert failed", e);
  }
}
