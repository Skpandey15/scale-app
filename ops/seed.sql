-- Synthetic data for batch / performance drills. Remove with ops/unseed.sql.
insert into users (username, password_hash)
select 'seed' || g, 'x' from generate_series(1, 20) g
on conflict (username) do nothing;

insert into posts (user_id, content, created_at)
select u.id, 'synthetic post ' || g, now() - (random() * interval '30 days') - interval '1 hour'
from generate_series(1, 300000) g
join users u on u.username = 'seed' || (1 + g % 20);
