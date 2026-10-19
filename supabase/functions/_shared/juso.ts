// ============================================================================
// juso — 행안부 도로명주소(juso.go.kr) 검색 (0025 §4.2)
//
// 업체 등록의 사업장 주소 검색. 종전에는 앱이 승인키를 들고 직접 불렀는데, 키가
// 클라이언트 번들에 실리면 공개 저장소·웹 JS 에서 누구나 꺼내 쿼터를 쓴다. 그래서
// 7/21 에 소스 기본값을 지웠고(pmdart cafec4a), 그 뒤로는 빌드에 키를 넣지 않으면
// 검색이 조용히 수동 입력으로 바뀌었다 — 키가 빠진 빌드가 실제로 배포됐다.
// 키를 서버(함수 시크릿)에만 두고 juso-search 함수가 대신 부른다.
//
// 응답 분류는 여기 한 곳에서 한다(함수는 HTTP 로 옮기기만 한다):
//   ok          정상(결과가 비어도 정상)
//   input       검색어 문제 — juso 의 errorMessage 가 이미 사용자용 문구다
//   config      키·시스템 문제(승인되지 않은 키, 개발키 만료, -999) — 운영자가 고칠 일
//   unavailable HTTP 오류·시간 초과·응답 형식 이상
// ============================================================================

export interface JusoAddress {
  road_addr: string; // 도로명 전체 주소
  jibun_addr: string; // 지번 전체 주소 (facilities.address 대조용)
  adm_cd: string; // 행정구역코드 10자리 (앞 5자리 = 시군구)
  zip_no: string;
}

export type JusoOutcome =
  | { kind: "ok"; results: JusoAddress[]; total: number }
  | { kind: "input"; code: string; message: string }
  | { kind: "config"; code: string; message: string }
  | { kind: "unavailable"; detail: string };

/// 검색어 자체의 문제를 뜻하는 juso 오류 코드. 그 밖의 코드(E0001 승인되지 않은
/// 키, E0014 개발키 만료, -999 시스템 오류 등)는 설정·서버 문제로 본다.
export const INPUT_ERROR_CODES: ReadonlySet<string> = new Set([
  "E0005", // 검색어 미입력
  "E0006", // 주소를 상세히 입력
  "E0008", // 두 글자 이상
  "E0009", // 문자와 숫자를 같이
  "E0010", // 검색어가 너무 길다
  "E0011", // 너무 긴 숫자
  "E0012", // 특수문자+숫자만
  "E0013", // SQL 예약어·특수문자
  "E0015", // 검색 범위 초과
]);

/// 페이지당 건수 — 앱이 한 번에 보여 주는 만큼(종전 클라이언트와 같다).
export const COUNT_PER_PAGE = 20;

/// 검색어 검증. 앞뒤 공백을 걷고 2~80자만 받는다(juso 상한: 한글 40자·영문 80자 —
/// 그 사이의 세부 판정은 juso 가 E0010 으로 돌려준다). 아니면 null.
export function validKeyword(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const q = raw.trim();
  if (q.length < 2 || q.length > 80) return null;
  return q;
}

/// 페이지 번호 — 1~50 정수만(그 밖은 1).
export function validPage(raw: unknown): number {
  const n = typeof raw === "number" ? raw : Number(raw);
  return Number.isInteger(n) && n >= 1 && n <= 50 ? n : 1;
}

/// juso 응답(HTTP 상태 + 본문)을 분류한다. 순수 함수 — 테스트는 이것만 본다.
export function parseJuso(status: number, bodyText: string): JusoOutcome {
  if (status !== 200) return { kind: "unavailable", detail: `HTTP ${status}` };
  // deno-lint-ignore no-explicit-any
  let body: any;
  try {
    body = JSON.parse(bodyText);
  } catch {
    return { kind: "unavailable", detail: "JSON 이 아닌 응답" };
  }
  const common = body?.results?.common;
  const code = typeof common?.errorCode === "string" ? common.errorCode : null;
  if (code === null) return { kind: "unavailable", detail: "results.common.errorCode 없음" };
  const message = typeof common?.errorMessage === "string" ? common.errorMessage.trim() : "";
  if (code !== "0") {
    if (INPUT_ERROR_CODES.has(code) && message) return { kind: "input", code, message };
    return { kind: "config", code, message };
  }
  const list: unknown[] = Array.isArray(body?.results?.juso) ? body.results.juso : [];
  const results: JusoAddress[] = [];
  for (const j of list) {
    // deno-lint-ignore no-explicit-any
    const r = j as any;
    const road = typeof r?.roadAddr === "string" ? r.roadAddr : "";
    if (!road) continue;
    results.push({
      road_addr: road,
      jibun_addr: typeof r?.jibunAddr === "string" ? r.jibunAddr : "",
      adm_cd: typeof r?.admCd === "string" ? r.admCd : "",
      zip_no: typeof r?.zipNo === "string" ? r.zipNo : "",
    });
  }
  const total = Number(common?.totalCount);
  return { kind: "ok", results, total: Number.isFinite(total) ? total : results.length };
}

/// juso 를 부른다. 시간 초과 8초(종전 클라이언트와 같다). 네트워크 오류도 분류해 돌려준다.
export async function jusoSearch(
  keyword: string,
  page: number,
  key: string,
  fetchImpl: typeof fetch = fetch,
): Promise<JusoOutcome> {
  const url = new URL("https://business.juso.go.kr/addrlink/addrLinkApi.do");
  url.search = new URLSearchParams({
    confmKey: key,
    currentPage: String(page),
    countPerPage: String(COUNT_PER_PAGE),
    keyword,
    resultType: "json",
  }).toString();
  try {
    const res = await fetchImpl(url, { signal: AbortSignal.timeout(8000) });
    return parseJuso(res.status, await res.text());
  } catch (e) {
    // 키가 URL 에 실리므로 오류 문구에 URL 을 그대로 남기지 않는다.
    const name = e instanceof Error ? e.name : "Error";
    return { kind: "unavailable", detail: `요청 실패(${name})` };
  }
}
