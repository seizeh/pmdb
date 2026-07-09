// ============================================================================
// passwords — argon2id 해싱/검증 (hash-wasm, WASM이라 콜드스타트 외 오버헤드 미미)
//   해싱은 항상 argon2id. 검증은 저장 해시 접두사로 분기:
//     $argon2…  → argon2id (신규)
//     $2…       → bcrypt   (레거시, pgcrypto crypt 산출물) — 로그인 성공 시
//                  update_password_hash 로 점진 재해싱한다(login 참조).
//   파라미터는 OWASP 권장 최소치(m=19MiB, t=2, p=1). 변경 시 기존 해시는 encoded
//   문자열에 파라미터가 들어있어 그대로 검증되고, 새 해시부터 새 파라미터가 적용된다.
// ============================================================================
import { argon2id, argon2Verify, bcryptVerify } from "npm:hash-wasm@4.12.0";

const ARGON2 = { parallelism: 1, iterations: 2, memorySize: 19456, hashLength: 32 } as const;

/** argon2id encoded 해시($argon2id$v=19$m=…) 생성. */
export async function hashPassword(password: string): Promise<string> {
  const salt = crypto.getRandomValues(new Uint8Array(16));
  return await argon2id({ password, salt, ...ARGON2, outputType: "encoded" });
}

/** 저장 해시 형식에 맞춰 검증. 알 수 없는 형식/파싱 실패는 false. */
export async function verifyPassword(password: string, hash: string): Promise<boolean> {
  try {
    if (hash.startsWith("$argon2")) return await argon2Verify({ password, hash });
    if (hash.startsWith("$2")) return await bcryptVerify({ password, hash });
    return false;
  } catch {
    return false;
  }
}

/** 레거시(bcrypt) 해시 여부 — 로그인 성공 시 재해싱 대상. */
export function isLegacyHash(hash: string): boolean {
  return hash.startsWith("$2");
}

// 존재하지 않는 계정에도 동일한 해싱 비용을 지불해 사용자명 열거(타이밍)를 막는다.
const DUMMY_SALT = new Uint8Array(16); // 고정 salt — 결과는 버림, 비용만 목적

/** 계정 미존재 시 호출 — argon2id 1회 비용만 소모하고 결과는 버린다. */
export async function dummyVerify(password: string): Promise<void> {
  try {
    await argon2id({ password, salt: DUMMY_SALT, ...ARGON2, outputType: "encoded" });
  } catch {
    // 시간 균등화 목적 — 결과/실패 무시
  }
}
