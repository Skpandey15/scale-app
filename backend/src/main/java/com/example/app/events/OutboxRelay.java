package com.example.app.events;

import io.micrometer.core.instrument.Gauge;
import io.micrometer.core.instrument.MeterRegistry;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.kafka.support.SendResult;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

/**
 * Relays committed outbox rows to Kafka. Every replica runs it; FOR UPDATE SKIP LOCKED lets them share
 * the work without double-sending. Delivery is at-least-once (a crash between send and commit re-sends),
 * so consumers must be idempotent.
 */
@Component
@ConditionalOnProperty(name = "app.outbox.relay.enabled", havingValue = "true", matchIfMissing = true)
public class OutboxRelay {
    private static final Logger log = LoggerFactory.getLogger(OutboxRelay.class);

    private final JdbcTemplate jdbc;
    private final KafkaTemplate<String, String> kafka;
    private final TransactionTemplate tx;

    public OutboxRelay(JdbcTemplate jdbc, KafkaTemplate<String, String> kafka, PlatformTransactionManager tm,
                       MeterRegistry metrics) {
        this.jdbc = jdbc;
        this.kafka = kafka;
        this.tx = new TransactionTemplate(tm);
        // Backlog is the key health signal: it grows during a Kafka outage and drains afterwards.
        Gauge.builder("outbox.pending", () -> (Number) jdbc.queryForObject(
                "select count(*) from outbox where sent_at is null", Long.class)).register(metrics);
    }

    @Scheduled(fixedDelayString = "${app.outbox.poll-ms:500}")
    public void relay() {
        try {
            tx.executeWithoutResult(status -> drain());
        } catch (RuntimeException e) {
            log.warn("outbox relay tick failed: {}", e.toString());
        }
    }

    private void drain() {
        List<Map<String, Object>> rows = jdbc.queryForList(
                "select id, topic, msg_key, payload from outbox where sent_at is null "
                        + "order by id limit 200 for update skip locked");
        if (rows.isEmpty()) return;

        List<CompletableFuture<SendResult<String, String>>> sends = new ArrayList<>();
        for (Map<String, Object> r : rows) {
            try {
                sends.add(kafka.send((String) r.get("topic"), (String) r.get("msg_key"), (String) r.get("payload")));
            } catch (RuntimeException e) {
                break;
            }
        }
        int sent = 0;
        for (int i = 0; i < sends.size(); i++) {
            try {
                sends.get(i).get(5, TimeUnit.SECONDS);
            } catch (Exception e) {
                log.warn("kafka unavailable, {} outbox rows stay pending: {}", rows.size() - sent, e.toString());
                break; // keep order: everything after the first failure waits for the next tick
            }
            jdbc.update("update outbox set sent_at = now() where id = ?", rows.get(i).get("id"));
            sent++;
        }
    }

    @Scheduled(fixedDelay = 60_000)
    public void cleanup() {
        try {
            jdbc.update("delete from outbox where sent_at < now() - interval '1 day'");
        } catch (RuntimeException ignored) {
        }
    }
}
