delete from posts where user_id in (select id from users where username like 'seed%');
delete from users where username like 'seed%';
truncate daily_post_stats;
delete from batch_checkpoint;
