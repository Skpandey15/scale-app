package com.example.app.events;

import com.example.app.domain.PostDto;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Duration;
import java.util.List;
import java.util.stream.IntStream;
import org.apache.kafka.clients.admin.NewTopic;
import org.apache.kafka.common.TopicPartition;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.kafka.config.TopicBuilder;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.kafka.listener.DeadLetterPublishingRecoverer;
import org.springframework.kafka.listener.DefaultErrorHandler;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.util.backoff.FixedBackOff;

/**
 * Events come from the transactional outbox (see OutboxRelay). One consumer per group invalidates the
 * shared Redis feed cache. Failures are retried, then parked on post-created.DLT instead of blocking the
 * partition forever. Topics are replicated (RF 3, min ISR 2) so one broker can fail without losing events.
 */
@Configuration
public class PostEvents {
    public static final String TOPIC = "post-created";

    @Bean
    NewTopic postCreatedTopic(@Value("${app.kafka.replicas:3}") int replicas) {
        return TopicBuilder.name(TOPIC).partitions(6).replicas(replicas)
                .config("min.insync.replicas", String.valueOf(Math.min(2, replicas))).build();
    }

    @Bean
    NewTopic postCreatedDlt(@Value("${app.kafka.replicas:3}") int replicas) {
        return TopicBuilder.name(TOPIC + ".DLT").partitions(3).replicas(replicas)
                .config("min.insync.replicas", String.valueOf(Math.min(2, replicas))).build();
    }

    /** 3 retries, 1s apart, then dead-letter. Spring Boot wires this into every @KafkaListener. */
    @Bean
    DefaultErrorHandler kafkaErrorHandler(KafkaTemplate<?, ?> template) {
        var recoverer = new DeadLetterPublishingRecoverer(template,
                (record, ex) -> new TopicPartition(record.topic() + ".DLT", -1));
        return new DefaultErrorHandler(recoverer, new FixedBackOff(1000L, 3L));
    }

    @Bean
    FeedCacheInvalidator feedCacheInvalidator(StringRedisTemplate redis, ObjectMapper json) {
        return new FeedCacheInvalidator(redis, json);
    }

    public static class FeedCacheInvalidator {
        private static final List<String> KEYS =
                IntStream.rangeClosed(1, 50).mapToObj(n -> "feed:first:" + n).toList();

        private final StringRedisTemplate redis;
        private final ObjectMapper json;

        FeedCacheInvalidator(StringRedisTemplate redis, ObjectMapper json) {
            this.redis = redis;
            this.json = json;
        }

        /**
         * Debounced invalidation. Clearing the hot page on every post made the hit rate collapse under heavy
         * writes (one miss per post). Now: the first event in a 1s window clears immediately (leading edge);
         * later events only raise a "pending" flag that flushSoon() turns into one more clear (trailing edge).
         * Staleness stays ~1s after the last write instead of one DB query per write.
         * Idempotent, so at-least-once delivery is fine.
         */
        @KafkaListener(topics = TOPIC, groupId = "feed-cache-invalidator")
        public void onPostCreated(String payload) throws JsonProcessingException {
            json.readValue(payload, PostDto.class); // malformed event -> exception -> retries -> DLT
            try {
                Boolean leading = redis.opsForValue().setIfAbsent("feed:inval:gate", "1", Duration.ofMillis(1000));
                if (Boolean.TRUE.equals(leading)) {
                    redis.delete(KEYS);
                } else {
                    redis.opsForValue().set("feed:inval:pending", "1", Duration.ofSeconds(5));
                }
            } catch (RuntimeException ignored) {
                // cache is best-effort; the 5s TTL still bounds staleness
            }
        }

        @Scheduled(fixedDelay = 1000)
        public void flushSoon() {
            try {
                if (Boolean.TRUE.equals(redis.delete("feed:inval:pending"))) {
                    redis.delete(KEYS);
                }
            } catch (RuntimeException ignored) {
            }
        }
    }
}
