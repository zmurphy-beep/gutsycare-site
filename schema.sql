-- ============================================
-- GUTSY CARE MARKETPLACE — SUPABASE SCHEMA
-- ============================================
-- Run this in Supabase SQL Editor


-- ── EXTENSIONS ──────────────────────────────
create extension if not exists "uuid-ossp";


-- ── PROFILES ────────────────────────────────
-- Extends Supabase auth.users with public info
create table profiles (
  id            uuid primary key references auth.users(id) on delete cascade,
  username      text unique,
  full_name     text,
  avatar_url    text,
  bio           text,
  location      text,
  phone         text,
  is_verified   boolean default false,
  is_seller     boolean default false,
  seller_rating numeric(3,2) default 0,
  total_sales   integer default 0,
  stripe_account_id text,           -- Stripe Connect account ID for payouts
  created_at    timestamptz default now(),
  updated_at    timestamptz default now()
);

-- Auto-create profile when user signs up
create or replace function handle_new_user()
returns trigger as $$
begin
  insert into profiles (id, full_name, avatar_url)
  values (
    new.id,
    new.raw_user_meta_data->>'full_name',
    new.raw_user_meta_data->>'avatar_url'
  );
  return new;
end;
$$ language plpgsql security definer;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure handle_new_user();


-- ── CATEGORIES ──────────────────────────────
create table categories (
  id          uuid primary key default uuid_generate_v4(),
  name        text not null unique,
  slug        text not null unique,
  description text,
  icon        text,
  sort_order  integer default 0
);

-- Seed common ostomy product categories
insert into categories (name, slug, icon, sort_order) values
  ('Pouching Systems',   'pouching-systems',   '🩺', 1),
  ('Skin Barriers',      'skin-barriers',      '🛡️', 2),
  ('Pouch Covers',       'pouch-covers',       '🧴', 3),
  ('Adhesive Removers',  'adhesive-removers',  '🧪', 4),
  ('Irrigation',         'irrigation',         '💧', 5),
  ('Belts & Support',    'belts-support',      '🩹', 6),
  ('Deodorants',         'deodorants',         '✨', 7),
  ('Accessories',        'accessories',        '📦', 8);


-- ── LISTINGS ────────────────────────────────
create type listing_condition as enum ('new', 'like_new', 'good', 'fair');
create type listing_status as enum ('active', 'sold', 'paused', 'deleted');
create type listing_type as enum ('retail', 'peer');  -- retail = store, peer = user selling

create table listings (
  id            uuid primary key default uuid_generate_v4(),
  seller_id     uuid not null references profiles(id) on delete cascade,
  category_id   uuid references categories(id),
  title         text not null,
  description   text,
  brand         text,
  model         text,
  condition     listing_condition not null default 'new',
  listing_type  listing_type not null default 'peer',
  price         numeric(10,2) not null check (price > 0),
  quantity      integer not null default 1 check (quantity >= 0),
  images        text[],                -- array of storage URLs
  tags          text[],
  status        listing_status not null default 'active',
  view_count    integer default 0,
  created_at    timestamptz default now(),
  updated_at    timestamptz default now()
);

-- Index for fast searching
create index listings_seller_id_idx on listings(seller_id);
create index listings_category_id_idx on listings(category_id);
create index listings_status_idx on listings(status);
create index listings_price_idx on listings(price);


-- ── ORDERS ──────────────────────────────────
create type order_status as enum (
  'pending',      -- created, awaiting payment
  'paid',         -- payment confirmed
  'shipped',      -- seller has shipped
  'delivered',    -- buyer confirmed delivery
  'cancelled',    -- cancelled before payment
  'refunded'      -- refund issued
);

create table orders (
  id                  uuid primary key default uuid_generate_v4(),
  listing_id          uuid not null references listings(id),
  buyer_id            uuid not null references profiles(id),
  seller_id           uuid not null references profiles(id),
  quantity            integer not null default 1,
  unit_price          numeric(10,2) not null,
  platform_fee        numeric(10,2) not null,   -- Gutsy Care's cut (e.g. 10%)
  stripe_fee          numeric(10,2) not null,   -- Stripe's cut
  seller_payout       numeric(10,2) not null,   -- what seller receives
  total_amount        numeric(10,2) not null,   -- what buyer pays
  status              order_status not null default 'pending',
  stripe_payment_intent_id  text,
  stripe_transfer_id        text,
  shipping_address    jsonb,
  tracking_number     text,
  carrier             text,
  notes               text,
  created_at          timestamptz default now(),
  updated_at          timestamptz default now()
);

create index orders_buyer_id_idx on orders(buyer_id);
create index orders_seller_id_idx on orders(seller_id);
create index orders_status_idx on orders(status);


-- ── REVIEWS ─────────────────────────────────
create type review_type as enum ('buyer_to_seller', 'seller_to_buyer');

create table reviews (
  id          uuid primary key default uuid_generate_v4(),
  order_id    uuid not null references orders(id),
  reviewer_id uuid not null references profiles(id),
  reviewee_id uuid not null references profiles(id),
  review_type review_type not null,
  rating      integer not null check (rating between 1 and 5),
  comment     text,
  created_at  timestamptz default now(),
  unique(order_id, reviewer_id)   -- one review per person per order
);

create index reviews_reviewee_id_idx on reviews(reviewee_id);

-- Auto-update seller rating when review is added
create or replace function update_seller_rating()
returns trigger as $$
begin
  update profiles
  set seller_rating = (
    select round(avg(rating)::numeric, 2)
    from reviews
    where reviewee_id = new.reviewee_id
      and review_type = 'buyer_to_seller'
  )
  where id = new.reviewee_id;
  return new;
end;
$$ language plpgsql security definer;

create trigger on_review_created
  after insert on reviews
  for each row execute procedure update_seller_rating();


-- ── MESSAGES ────────────────────────────────
create table conversations (
  id            uuid primary key default uuid_generate_v4(),
  listing_id    uuid references listings(id),
  buyer_id      uuid not null references profiles(id),
  seller_id     uuid not null references profiles(id),
  last_message  text,
  last_message_at timestamptz,
  created_at    timestamptz default now()
);

create table messages (
  id              uuid primary key default uuid_generate_v4(),
  conversation_id uuid not null references conversations(id) on delete cascade,
  sender_id       uuid not null references profiles(id),
  content         text not null,
  is_read         boolean default false,
  created_at      timestamptz default now()
);

create index messages_conversation_id_idx on messages(conversation_id);
create index conversations_buyer_id_idx on conversations(buyer_id);
create index conversations_seller_id_idx on conversations(seller_id);


-- ── SAVED / WATCHLIST ───────────────────────
create table saved_listings (
  id          uuid primary key default uuid_generate_v4(),
  user_id     uuid not null references profiles(id) on delete cascade,
  listing_id  uuid not null references listings(id) on delete cascade,
  created_at  timestamptz default now(),
  unique(user_id, listing_id)
);


-- ── ROW LEVEL SECURITY (RLS) ─────────────────
-- Enable RLS on all tables
alter table profiles enable row level security;
alter table listings enable row level security;
alter table orders enable row level security;
alter table reviews enable row level security;
alter table conversations enable row level security;
alter table messages enable row level security;
alter table saved_listings enable row level security;

-- PROFILES: public read, own write
create policy "Profiles are public" on profiles for select using (true);
create policy "Users can update own profile" on profiles for update using (auth.uid() = id);

-- LISTINGS: public read, seller write
create policy "Listings are public" on listings for select using (status = 'active');
create policy "Sellers can insert listings" on listings for insert with check (auth.uid() = seller_id);
create policy "Sellers can update own listings" on listings for update using (auth.uid() = seller_id);

-- ORDERS: buyer and seller can see their own
create policy "Buyers can see own orders" on orders for select using (auth.uid() = buyer_id or auth.uid() = seller_id);
create policy "Buyers can create orders" on orders for insert with check (auth.uid() = buyer_id);

-- REVIEWS: public read, reviewer write
create policy "Reviews are public" on reviews for select using (true);
create policy "Users can write reviews" on reviews for insert with check (auth.uid() = reviewer_id);

-- MESSAGES: participants only
create policy "Conversation participants can read messages" on messages
  for select using (
    auth.uid() in (
      select buyer_id from conversations where id = conversation_id
      union
      select seller_id from conversations where id = conversation_id
    )
  );
create policy "Users can send messages" on messages
  for insert with check (auth.uid() = sender_id);

-- SAVED LISTINGS: own only
create policy "Users can manage own saved listings" on saved_listings
  for all using (auth.uid() = user_id);


-- ── UPDATED_AT TRIGGER ───────────────────────
create or replace function set_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

create trigger set_profiles_updated_at before update on profiles for each row execute procedure set_updated_at();
create trigger set_listings_updated_at before update on listings for each row execute procedure set_updated_at();
create trigger set_orders_updated_at before update on orders for each row execute procedure set_updated_at();
