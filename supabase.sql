-- LearnDesk sync table. Run once in the Supabase SQL editor.
-- Every idea, journal entry, question and to-do is one row. Row-level security
-- means a signed-in user can only ever read or change their own rows.

create table public.items (
  id       uuid primary key,
  user_id  uuid not null default auth.uid() references auth.users (id) on delete cascade,
  kind     text not null,
  data     jsonb not null default '{}'::jsonb,
  modified bigint not null,
  deleted  boolean not null default false
);

alter table public.items enable row level security;

create policy "Own rows only" on public.items
  for all to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
