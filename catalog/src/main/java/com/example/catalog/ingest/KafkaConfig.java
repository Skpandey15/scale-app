package com.example.catalog.ingest;

import com.fasterxml.jackson.core.JsonProcessingException;
import jakarta.validation.ConstraintViolationException;
import org.apache.kafka.clients.admin.NewTopic;
import org.apache.kafka.common.TopicPartition;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.kafka.config.TopicBuilder;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.kafka.listener.DeadLetterPublishingRecoverer;
import org.springframework.kafka.listener.DefaultErrorHandler;
import org.springframework.util.backoff.ExponentialBackOff;

@Configuration
public class KafkaConfig {
    public static final String RAW = "metadata-raw";
    public static final String RATE = "ingest-rate-1m";

    private static NewTopic topic(String name, int partitions, int replicas) {
        return TopicBuilder.name(name).partitions(partitions).replicas(replicas)
                .config("min.insync.replicas", String.valueOf(Math.min(2, replicas))).build();
    }

    @Bean NewTopic rawTopic(@Value("${catalog.kafka-replicas}") int r)      { return topic(RAW, 6, r); }
    @Bean NewTopic rawDlt(@Value("${catalog.kafka-replicas}") int r)        { return topic(RAW + ".DLT", 3, r); }
    @Bean NewTopic rateTopic(@Value("${catalog.kafka-replicas}") int r)     { return topic(RATE, 3, r); }
    @Bean NewTopic rateDlt(@Value("${catalog.kafka-replicas}") int r)       { return topic(RATE + ".DLT", 3, r); }

    /**
     * Two kinds of failure, handled differently:
     *  - POISON (unparseable / invalid record): retrying cannot help, so it goes straight to the dead-letter topic.
     *  - INFRASTRUCTURE (Mongo down, timeouts): retried with capped exponential backoff, forever. The consumer simply
     *    stalls on that record (backpressure, offsets uncommitted) and resumes when Mongo returns, so an outage never
     *    pushes good records to the DLT or loses them.
     */
    @Bean
    DefaultErrorHandler kafkaErrorHandler(KafkaTemplate<?, ?> template) {
        var recoverer = new DeadLetterPublishingRecoverer(template,
                (record, ex) -> new TopicPartition(record.topic() + ".DLT", -1));
        ExponentialBackOff backoff = new ExponentialBackOff(500L, 2.0);
        backoff.setMaxInterval(10_000L);
        backoff.setMaxElapsedTime(Long.MAX_VALUE);
        DefaultErrorHandler handler = new DefaultErrorHandler(recoverer, backoff);
        handler.addNotRetryableExceptions(JsonProcessingException.class, IllegalArgumentException.class,
                ConstraintViolationException.class, NumberFormatException.class);
        return handler;
    }
}
