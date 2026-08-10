-- facilities.ext_id 를 LOCALDATA 관리번호로 정착 (되돌림용 컬럼 추가).
--
-- ── 왜 필요했나 ─────────────────────────────────────────────────────────
--
-- 초기 적재(2026-06-27)는 LOCALDATA 원본을 xlsx 로 변환해 넣었고, 그 과정에서
-- ext_id 에 **재현 불가능한 생성 해시**(예: 5568e1c5381a3dbd8e0b)가 들어갔다.
-- upsert 키가 (source, ext_id) 인데 그 값을 원본에서 다시 만들 수 없으니,
-- 다음 갱신본을 받아도 기존 행에 붙지 않고 통째로 새 행이 쌓이는 상태였다.
-- 폐업 반영(is_open=false)도 같은 이유로 불가능했다.
--
-- 그래서 CSV 원본(CP949, 관리번호가 텍스트로 온전)과 대조해 ext_id 를 관리번호로
-- 갈아끼웠다. 매칭 기준은 ①(category, 사업장명, 도로명주소) ②지번주소 폴백
-- ③깨진 문자 구간을 와일드카드로 둔 정규식(아래 참조) — 24,550건 전부 매칭,
-- 관리번호 중복 0건.
--
-- 같은 작업에서 xlsx 경유로 깨진 문자 17건도 원본 문자열로 교정했다
-- ('#NAME?' → '+더개꿀', '치�� 애견유치원' → '치즈 애견유치원' 등).
-- Excel 이 '+' 로 시작하는 상호를 수식으로 해석한 흔적이다.
-- 업주가 직접 고친 행(owner_updated_at)은 name 을 덮지 않았다.
--
-- ⚠️ 데이터 교체 자체는 외부 CSV 를 대조하는 1회성 작업이라 이 마이그레이션에
-- 담기지 않는다(운영에 직접 적용, 2026-08-10). 여기서는 되돌림용 컬럼만 만든다.
-- 되돌리려면: update public.facilities set ext_id = legacy_ext_id
--             where legacy_ext_id is not null;

alter table public.facilities add column if not exists legacy_ext_id varchar(64);

comment on column public.facilities.legacy_ext_id is
  '2026-08-10 ext_id 를 LOCALDATA 관리번호로 교체하기 전의 옛 생성 해시(되돌림용).';
