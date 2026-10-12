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
-- Seed: the ingredient directory (225 items)
-- ---------------------------------------------------------------------------
insert into ingredient_catalog (name, category, default_unit, allowed_units, aliases) values
('Onion', 'Vegetables', 'pcs', array['pcs','g','kg']::text[], array['pyaz','pyaaz','kanda','dungri']::text[]),
('Red onion', 'Vegetables', 'pcs', array['pcs','g','kg']::text[], array['lal pyaz']::text[]),
('Spring onion', 'Vegetables', 'bunch', array['bunch','g']::text[], array['hara pyaz','scallion']::text[]),
('Shallots', 'Vegetables', 'g', array['g','kg','pcs']::text[], array['sambar onion','chhota pyaz']::text[]),
('Tomato', 'Vegetables', 'pcs', array['pcs','g','kg']::text[], array['tamatar','tameta']::text[]),
('Cherry tomato', 'Vegetables', 'g', array['g','kg','pcs']::text[], '{}'),
('Potato', 'Vegetables', 'pcs', array['pcs','g','kg']::text[], array['aloo','batata']::text[]),
('Sweet potato', 'Vegetables', 'pcs', array['pcs','g','kg']::text[], array['shakarkandi']::text[]),
('Garlic', 'Vegetables', 'g', array['g','kg','pcs']::text[], array['lahsun','lehsun','lasun']::text[]),
('Ginger', 'Vegetables', 'g', array['g','kg','pcs']::text[], array['adrak','adu']::text[]),
('Green chilli', 'Vegetables', 'g', array['g','kg','pcs']::text[], array['hari mirch','mirchi']::text[]),
('Capsicum', 'Vegetables', 'pcs', array['pcs','g','kg']::text[], array['shimla mirch','bell pepper']::text[]),
('Red bell pepper', 'Vegetables', 'pcs', array['pcs','g','kg']::text[], array['lal shimla mirch']::text[]),
('Yellow bell pepper', 'Vegetables', 'pcs', array['pcs','g','kg']::text[], '{}'),
('Carrot', 'Vegetables', 'pcs', array['pcs','g','kg']::text[], array['gajar']::text[]),
('Beetroot', 'Vegetables', 'pcs', array['pcs','g','kg']::text[], array['chukandar']::text[]),
('Radish', 'Vegetables', 'pcs', array['pcs','g','kg']::text[], array['mooli','muli']::text[]),
('Cauliflower', 'Vegetables', 'pcs', array['pcs','g','kg']::text[], array['gobhi','phool gobhi','gobi']::text[]),
('Cabbage', 'Vegetables', 'pcs', array['pcs','g','kg']::text[], array['patta gobhi','band gobhi']::text[]),
('Broccoli', 'Vegetables', 'pcs', array['pcs','g','kg']::text[], '{}'),
('Green peas', 'Vegetables', 'g', array['g','kg']::text[], array['matar','mutter','peas']::text[]),
('Frozen peas', 'Vegetables', 'g', array['g','kg']::text[], array['frozen matar']::text[]),
('French beans', 'Vegetables', 'g', array['g','kg','pcs']::text[], array['beans','phali']::text[]),
('Cluster beans', 'Vegetables', 'g', array['g','kg']::text[], array['gawar','guar phali']::text[]),
('Broad beans', 'Vegetables', 'g', array['g','kg']::text[], array['sem','papdi']::text[]),
('Okra', 'Vegetables', 'g', array['g','kg']::text[], array['bhindi','lady finger','ladies finger']::text[]),
('Brinjal', 'Vegetables', 'pcs', array['pcs','g','kg']::text[], array['baingan','eggplant','aubergine','vangi']::text[]),
('Bottle gourd', 'Vegetables', 'pcs', array['pcs','g','kg']::text[], array['lauki','dudhi','ghiya']::text[]),
('Ridge gourd', 'Vegetables', 'pcs', array['pcs','g','kg']::text[], array['turai','tori','dodka']::text[]),
('Bitter gourd', 'Vegetables', 'pcs', array['pcs','g','kg']::text[], array['karela']::text[]),
('Snake gourd', 'Vegetables', 'pcs', array['pcs','g','kg']::text[], array['chichinda','padwal']::text[]),
('Ash gourd', 'Vegetables', 'g', array['g','kg','pcs']::text[], array['petha']::text[]),
('Pumpkin', 'Vegetables', 'g', array['g','kg','pcs']::text[], array['kaddu','sitaphal','lal kaddu']::text[]),
('Tinda', 'Vegetables', 'pcs', array['pcs','g','kg']::text[], array['round gourd']::text[]),
('Parwal', 'Vegetables', 'pcs', array['pcs','g','kg']::text[], array['pointed gourd']::text[]),
('Cucumber', 'Vegetables', 'pcs', array['pcs','g','kg']::text[], array['kheera','kakdi']::text[]),
('Zucchini', 'Vegetables', 'pcs', array['pcs','g','kg']::text[], '{}'),
('Raw banana', 'Vegetables', 'pcs', array['pcs','g','kg']::text[], array['kaccha kela','plantain']::text[]),
('Raw papaya', 'Vegetables', 'g', array['g','kg','pcs']::text[], array['kaccha papita']::text[]),
('Drumstick', 'Vegetables', 'pcs', array['pcs','g','kg']::text[], array['sahjan','moringa','shevga']::text[]),
('Mushroom', 'Vegetables', 'g', array['g','kg']::text[], array['khumb','kukurmutta']::text[]),
('Baby corn', 'Vegetables', 'g', array['g','kg']::text[], '{}'),
('Sweet corn', 'Vegetables', 'g', array['g','kg']::text[], array['makai','bhutta','corn']::text[]),
('Jackfruit', 'Vegetables', 'g', array['g','kg']::text[], array['kathal']::text[]),
('Colocasia', 'Vegetables', 'g', array['g','kg']::text[], array['arbi','arvi','taro']::text[]),
('Yam', 'Vegetables', 'g', array['g','kg']::text[], array['suran','jimikand','elephant foot yam']::text[]),
('Lotus stem', 'Vegetables', 'g', array['g','kg']::text[], array['kamal kakdi','nadru']::text[]),
('Raw mango', 'Vegetables', 'pcs', array['pcs','g','kg']::text[], array['kairi','kaccha aam']::text[]),
('Lemon', 'Vegetables', 'pcs', array['pcs']::text[], array['nimbu','limbu','lime']::text[]),
('Spinach', 'Leafy greens & herbs', 'bunch', array['bunch','g']::text[], array['palak']::text[]),
('Fenugreek leaves', 'Leafy greens & herbs', 'bunch', array['bunch','g']::text[], array['methi','methi leaves']::text[]),
('Coriander leaves', 'Leafy greens & herbs', 'bunch', array['bunch','g']::text[], array['dhaniya','dhania','hara dhaniya','cilantro','coriander']::text[]),
('Mint', 'Leafy greens & herbs', 'bunch', array['bunch','g']::text[], array['pudina']::text[]),
('Curry leaves', 'Leafy greens & herbs', 'bunch', array['bunch','g']::text[], array['kadi patta','kadhi patta','meetha neem']::text[]),
('Mustard greens', 'Leafy greens & herbs', 'bunch', array['bunch','g']::text[], array['sarson','sarson ka saag']::text[]),
('Dill leaves', 'Leafy greens & herbs', 'bunch', array['bunch','g']::text[], array['suva','shepu','soya leaves']::text[]),
('Amaranth leaves', 'Leafy greens & herbs', 'bunch', array['bunch','g']::text[], array['chaulai','lal saag']::text[]),
('Bathua', 'Leafy greens & herbs', 'bunch', array['bunch','g']::text[], array['chenopodium']::text[]),
('Lettuce', 'Leafy greens & herbs', 'bunch', array['bunch','g']::text[], '{}'),
('Basil', 'Leafy greens & herbs', 'bunch', array['bunch','g']::text[], array['tulsi']::text[]),
('Banana', 'Fruits', 'pcs', array['pcs','g','kg']::text[], array['kela']::text[]),
('Apple', 'Fruits', 'pcs', array['pcs','g','kg']::text[], array['seb']::text[]),
('Mango', 'Fruits', 'pcs', array['pcs','g','kg']::text[], array['aam']::text[]),
('Orange', 'Fruits', 'pcs', array['pcs','g','kg']::text[], array['santra','narangi']::text[]),
('Papaya', 'Fruits', 'g', array['g','kg','pcs']::text[], array['papita']::text[]),
('Pomegranate', 'Fruits', 'pcs', array['pcs','g','kg']::text[], array['anar']::text[]),
('Grapes', 'Fruits', 'g', array['g','kg']::text[], array['angoor']::text[]),
('Guava', 'Fruits', 'pcs', array['pcs','g','kg']::text[], array['amrud']::text[]),
('Pineapple', 'Fruits', 'pcs', array['pcs','g','kg']::text[], array['ananas']::text[]),
('Watermelon', 'Fruits', 'g', array['g','kg','pcs']::text[], array['tarbooz']::text[]),
('Muskmelon', 'Fruits', 'pcs', array['pcs','g','kg']::text[], array['kharbooja']::text[]),
('Chikoo', 'Fruits', 'pcs', array['pcs','g','kg']::text[], array['sapota']::text[]),
('Pear', 'Fruits', 'pcs', array['pcs','g','kg']::text[], array['nashpati']::text[]),
('Strawberry', 'Fruits', 'g', array['g','kg']::text[], '{}'),
('Coconut', 'Fruits', 'pcs', array['pcs']::text[], array['nariyal','thengai']::text[]),
('Fresh grated coconut', 'Fruits', 'g', array['g','kg']::text[], array['kasa hua nariyal']::text[]),
('Avocado', 'Fruits', 'pcs', array['pcs','g','kg']::text[], '{}'),
('Toor dal', 'Dals & pulses', 'g', array['g','kg']::text[], array['arhar dal','tuvar dal','pigeon pea','tur dal']::text[]),
('Moong dal', 'Dals & pulses', 'g', array['g','kg']::text[], array['yellow moong','mung dal']::text[]),
('Green moong', 'Dals & pulses', 'g', array['g','kg']::text[], array['sabut moong','whole moong']::text[]),
('Masoor dal', 'Dals & pulses', 'g', array['g','kg']::text[], array['red lentil','lal masoor']::text[]),
('Whole masoor', 'Dals & pulses', 'g', array['g','kg']::text[], array['sabut masoor','brown lentil']::text[]),
('Chana dal', 'Dals & pulses', 'g', array['g','kg']::text[], array['split bengal gram']::text[]),
('Urad dal', 'Dals & pulses', 'g', array['g','kg']::text[], array['white urad','dhuli urad']::text[]),
('Whole urad', 'Dals & pulses', 'g', array['g','kg']::text[], array['sabut urad','kali dal','black gram']::text[]),
('Rajma', 'Dals & pulses', 'g', array['g','kg']::text[], array['kidney beans']::text[]),
('Kabuli chana', 'Dals & pulses', 'g', array['g','kg']::text[], array['chickpeas','chole','safed chana','garbanzo']::text[]),
('Kala chana', 'Dals & pulses', 'g', array['g','kg']::text[], array['black chickpeas','bengal gram']::text[]),
('Lobia', 'Dals & pulses', 'g', array['g','kg']::text[], array['black eyed beans','chawli']::text[]),
('Moth beans', 'Dals & pulses', 'g', array['g','kg']::text[], array['matki','moth dal']::text[]),
('Horse gram', 'Dals & pulses', 'g', array['g','kg']::text[], array['kulthi','kollu']::text[]),
('Soya chunks', 'Dals & pulses', 'g', array['g','kg']::text[], array['nutrela','soya badi']::text[]),
('Roasted chana', 'Dals & pulses', 'g', array['g','kg']::text[], array['bhuna chana','dalia chana']::text[]),
('Basmati rice', 'Rice & grains', 'g', array['g','kg']::text[], array['basmati chawal']::text[]),
('Rice', 'Rice & grains', 'g', array['g','kg']::text[], array['chawal','sona masoori','kolam','white rice']::text[]),
('Brown rice', 'Rice & grains', 'g', array['g','kg']::text[], '{}'),
('Idli rice', 'Rice & grains', 'g', array['g','kg']::text[], array['parboiled rice','ukda chawal']::text[]),
('Poha', 'Rice & grains', 'g', array['g','kg']::text[], array['flattened rice','chivda','aval','pohe']::text[]),
('Puffed rice', 'Rice & grains', 'g', array['g','kg']::text[], array['murmura','kurmura','mamra']::text[]),
('Sooji', 'Rice & grains', 'g', array['g','kg','tbsp']::text[], array['rava','semolina','suji']::text[]),
('Dalia', 'Rice & grains', 'g', array['g','kg']::text[], array['broken wheat','lapsi','daliya']::text[]),
('Oats', 'Rice & grains', 'g', array['g','kg']::text[], '{}'),
('Vermicelli', 'Rice & grains', 'packet', array['packet','g']::text[], array['seviyan','semiya','sevai']::text[]),
('Sabudana', 'Rice & grains', 'g', array['g','kg']::text[], array['sago','tapioca pearls']::text[]),
('Quinoa', 'Rice & grains', 'g', array['g','kg']::text[], '{}'),
('Millet', 'Rice & grains', 'g', array['g','kg']::text[], array['bajra','jowar','ragi grain']::text[]),
('Atta', 'Flours', 'g', array['g','kg']::text[], array['wheat flour','gehun ka atta','chapati flour']::text[]),
('Multigrain atta', 'Flours', 'g', array['g','kg']::text[], '{}'),
('Maida', 'Flours', 'g', array['g','kg']::text[], array['all purpose flour','refined flour']::text[]),
('Besan', 'Flours', 'g', array['g','kg']::text[], array['gram flour','chickpea flour']::text[]),
('Rice flour', 'Flours', 'g', array['g','kg']::text[], array['chawal ka atta']::text[]),
('Ragi flour', 'Flours', 'g', array['g','kg']::text[], array['nachni','finger millet flour']::text[]),
('Jowar flour', 'Flours', 'g', array['g','kg']::text[], array['jowar atta','sorghum flour']::text[]),
('Bajra flour', 'Flours', 'g', array['g','kg']::text[], array['bajra atta','pearl millet flour']::text[]),
('Makki ka atta', 'Flours', 'g', array['g','kg']::text[], array['corn flour','maize flour']::text[]),
('Cornflour', 'Flours', 'g', array['g','kg','tbsp']::text[], array['corn starch','arrowroot']::text[]),
('Idli batter', 'Flours', 'g', array['g','kg']::text[], array['dosa batter']::text[]),
('Milk', 'Dairy', 'ml', array['ml','L']::text[], array['doodh','dudh']::text[]),
('Curd', 'Dairy', 'g', array['g','kg']::text[], array['dahi','yogurt','yoghurt']::text[]),
('Paneer', 'Dairy', 'g', array['g','kg']::text[], array['cottage cheese']::text[]),
('Butter', 'Dairy', 'g', array['g','kg']::text[], array['makhan','makkhan']::text[]),
('Cheese', 'Dairy', 'g', array['g','kg']::text[], array['cheese slice','mozzarella']::text[]),
('Fresh cream', 'Dairy', 'ml', array['ml','g']::text[], array['malai','cream']::text[]),
('Buttermilk', 'Dairy', 'ml', array['ml','L']::text[], array['chaas','chhach','mattha']::text[]),
('Khoya', 'Dairy', 'g', array['g','kg']::text[], array['mawa']::text[]),
('Condensed milk', 'Dairy', 'ml', array['ml','g']::text[], array['milkmaid']::text[]),
('Eggs', 'Eggs', 'pcs', array['pcs','dozen']::text[], array['anda','ande','egg']::text[]),
('Chicken', 'Meat & seafood', 'g', array['g','kg']::text[], array['murgi','murgh']::text[]),
('Mutton', 'Meat & seafood', 'g', array['g','kg']::text[], array['goat meat','gosht']::text[]),
('Fish', 'Meat & seafood', 'g', array['g','kg']::text[], array['machli','macchi']::text[]),
('Prawns', 'Meat & seafood', 'g', array['g','kg']::text[], array['jhinga','shrimp']::text[]),
('Keema', 'Meat & seafood', 'g', array['g','kg']::text[], array['mince','minced meat']::text[]),
('Jeera', 'Whole spices', 'g', array['g','tsp','tbsp']::text[], array['cumin','cumin seeds','zeera']::text[]),
('Mustard seeds', 'Whole spices', 'g', array['g','tsp','tbsp']::text[], array['rai','sarson ke beej','rye']::text[]),
('Fennel seeds', 'Whole spices', 'g', array['g','tsp','tbsp']::text[], array['saunf','variyali']::text[]),
('Fenugreek seeds', 'Whole spices', 'g', array['g','tsp','tbsp']::text[], array['methi dana','methi seeds']::text[]),
('Ajwain', 'Whole spices', 'g', array['g','tsp','tbsp']::text[], array['carom seeds','owa']::text[]),
('Kalonji', 'Whole spices', 'g', array['g','tsp','tbsp']::text[], array['nigella seeds','onion seeds']::text[]),
('Coriander seeds', 'Whole spices', 'g', array['g','tsp','tbsp']::text[], array['sabut dhaniya']::text[]),
('Black pepper', 'Whole spices', 'g', array['g','tsp','tbsp']::text[], array['kali mirch','peppercorn']::text[]),
('Cloves', 'Whole spices', 'pcs', array['pcs','g']::text[], array['laung','lavang']::text[]),
('Green cardamom', 'Whole spices', 'pcs', array['pcs','g']::text[], array['elaichi','choti elaichi']::text[]),
('Black cardamom', 'Whole spices', 'pcs', array['pcs','g']::text[], array['badi elaichi']::text[]),
('Cinnamon', 'Whole spices', 'pcs', array['pcs','g']::text[], array['dalchini']::text[]),
('Bay leaf', 'Whole spices', 'pcs', array['pcs','g']::text[], array['tej patta']::text[]),
('Dry red chilli', 'Whole spices', 'pcs', array['pcs','g']::text[], array['sukhi lal mirch','sabut lal mirch']::text[]),
('Star anise', 'Whole spices', 'pcs', array['pcs','g']::text[], array['chakri phool','badiyan']::text[]),
('Mace', 'Whole spices', 'g', array['g','tsp','tbsp']::text[], array['javitri']::text[]),
('Nutmeg', 'Whole spices', 'pcs', array['pcs','g']::text[], array['jaiphal']::text[]),
('Poppy seeds', 'Whole spices', 'g', array['g','tsp','tbsp']::text[], array['khus khus','posto']::text[]),
('Haldi', 'Ground masalas', 'g', array['g','tsp','tbsp']::text[], array['turmeric','haldi powder','halad']::text[]),
('Red chilli powder', 'Ground masalas', 'g', array['g','tsp','tbsp']::text[], array['lal mirch powder','mirchi powder','chilli powder']::text[]),
('Kashmiri chilli powder', 'Ground masalas', 'g', array['g','tsp','tbsp']::text[], array['degi mirch']::text[]),
('Coriander powder', 'Ground masalas', 'g', array['g','tsp','tbsp']::text[], array['dhaniya powder']::text[]),
('Cumin powder', 'Ground masalas', 'g', array['g','tsp','tbsp']::text[], array['jeera powder','bhuna jeera']::text[]),
('Garam masala', 'Ground masalas', 'g', array['g','tsp','tbsp']::text[], '{}'),
('Chaat masala', 'Ground masalas', 'g', array['g','tsp','tbsp']::text[], '{}'),
('Kitchen king masala', 'Ground masalas', 'g', array['g','tsp','tbsp']::text[], '{}'),
('Pav bhaji masala', 'Ground masalas', 'g', array['g','tsp','tbsp']::text[], '{}'),
('Sambar powder', 'Ground masalas', 'g', array['g','tsp','tbsp']::text[], array['sambhar masala']::text[]),
('Rasam powder', 'Ground masalas', 'g', array['g','tsp','tbsp']::text[], '{}'),
('Chole masala', 'Ground masalas', 'g', array['g','tsp','tbsp']::text[], array['chana masala powder']::text[]),
('Biryani masala', 'Ground masalas', 'g', array['g','tsp','tbsp']::text[], '{}'),
('Amchur', 'Ground masalas', 'g', array['g','tsp','tbsp']::text[], array['dry mango powder','amchoor']::text[]),
('Kasuri methi', 'Ground masalas', 'g', array['g','tsp','tbsp']::text[], array['dried fenugreek leaves']::text[]),
('Black salt', 'Ground masalas', 'g', array['g','tsp','tbsp']::text[], array['kala namak']::text[]),
('Hing', 'Ground masalas', 'g', array['g','pinch']::text[], array['asafoetida','heeng']::text[]),
('Saffron', 'Ground masalas', 'g', array['g','pinch']::text[], array['kesar']::text[]),
('Salt', 'Ground masalas', 'g', array['g','kg','tbsp']::text[], array['namak','table salt']::text[]),
('Sugar', 'Sweeteners', 'g', array['g','kg','tbsp']::text[], array['cheeni','shakkar']::text[]),
('Jaggery', 'Sweeteners', 'g', array['g','kg','tbsp']::text[], array['gur','gud','vellam']::text[]),
('Honey', 'Sweeteners', 'ml', array['ml','g','tbsp']::text[], array['shahad','madh']::text[]),
('Brown sugar', 'Sweeteners', 'g', array['g','kg','tbsp']::text[], '{}'),
('Mustard oil', 'Oils & ghee', 'ml', array['ml','L']::text[], array['sarson ka tel','kachi ghani']::text[]),
('Sunflower oil', 'Oils & ghee', 'ml', array['ml','L']::text[], array['refined oil','oil','cooking oil']::text[]),
('Groundnut oil', 'Oils & ghee', 'ml', array['ml','L']::text[], array['peanut oil','moongphali tel']::text[]),
('Coconut oil', 'Oils & ghee', 'ml', array['ml','L']::text[], array['nariyal tel']::text[]),
('Olive oil', 'Oils & ghee', 'ml', array['ml','L']::text[], '{}'),
('Sesame oil', 'Oils & ghee', 'ml', array['ml','L']::text[], array['til ka tel','gingelly oil']::text[]),
('Ghee', 'Oils & ghee', 'ml', array['ml','L','g','kg']::text[], array['desi ghee','clarified butter']::text[]),
('Peanuts', 'Nuts & seeds', 'g', array['g','kg']::text[], array['moongphali','shengdana','groundnut']::text[]),
('Cashews', 'Nuts & seeds', 'g', array['g','kg']::text[], array['kaju']::text[]),
('Almonds', 'Nuts & seeds', 'g', array['g','kg']::text[], array['badam']::text[]),
('Raisins', 'Nuts & seeds', 'g', array['g','kg']::text[], array['kishmish','kismis']::text[]),
('Walnuts', 'Nuts & seeds', 'g', array['g','kg']::text[], array['akhrot']::text[]),
('Pistachios', 'Nuts & seeds', 'g', array['g','kg']::text[], array['pista']::text[]),
('Dates', 'Nuts & seeds', 'g', array['g','kg']::text[], array['khajur']::text[]),
('Dry coconut', 'Nuts & seeds', 'g', array['g','kg','pcs']::text[], array['copra','sukha nariyal','desiccated coconut']::text[]),
('Sesame seeds', 'Nuts & seeds', 'g', array['g','tsp','tbsp']::text[], array['til']::text[]),
('Flax seeds', 'Nuts & seeds', 'g', array['g','tsp','tbsp']::text[], array['alsi']::text[]),
('Makhana', 'Nuts & seeds', 'g', array['g','kg']::text[], array['fox nuts','lotus seeds']::text[]),
('Tamarind', 'Sauces & pastes', 'g', array['g','tbsp']::text[], array['imli','chinch']::text[]),
('Ginger garlic paste', 'Sauces & pastes', 'g', array['g','tbsp']::text[], array['adrak lahsun paste']::text[]),
('Tomato puree', 'Sauces & pastes', 'ml', array['ml','g','tbsp']::text[], '{}'),
('Tomato ketchup', 'Sauces & pastes', 'ml', array['ml','g','tbsp']::text[], array['ketchup','tomato sauce']::text[]),
('Soy sauce', 'Sauces & pastes', 'ml', array['ml','g','tbsp']::text[], '{}'),
('Green chilli sauce', 'Sauces & pastes', 'ml', array['ml','g','tbsp']::text[], '{}'),
('Red chilli sauce', 'Sauces & pastes', 'ml', array['ml','g','tbsp']::text[], array['schezwan sauce']::text[]),
('Vinegar', 'Sauces & pastes', 'ml', array['ml','g','tbsp']::text[], array['sirka']::text[]),
('Mayonnaise', 'Sauces & pastes', 'ml', array['ml','g','tbsp']::text[], array['mayo']::text[]),
('Peanut butter', 'Sauces & pastes', 'g', array['g','tbsp']::text[], '{}'),
('Coconut milk', 'Sauces & pastes', 'ml', array['ml','g','tbsp']::text[], array['nariyal doodh']::text[]),
('Mango pickle', 'Pickles & chutneys', 'g', array['g','tbsp']::text[], array['aam ka achar','achaar']::text[]),
('Lemon pickle', 'Pickles & chutneys', 'g', array['g','tbsp']::text[], array['nimbu ka achar']::text[]),
('Mixed pickle', 'Pickles & chutneys', 'g', array['g','tbsp']::text[], array['achar']::text[]),
('Green chutney', 'Pickles & chutneys', 'g', array['g','tbsp']::text[], array['hari chutney','pudina chutney']::text[]),
('Tamarind chutney', 'Pickles & chutneys', 'g', array['g','tbsp']::text[], array['imli chutney','meethi chutney']::text[]),
('Papad', 'Pickles & chutneys', 'packet', array['packet','g']::text[], array['papadum','appalam']::text[]),
('Bread', 'Breads & ready-to-eat', 'slices', array['slices','packet']::text[], array['white bread','double roti']::text[]),
('Brown bread', 'Breads & ready-to-eat', 'slices', array['slices','packet']::text[], array['whole wheat bread']::text[]),
('Pav', 'Breads & ready-to-eat', 'slices', array['slices','packet']::text[], array['ladi pav','bun']::text[]),
('Burger bun', 'Breads & ready-to-eat', 'slices', array['slices','packet']::text[], '{}'),
('Roti', 'Breads & ready-to-eat', 'pcs', array['pcs']::text[], array['chapati','phulka']::text[]),
('Frozen paratha', 'Breads & ready-to-eat', 'packet', array['packet','g']::text[], array['ready paratha']::text[]),
('Tortilla', 'Breads & ready-to-eat', 'pcs', array['pcs']::text[], array['wrap']::text[]),
('Rusk', 'Breads & ready-to-eat', 'packet', array['packet','g']::text[], array['toast','khari']::text[]),
('Instant noodles', 'Packaged & instant', 'packet', array['packet','g']::text[], array['maggi','noodles']::text[]),
('Hakka noodles', 'Packaged & instant', 'packet', array['packet','g']::text[], '{}'),
('Pasta', 'Packaged & instant', 'packet', array['packet','g']::text[], array['macaroni','penne']::text[]),
('Cornflakes', 'Packaged & instant', 'g', array['g','kg']::text[], array['cereal','muesli']::text[]),
('Bhujia', 'Packaged & instant', 'g', array['g','kg']::text[], array['namkeen','sev']::text[]),
('Tofu', 'Packaged & instant', 'g', array['g','kg']::text[], '{}'),
('Tea', 'Beverages', 'g', array['g','kg']::text[], array['chai patti','tea leaves']::text[]),
('Coffee', 'Beverages', 'g', array['g','kg']::text[], array['instant coffee']::text[]),
('Water', 'Basics', 'ml', array['ml','L']::text[], array['paani','pani']::text[]);
