-- ═══════════════════════════════════════════════════════════
-- LIFE GTM — database schema, security rules, and functions
-- Paste this entire file into: Supabase → SQL Editor → Run
-- Safe to re-run (idempotent-ish: drops functions it owns).
-- ═══════════════════════════════════════════════════════════

-- ── PROFILES: public-safe fields only (what friends can see) ──
create table if not exists public.profiles (
  id          uuid primary key references auth.users on delete cascade,
  handle      text unique not null check (handle ~ '^[a-z0-9_]{3,20}$'),
  display_name text not null check (char_length(display_name) between 1 and 40),
  friend_code text unique not null check (friend_code ~ '^GTM-[A-Z2-9]{4}$'),
  level       int  not null default 1  check (level between 1 and 999),
  xp          int  not null default 0  check (xp >= 0),
  pts         int  not null default 0  check (pts >= 0),
  week_xp     int  not null default 0  check (week_xp between 0 and 200),
  chain       int  not null default 0  check (chain >= 0),
  season_week int  not null default 1,
  updated_at  timestamptz not null default now(),
  created_at  timestamptz not null default now()
);

-- ── SAVES: private full game state (owner only, never public) ──
create table if not exists public.saves (
  id         uuid primary key references auth.users on delete cascade,
  onboarding jsonb,
  roadmap    jsonb,
  state      jsonb,
  updated_at timestamptz not null default now()
);

-- ── FOLLOWS: who you follow (one-way, Strava-style) ──
create table if not exists public.follows (
  follower  uuid not null references auth.users on delete cascade,
  followee  uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (follower, followee),
  check (follower <> followee)
);

-- ── GIFTS: XP-point gifts between players (insert ONLY via function) ──
create table if not exists public.gifts (
  id         bigint generated always as identity primary key,
  from_id    uuid not null references public.profiles(id) on delete cascade,
  to_id      uuid not null references public.profiles(id) on delete cascade,
  amount     int  not null check (amount between 1 and 50),
  message    text check (char_length(message) <= 140),
  created_at timestamptz not null default now()
);
create index if not exists gifts_to_idx   on public.gifts (to_id, created_at desc);
create index if not exists gifts_from_idx on public.gifts (from_id, created_at desc);

-- ═══════════════ ROW LEVEL SECURITY ═══════════════
alter table public.profiles enable row level security;
alter table public.saves    enable row level security;
alter table public.follows  enable row level security;
alter table public.gifts    enable row level security;

-- profiles: any signed-in user can read (that's the social layer);
-- you can only create/update your own row. pts moves only via send_gift + your own sync.
drop policy if exists "profiles read"   on public.profiles;
drop policy if exists "profiles insert" on public.profiles;
drop policy if exists "profiles update" on public.profiles;
create policy "profiles read"   on public.profiles for select using (auth.uid() is not null);
create policy "profiles insert" on public.profiles for insert with check (auth.uid() = id);
create policy "profiles update" on public.profiles for update using (auth.uid() = id) with check (auth.uid() = id);

-- saves: strictly owner-only, all operations
drop policy if exists "saves all own" on public.saves;
create policy "saves all own" on public.saves for all using (auth.uid() = id) with check (auth.uid() = id);

-- follows: manage your own follow list; read your own rows
drop policy if exists "follows read own"   on public.follows;
drop policy if exists "follows insert own" on public.follows;
drop policy if exists "follows delete own" on public.follows;
create policy "follows read own"   on public.follows for select using (auth.uid() = follower);
create policy "follows insert own" on public.follows for insert with check (auth.uid() = follower);
create policy "follows delete own" on public.follows for delete using (auth.uid() = follower);

-- gifts: read only gifts you sent or received. NO insert/update/delete policy
-- → direct writes are denied; the send_gift() function below is the only door.
drop policy if exists "gifts read own" on public.gifts;
create policy "gifts read own" on public.gifts for select using (auth.uid() = from_id or auth.uid() = to_id);

-- ═══════════════ FUNCTIONS (security definer = the referee) ═══════════════

-- send_gift: validates everything server-side, moves points atomically.
-- Caps: 1–50 per gift, 100/day per sender, must actually have the points.
create or replace function public.send_gift(to_code text, amt int, msg text default '')
returns json
language plpgsql security definer set search_path = public
as $$
declare
  sender uuid := auth.uid();
  target public.profiles%rowtype;
  today_total int;
begin
  if sender is null then raise exception 'Sign in first.'; end if;
  if amt is null or amt < 1 or amt > 50 then raise exception 'Gift must be 1–50 points.'; end if;
  if char_length(coalesce(msg,'')) > 140 then raise exception 'Message too long (140 max).'; end if;

  select * into target from public.profiles where friend_code = upper(trim(to_code));
  if target.id is null then raise exception 'No player with that code.'; end if;
  if target.id = sender then raise exception 'You cannot gift yourself. Nice try.'; end if;

  select coalesce(sum(amount),0) into today_total
    from public.gifts where from_id = sender and created_at > now() - interval '24 hours';
  if today_total + amt > 100 then raise exception 'Daily gift limit is 100 points.'; end if;

  update public.profiles set pts = pts - amt, updated_at = now()
    where id = sender and pts >= amt;
  if not found then raise exception 'Not enough points.'; end if;

  update public.profiles set pts = pts + amt, updated_at = now() where id = target.id;
  insert into public.gifts (from_id, to_id, amount, message) values (sender, target.id, amt, msg);

  return json_build_object('ok', true, 'to', target.display_name, 'amount', amt);
end $$;

-- lookup_code: find a player by friend code (for the add-friend flow)
create or replace function public.lookup_code(code text)
returns table (id uuid, handle text, display_name text, friend_code text, level int, week_xp int, chain int)
language sql security definer set search_path = public
as $$
  select id, handle, display_name, friend_code, level, week_xp, chain
  from public.profiles where friend_code = upper(trim(code)) and auth.uid() is not null;
$$;

-- gift_totals: net gift balance for the signed-in user (received - sent)
create or replace function public.gift_totals()
returns json language sql security definer set search_path = public
as $$
  select json_build_object(
    'received', coalesce((select sum(amount) from public.gifts where to_id   = auth.uid()),0),
    'sent',     coalesce((select sum(amount) from public.gifts where from_id = auth.uid()),0)
  );
$$;

-- keep updated_at honest
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;
drop trigger if exists profiles_touch on public.profiles;
create trigger profiles_touch before update on public.profiles for each row execute function public.touch_updated_at();
drop trigger if exists saves_touch on public.saves;
create trigger saves_touch before update on public.saves for each row execute function public.touch_updated_at();

-- lock down function execution to signed-in users
revoke all on function public.send_gift(text,int,text) from anon;
revoke all on function public.gift_totals() from anon;
