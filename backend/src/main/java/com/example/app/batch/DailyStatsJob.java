package com.example.app.batch;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.ApplicationContext;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

/**
 * Batch path: rolls posts up into daily_post_stats. Runs as a Kubernetes CronJob using the same image
 * (--app.batch.job=daily-stats), then exits.
 *
 * Design: id-range chunks; each chunk's aggregate AND the checkpoint commit in ONE transaction, so a crash
 * at any point leaves the data consistent and a re-run resumes from the checkpoint (effectively exactly-once).
 * Only rows older than 1 minute are processed, so late-committing transactions with lower ids are not skipped.
 */
@Component
@ConditionalOnProperty(name = "app.batch.job", havingValue = "daily-stats")
public class DailyStatsJob implements ApplicationRunner {
    private static final Logger log = LoggerFactory.getLogger(DailyStatsJob.class);
    private static final String JOB = "daily-stats";
    private static final long CHUNK = 10_000;

    private final JdbcTemplate jdbc;
    private final TransactionTemplate tx;
    private final ApplicationContext ctx;
    private final int failOnceAfterChunks;

    public DailyStatsJob(JdbcTemplate jdbc, PlatformTransactionManager tm, ApplicationContext ctx,
                         @Value("${app.batch.fail-once-after-chunks:0}") int failOnceAfterChunks) {
        this.jdbc = jdbc;
        this.tx = new TransactionTemplate(tm);
        this.ctx = ctx;
        this.failOnceAfterChunks = failOnceAfterChunks;
    }

    @Override
    public void run(ApplicationArguments args) {
        int code = 0;
        try {
            execute();
        } catch (Exception e) {
            log.error("daily-stats FAILED: {}", e.toString());
            code = 1;
        }
        int exit = code;
        System.exit(SpringApplication.exit(ctx, () -> exit));
    }

    private void execute() {
        long start = jdbc.query("select last_id from batch_checkpoint where job = ?",
                (rs, i) -> rs.getLong(1), JOB).stream().findFirst().orElse(0L);
        Long max = jdbc.queryForObject(
                "select coalesce(max(id), 0) from posts where created_at < now() - interval '1 minute'", Long.class);
        long upTo = max == null ? 0 : max;
        log.info("daily-stats start: checkpoint={} target={}", start, upTo);

        long last = start;
        int chunks = 0;
        long t0 = System.currentTimeMillis();
        while (last < upTo) {
            long from = last;
            long to = Math.min(from + CHUNK, upTo);
            tx.executeWithoutResult(s -> {
                jdbc.update("""
                        insert into daily_post_stats (day, author_id, posts)
                        select (created_at at time zone 'UTC')::date, user_id, count(*)
                        from posts where id > ? and id <= ? group by 1, 2
                        on conflict (day, author_id) do update set posts = daily_post_stats.posts + excluded.posts
                        """, from, to);
                jdbc.update("""
                        insert into batch_checkpoint (job, last_id, updated_at) values (?, ?, now())
                        on conflict (job) do update set last_id = excluded.last_id, updated_at = now()
                        """, JOB, to);
            });
            last = to;
            chunks++;
            if (chunks % 5 == 0) log.info("daily-stats progress: checkpoint={}/{}", last, upTo);
            // Failure injection for the restart drill: only on a fresh run (checkpoint 0), so the retry succeeds.
            if (failOnceAfterChunks > 0 && start == 0 && chunks == failOnceAfterChunks) {
                throw new IllegalStateException("injected failure after " + chunks + " chunks (checkpoint=" + last + ")");
            }
        }
        log.info("daily-stats DONE: {} chunks, checkpoint={}, {} ms", chunks, last, System.currentTimeMillis() - t0);
    }
}
