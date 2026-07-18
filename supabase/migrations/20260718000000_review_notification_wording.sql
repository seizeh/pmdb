-- 사용자 평가 → '후기' 용어 통일(앱 UI 변경과 동기화): 알림 문구 변경.
create or replace function app.tg_notify_review()
returns trigger language plpgsql security definer set search_path to ''
as $function$
begin
  begin
    if new.reviewee_id <> new.reviewer_id then
      insert into public.notifications(user_id, actor_user_id, notification_type, title)
      values (new.reviewee_id, new.reviewer_id, 'review_received', '새 후기를 받았어요');
    end if;
  exception when others then null;
  end;
  return new;
end; $function$;
