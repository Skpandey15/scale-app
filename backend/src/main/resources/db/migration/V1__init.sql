create table users (
  id            bigserial primary key,
  username      varchar(50)  not null unique,
  password_hash varchar(100) not null
);

create table posts (
  id         bigserial primary key,
  user_id    bigint       not null references users(id),
  content    varchar(500) not null,
  created_at timestamptz  not null default now()
);

-- Keyset pagination reads the PK backwards; this serves per-user timelines.
create index idx_posts_user_id_id on posts (user_id, id desc);
