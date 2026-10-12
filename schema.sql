-- Aaj Kya Banega: database schema (Supabase / Postgres)
-- Every user-owned table carries user_id and is locked by Row Level Security,
-- so a signed-in user can only ever read or write their own rows.

-- ---------------------------------------------------------------------------
-- 1. profiles: one row per user (id = Supabase auth user id)
-- ---------------------------------------------------------------------------
create table profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  name        text not null default '',
  email       text not null,
  diet        text not null default 'veg' check (diet in ('veg', 'egg', 'nonveg')),
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- 2. ingredient_catalog: shared master list (autocomplete, category, default unit)
--    Read-only for users. You manage it.
-- ---------------------------------------------------------------------------
create table ingredient_catalog (
  id            serial primary key,
  name          text not null unique,
  category      text not null,
  default_unit  text not null,
  allowed_units text[] not null,               -- onion: {pcs,g,kg}; never ml
  aliases       text[] not null default '{}'   -- pyaz, kanda: used by search
);

-- ---------------------------------------------------------------------------
-- 3. user_ingredients: what is in each user's kitchen. Quantity is optional.
-- ---------------------------------------------------------------------------
create table user_ingredients (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references profiles(id) on delete cascade,
  catalog_id  int references ingredient_catalog(id),        -- null for items not in the catalog
  name        text not null,
  category    text not null default 'Others',
  quantity    numeric check (quantity is null or quantity >= 0),
  unit        text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create unique index user_ingredients_one_per_name on user_ingredients (user_id, lower(name));

-- ---------------------------------------------------------------------------
-- 4. user_staples: things a user always has (salt, oil, haldi...). Not counted as ingredients.
-- ---------------------------------------------------------------------------
create table user_staples (
  user_id  uuid not null references profiles(id) on delete cascade,
  name     text not null,
  primary key (user_id, name)
);

-- ---------------------------------------------------------------------------
-- 5. suggestions: one row per "Suggest food" press, with the AI call's metadata.
--    This is the log behind cost tracking, rate limits and evals.
-- ---------------------------------------------------------------------------
create table suggestions (
  client_id             text,                    -- id the app generated, so favourites can point at meals before the round trip
  id                    uuid primary key default gen_random_uuid(),
  user_id               uuid not null references profiles(id) on delete cascade,
  slot                  text not null check (slot in ('breakfast', 'lunch', 'both')),
  possible              boolean not null,
  reason                text,
  unlock_ingredient     text,
  ingredients_snapshot  jsonb not null,          -- exactly what the model was given
  model                 text not null,
  effort                text,
  prompt_version        text not null,           -- lets evals compare prompt v1 vs v2
  input_tokens          int,
  output_tokens         int,
  cost_usd              numeric(10, 6),
  latency_ms            int,
  stop_reason           text,
  created_at            timestamptz not null default now()
);
create index suggestions_user_time on suggestions (user_id, created_at desc);

-- ---------------------------------------------------------------------------
-- 6. suggestion_meals: the individual dishes inside a suggestion (breakfast, lunch)
-- ---------------------------------------------------------------------------
create table suggestion_meals (
  id             uuid primary key default gen_random_uuid(),
  suggestion_id  uuid not null references suggestions(id) on delete cascade,
  user_id        uuid not null references profiles(id) on delete cascade,
  slot           text not null check (slot in ('breakfast', 'lunch')),
  dish           text not null,
  why            text,
  minutes        int,
  uses           text[] not null default '{}',
  steps          text[] not null default '{}',
  created_at     timestamptz not null default now()
);
create index suggestion_meals_user on suggestion_meals (user_id, created_at desc);

-- ---------------------------------------------------------------------------
-- 7. favourites: meals a user saved with the heart
-- ---------------------------------------------------------------------------
create table favourites (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references profiles(id) on delete cascade,
  meal_id     uuid not null references suggestion_meals(id) on delete cascade,
  created_at  timestamptz not null default now(),
  unique (user_id, meal_id)
);

-- ---------------------------------------------------------------------------
-- 8. meal_ratings: thumbs up / down per meal. The seed for evals.
-- ---------------------------------------------------------------------------
create table meal_ratings (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references profiles(id) on delete cascade,
  meal_id     uuid not null references suggestion_meals(id) on delete cascade,
  value       smallint not null check (value in (-1, 1)),
  comment     text,
  created_at  timestamptz not null default now(),
  unique (user_id, meal_id)
);

-- ---------------------------------------------------------------------------
-- Row Level Security: each user sees only their own rows
-- ---------------------------------------------------------------------------
alter table profiles          enable row level security;
alter table ingredient_catalog enable row level security;
alter table user_ingredients  enable row level security;
alter table user_staples      enable row level security;
alter table suggestions       enable row level security;
alter table suggestion_meals  enable row level security;
alter table favourites        enable row level security;
alter table meal_ratings      enable row level security;

create policy "own profile" on profiles for all using (id = auth.uid()) with check (id = auth.uid());
create policy "catalog is readable" on ingredient_catalog for select using (auth.role() = 'authenticated');
create policy "own ingredients" on user_ingredients for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "own staples" on user_staples for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "own favourites" on favourites for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "own ratings" on meal_ratings for all using (user_id = auth.uid()) with check (user_id = auth.uid());
-- For now the app saves its own suggestions. Once the AI call moves into a Supabase function,
-- these two become read-only for users and the function writes them.
create policy "own suggestions" on suggestions for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "own meals" on suggestion_meals for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- New user: create their profile and default staples automatically on sign-up
-- ---------------------------------------------------------------------------
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, name, email)
  values (new.id, coalesce(new.raw_user_meta_data->>'name', split_part(new.email, '@', 1)), new.email);
  insert into public.user_staples (user_id, name)
  select new.id, s from unnest(array['Salt','Sunflower oil','Water','Haldi','Jeera','Mustard seeds','Red chilli powder','Garam masala']) as s;
  return new;
end; $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- 9-11. Evals (admin only: RLS on, no user policies, so only the server can touch them)
-- ---------------------------------------------------------------------------
create table eval_cases (
  id           serial primary key,
  ingredients  text[] not null,
  slot         text not null default 'both',
  expect       text not null check (expect in ('possible', 'impossible')),
  category     text not null,                    -- full, sparse, near-miss, impossible
  split        text not null default 'test' check (split in ('train', 'test'))
);
create table eval_runs (
  id              uuid primary key default gen_random_uuid(),
  model           text not null,
  effort          text,
  prompt_version  text not null,
  notes           text,
  created_at      timestamptz not null default now()
);
create table eval_results (
  id           uuid primary key default gen_random_uuid(),
  run_id       uuid not null references eval_runs(id) on delete cascade,
  case_id      int not null references eval_cases(id),
  output       jsonb not null,
  grounded     boolean,                          -- code check
  ungrounded   text[],
  said_possible boolean,
  rubric       jsonb,                            -- judge verdicts per criterion
  input_tokens int, output_tokens int, cost_usd numeric(10, 6), latency_ms int, stop_reason text
);
alter table eval_cases   enable row level security;
alter table eval_runs    enable row level security;
alter table eval_results enable row level security;

-- ---------------------------------------------------------------------------
-- v2 (13 Oct 2026): keep the model's full answer for evals, and the nearest-dish hint
-- ---------------------------------------------------------------------------
alter table suggestions add column if not exists raw_output jsonb;              -- all 3 candidates per meal, as the model returned them
alter table suggestions add column if not exists grounding_dropped jsonb;       -- candidates our code check removed, and why
alter table suggestions add column if not exists nearest_dish text;
alter table suggestions add column if not exists nearest_missing text[];
alter table suggestions add column if not exists temperature numeric;
