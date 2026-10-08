-- Transactional outbox: events are written in the same DB transaction as the business change,
-- then relayed to Kafka. A crash or Kafka outage can delay an event but never lose it.
create table outbox (
  id         bigserial primary key,
  topic      varchar(100) not null,
  msg_key    varchar(200),
  payload    text         not null,
  created_at timestamptz  not null default now(),
  sent_at    timestamptz
);
create index idx_outbox_pending on outbox (id) where sent_at is null;

-- Batch job output + checkpoint (restartable, idempotent chunked processing).
create table daily_post_stats (
  day       date   not null,
  author_id bigint not null,
  posts     bigint not null,
  primary key (day, author_id)
);

create table batch_checkpoint (
  job        varchar(100) primary key,
  last_id    bigint       not null,
  updated_at timestamptz  not null default now()
);
