-- Initial schema — physical-improvement-app (SPINE §79 data model, §116 RLS)
-- Authz rule-of-record: every row user-scoped, RLS enforced on every table.
-- Identity: Supabase built-in auth.users IS the SPINE `user` entity; everything FKs to it.

-- ============================================================
-- Enums (SPINE-specified closed sets; open/unspecified sets use text)
-- ============================================================
create type experience_level as enum ('none', 'beginner', 'intermediate', 'advanced');
create type routine_status   as enum ('active', 'superseded');
create type session_status   as enum ('planned', 'in_progress', 'done', 'skipped', 'partial');
create type kpi_source       as enum ('logged', 'manual');
-- values below are assumptions (SPINE said "enum" without enumerating) — revise if needed
create type sex              as enum ('male', 'female', 'other', 'prefer_not_to_say');
create type energy_level     as enum ('low', 'medium', 'high');

-- ============================================================
-- Tables
-- ============================================================

-- exercise: GLOBAL reference data (wger import + curation), NOT user-scoped
create table public.exercise (
  key           text primary key,
  name          text not null,
  muscles       text[] not null default '{}',
  equipment_key text,
  image_url     text,
  instructions  text
);

-- profile: one per user; injuries/constraint_tags are GDPR Art.9 sensitive (see hardening note)
create table public.profile (
  user_id         uuid primary key references auth.users (id) on delete cascade,
  age             int,
  sex             sex,
  height_cm       int,
  weight_kg       numeric(5,2),
  experience      experience_level not null default 'none',
  injuries        jsonb not null default '[]'::jsonb,   -- [{area, note}]
  constraint_tags jsonb not null default '[]'::jsonb,   -- from note parsing
  created_at      timestamptz not null default now()
);

-- gym: one per user at P0 (unique enforces it); equipment = moat seed (§120a)
create table public.gym (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users (id) on delete cascade,
  name       text not null,
  equipment  jsonb not null default '[]'::jsonb,        -- equipment_key[]
  created_at timestamptz not null default now(),
  unique (user_id)
);

create table public.availability (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  weekly     jsonb not null default '[]'::jsonb,        -- [{day, start, minutes}]
  created_at timestamptz not null default now()
);

create table public.goal (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users (id) on delete cascade,
  template    text,                                     -- open set → text
  statement   text,
  target_date date,
  status      text not null default 'active',           -- open set → text
  created_at  timestamptz not null default now()
);

create table public.milestone (
  id          uuid primary key default gen_random_uuid(),
  goal_id     uuid not null references public.goal (id) on delete cascade,
  seq         int not null,
  due_date    date,
  kpi_targets jsonb not null default '{}'::jsonb
);

create table public.kpi (
  id      uuid primary key default gen_random_uuid(),
  goal_id uuid not null references public.goal (id) on delete cascade,
  key     text not null,
  unit    text,
  target  numeric,
  source  kpi_source not null default 'manual'
);

create table public.kpi_entry (
  id          uuid primary key default gen_random_uuid(),
  kpi_id      uuid not null references public.kpi (id) on delete cascade,
  value       numeric not null,
  recorded_at timestamptz not null default now()
);

-- routine: append-only history = moat seed (§120b); supersede-on-replan enforced in app logic
create table public.routine (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users (id) on delete cascade,
  week_start     date not null,
  status         routine_status not null default 'active',
  generated_from jsonb,                                 -- input snapshot
  created_at     timestamptz not null default now()
);

create table public.session (
  id                uuid primary key default gen_random_uuid(),
  routine_id        uuid not null references public.routine (id) on delete cascade,
  scheduled_day     date,
  scheduled_minutes int,
  status            session_status not null default 'planned',
  started_at        timestamptz,
  ended_at          timestamptz,
  energy            energy_level,
  note              text
);

create table public.session_exercise (
  id               uuid primary key default gen_random_uuid(),
  session_id       uuid not null references public.session (id) on delete cascade,
  exercise_key     text not null references public.exercise (key),
  seq              int not null,
  target_sets      int,
  target_reps      int,
  target_weight_kg numeric(6,2),
  alternates       jsonb not null default '[]'::jsonb,  -- exercise_key[]
  status           text
);

create table public.set_log (
  id                  uuid primary key default gen_random_uuid(),
  session_exercise_id uuid not null references public.session_exercise (id) on delete cascade,
  set_no              int not null,
  weight_kg           numeric(6,2),
  reps                int,
  machine_label       text,
  logged_at           timestamptz not null default now()
);

-- ============================================================
-- Indexes (FK columns — for RLS subquery perf + query perf; §115 <100ms)
-- ============================================================
create index on public.gym (user_id);
create index on public.goal (user_id);
create index on public.milestone (goal_id);
create index on public.kpi (goal_id);
create index on public.kpi_entry (kpi_id);
create index on public.routine (user_id);
create index on public.session (routine_id);
create index on public.session_exercise (session_id);
create index on public.session_exercise (exercise_key);
create index on public.set_log (session_exercise_id);

-- ============================================================
-- Row Level Security — enable on every table, then scope.
-- auth.uid() wrapped in a subquery so it evaluates once per query, not per row.
-- ============================================================
alter table public.profile          enable row level security;
alter table public.gym              enable row level security;
alter table public.availability     enable row level security;
alter table public.goal             enable row level security;
alter table public.milestone        enable row level security;
alter table public.kpi              enable row level security;
alter table public.kpi_entry        enable row level security;
alter table public.routine          enable row level security;
alter table public.session          enable row level security;
alter table public.session_exercise enable row level security;
alter table public.set_log          enable row level security;
alter table public.exercise         enable row level security;

-- Direct user_id ownership
create policy "own profile" on public.profile for all
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "own gym" on public.gym for all
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "own availability" on public.availability for all
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "own goal" on public.goal for all
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "own routine" on public.routine for all
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

-- Transitive ownership (scoped through parent rows)
create policy "own milestone" on public.milestone for all
  using (exists (select 1 from public.goal g
    where g.id = milestone.goal_id and g.user_id = (select auth.uid())))
  with check (exists (select 1 from public.goal g
    where g.id = milestone.goal_id and g.user_id = (select auth.uid())));

create policy "own kpi" on public.kpi for all
  using (exists (select 1 from public.goal g
    where g.id = kpi.goal_id and g.user_id = (select auth.uid())))
  with check (exists (select 1 from public.goal g
    where g.id = kpi.goal_id and g.user_id = (select auth.uid())));

create policy "own kpi_entry" on public.kpi_entry for all
  using (exists (select 1 from public.kpi k join public.goal g on g.id = k.goal_id
    where k.id = kpi_entry.kpi_id and g.user_id = (select auth.uid())))
  with check (exists (select 1 from public.kpi k join public.goal g on g.id = k.goal_id
    where k.id = kpi_entry.kpi_id and g.user_id = (select auth.uid())));

create policy "own session" on public.session for all
  using (exists (select 1 from public.routine r
    where r.id = session.routine_id and r.user_id = (select auth.uid())))
  with check (exists (select 1 from public.routine r
    where r.id = session.routine_id and r.user_id = (select auth.uid())));

create policy "own session_exercise" on public.session_exercise for all
  using (exists (select 1 from public.session s join public.routine r on r.id = s.routine_id
    where s.id = session_exercise.session_id and r.user_id = (select auth.uid())))
  with check (exists (select 1 from public.session s join public.routine r on r.id = s.routine_id
    where s.id = session_exercise.session_id and r.user_id = (select auth.uid())));

create policy "own set_log" on public.set_log for all
  using (exists (select 1 from public.session_exercise se
    join public.session s on s.id = se.session_id
    join public.routine r on r.id = s.routine_id
    where se.id = set_log.session_exercise_id and r.user_id = (select auth.uid())))
  with check (exists (select 1 from public.session_exercise se
    join public.session s on s.id = se.session_id
    join public.routine r on r.id = s.routine_id
    where se.id = set_log.session_exercise_id and r.user_id = (select auth.uid())));

-- exercise: global reference — authenticated may read; writes are service-role only (no write policy)
create policy "read exercises" on public.exercise for select to authenticated using (true);
