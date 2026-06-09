-- 이벤트 발생 시 notifications 자동 생성.
-- SECURITY DEFINER 로 admin-only insert RLS 우회. 자기 자신 알림은 제외.
-- 알림 생성 실패가 본 작업(댓글/지원 등)을 막지 않도록 예외는 무시.

-- 1) 내 게시글에 새 댓글
create or replace function app.tg_notify_comment()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_owner uuid;
begin
  begin
    select user_id into v_owner from public.posts where id = new.post_id;
    if v_owner is not null and v_owner <> new.user_id then
      insert into public.notifications(user_id, actor_user_id, notification_type, title, resource_type, resource_id)
      values (v_owner, new.user_id, 'post_comment', '내 게시글에 새 댓글이 달렸어요', 'post', new.post_id);
    end if;
  exception when others then null;
  end;
  return new;
end; $$;

create trigger trg_notify_comment
  after insert on public.comments
  for each row execute function app.tg_notify_comment();

-- 2) 내 게시글에 지원
create or replace function app.tg_notify_application()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_owner uuid;
begin
  begin
    select user_id into v_owner from public.posts where id = new.post_id;
    if v_owner is not null and v_owner <> new.applicant_id then
      insert into public.notifications(user_id, actor_user_id, notification_type, title, resource_type, resource_id)
      values (v_owner, new.applicant_id, 'post_application', '내 게시글에 지원이 들어왔어요', 'post', new.post_id);
    end if;
  exception when others then null;
  end;
  return new;
end; $$;

create trigger trg_notify_application
  after insert on public.applications
  for each row execute function app.tg_notify_application();

-- 3) 지원 수락됨 → 지원자에게
create or replace function app.tg_notify_application_accepted()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  begin
    if new.status = 'accepted' and old.status is distinct from 'accepted' then
      insert into public.notifications(user_id, notification_type, title, resource_type, resource_id)
      values (new.applicant_id, 'application_accepted', '지원이 수락됐어요', 'post', new.post_id);
    end if;
  exception when others then null;
  end;
  return new;
end; $$;

create trigger trg_notify_application_accepted
  after update on public.applications
  for each row execute function app.tg_notify_application_accepted();

-- 4) 평가 받음 → 피평가자에게
create or replace function app.tg_notify_review()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  begin
    if new.reviewee_id <> new.reviewer_id then
      insert into public.notifications(user_id, actor_user_id, notification_type, title)
      values (new.reviewee_id, new.reviewer_id, 'review_received', '새 평가를 받았어요');
    end if;
  exception when others then null;
  end;
  return new;
end; $$;

create trigger trg_notify_review
  after insert on public.reviews
  for each row execute function app.tg_notify_review();
