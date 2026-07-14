// 국세청 사업자등록 상태조회 (공공데이터포털 nts-businessman v1, 0025 §3.1).
// check-business-no(사전 확인)와 apply-business(제출 시 서버 재조회)가 공유.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

export type NtsStatus = {
  ok: boolean;                 // b_stt_cd === '01' (계속사업자)
  statusCode: string | null;   // '01' 계속 / '02' 휴업 / '03' 폐업 / null 미등록
  statusLabel: string | null;  // 계속사업자/휴업자/폐업자
  taxType: string | null;      // 과세유형 문구(미등록 안내 문구 포함)
};

/// 사업자등록번호 체크섬 (가중치 1,3,7,1,3,7,1,3,5 — 오타를 API 호출 전에 거른다)
export function isValidBizNo(no: string): boolean {
  if (!/^\d{10}$/.test(no)) return false;
  const w = [1, 3, 7, 1, 3, 7, 1, 3, 5];
  let sum = 0;
  for (let i = 0; i < 9; i++) sum += Number(no[i]) * w[i];
  sum += Math.floor((Number(no[8]) * 5) / 10);
  return (10 - (sum % 10)) % 10 === Number(no[9]);
}

/// 상태조회. 네트워크/응답 이상은 null (호출부가 nts_unavailable 처리).
export async function ntsStatus(bNo: string, serviceKey: string): Promise<NtsStatus | null> {
  try {
    const res = await fetch(
      "https://api.odcloud.kr/api/nts-businessman/v1/status?serviceKey=" +
        encodeURIComponent(serviceKey),
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ b_no: [bNo] }),
      },
    );
    if (!res.ok) return null;
    const body = await res.json();
    const d = Array.isArray(body?.data) ? body.data[0] : null;
    if (!d) return null;
    // 미등록 번호: b_stt/b_stt_cd 가 빈값, tax_type 에 안내 문구
    const code = (d.b_stt_cd ?? "").trim() || null;
    return {
      ok: code === "01",
      statusCode: code,
      statusLabel: (d.b_stt ?? "").trim() || null,
      taxType: (d.tax_type ?? "").trim() || null,
    };
  } catch {
    return null;
  }
}
