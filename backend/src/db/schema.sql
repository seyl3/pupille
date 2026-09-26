-- Schema from docs/ARCHITECTURE.md §12, applied verbatim.
create extension if not exists citext;

create table if not exists profiles (
  id          bytea primary key,                 -- 16-byte profileId
  nullifier   numeric(78,0) unique not null,      -- uniqueness proof (pupille-profile-v1); never leaves the server
  session_id  text unique,                        -- populated when World sessions are available
  sybil_score int,                                -- Selfie Check risk signal (stored, not shown)
  handle      citext unique not null check (handle ~ '^[a-z0-9_]{3,20}$'),
  credential  text not null,
  app_attest_key_id text,
  created_at  timestamptz not null default now()
);
alter table profiles alter column session_id drop not null;
alter table profiles add column if not exists app_attest_key_id text;
alter table profiles add column if not exists avatar_image bytea;
alter table profiles add column if not exists avatar_content_type text;
alter table profiles add column if not exists avatar_updated_at timestamptz;

create table if not exists profile_avatar_challenges (
  id text primary key,
  profile_id bytea not null references profiles(id),
  challenge bytea not null,
  expires_at timestamptz not null,
  used boolean not null default false
);

create table if not exists profile_keys (
  profile_id   bytea not null references profiles(id),
  key_version  int not null,
  public_key   bytea unique not null,             -- 65-byte X9.63
  status       text not null default 'active',    -- active | retired
  cert         bytea not null, cert_sig bytea not null,
  activated_at timestamptz not null default now(), retired_at timestamptz,
  primary key (profile_id, key_version)
);
create unique index if not exists one_active_key on profile_keys(profile_id) where status = 'active';

create table if not exists profile_sessions (   -- handle reservation + pending proof
  id text primary key, profile_id bytea not null, public_key bytea not null,
  handle citext not null, app_attest_key_id text not null,
  world_nonce text,
  device_verified boolean not null default false,
  device_counter bigint,
  expires_at timestamptz not null, used boolean not null default false
);
alter table profile_sessions add column if not exists world_nonce text;
alter table profile_sessions add column if not exists device_verified boolean not null default false;
alter table profile_sessions add column if not exists device_counter bigint;

create table if not exists world_session_nullifiers (  -- per-proof replay protection
  nullifier numeric(78,0) not null, action text not null,
  used_at timestamptz not null default now(), primary key (nullifier, action)
);

create table if not exists app_attest_keys (
  key_id text primary key, public_key bytea not null, receipt bytea,
  counter bigint not null default 0, created_at timestamptz not null default now()
);

create table if not exists capture_challenges (
  id text primary key, challenge bytea not null,
  profile_id bytea not null, key_version int not null, app_attest_key_id text not null,
  image_sha256 bytea, depth_sha256 bytea, assertion_sha256 bytea,
  commitment bytea, post_signature bytea, world_proof jsonb,
  -- Not in the architecture doc's schema table verbatim, but required to make POST
  -- /v1/captures/:id/human able to persist `posts.image`/`posts.depth` without asking the
  -- client to resend bytes it already uploaded to /device. Holds the exact bytes uploaded
  -- to /device, moved into `posts` once /human succeeds.
  pending_image bytea, pending_depth bytea,
  status text not null default 'issued',           -- issued | device_ok | used | expired
  issued_at timestamptz not null default now(), expires_at timestamptz not null
);

create table if not exists posts (
  id text primary key,
  profile_id bytea not null, key_version int not null,
  challenge_id text unique not null references capture_challenges(id),
  image bytea not null, content_type text not null, depth bytea, caption text,
  post_signature bytea not null, capture_cert bytea not null, capture_cert_sig bytea not null,
  created_at timestamptz not null default now(),
  foreign key (profile_id, key_version) references profile_keys(profile_id, key_version)
);

create table if not exists post_reactions (
  post_id text not null references posts(id) on delete cascade,
  profile_id bytea not null references profiles(id) on delete cascade,
  reaction text not null check (reaction in ('nerd', 'heart', 'aubergine', 'japan')),
  updated_at timestamptz not null default now(),
  primary key (post_id, profile_id)
);

create table if not exists reaction_challenges (
  id text primary key,
  post_id text not null references posts(id) on delete cascade,
  profile_id bytea not null references profiles(id) on delete cascade,
  challenge bytea not null,
  expires_at timestamptz not null,
  used boolean not null default false
);
