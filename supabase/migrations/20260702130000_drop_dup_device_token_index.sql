-- device_tokens.token 에 unique 인덱스가 2개 존재(중복): 원래 UNIQUE 제약의
-- device_tokens_token_key + 푸시 마이그레이션이 잘못 추가한 device_tokens_token_uq.
-- 후자를 제거(전자가 남아 register_device_token 의 on conflict (token) 을 계속 지원).
drop index if exists public.device_tokens_token_uq;
