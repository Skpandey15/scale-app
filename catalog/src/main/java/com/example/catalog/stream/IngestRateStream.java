package com.example.catalog.stream;

import com.example.catalog.ingest.KafkaConfig;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Duration;
import org.apache.kafka.common.serialization.Serdes;
import org.apache.kafka.streams.KeyValue;
import org.apache.kafka.streams.StreamsBuilder;
import org.apache.kafka.streams.errors.StreamsUncaughtExceptionHandler;
import org.apache.kafka.streams.kstream.Consumed;
import org.apache.kafka.streams.kstream.Grouped;
import org.apache.kafka.streams.kstream.KStream;
import org.apache.kafka.streams.kstream.Materialized;
import org.apache.kafka.streams.kstream.Produced;
import org.apache.kafka.streams.kstream.TimeWindows;
import org.apache.kafka.streams.state.Stores;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.kafka.annotation.EnableKafkaStreams;
import org.springframework.kafka.config.StreamsBuilderFactoryBeanConfigurer;

/**
 * Stream processing: counts ingested records per source in 1-minute tumbling windows (10 s grace for late events)
 * straight off the raw topic. The store is in-memory (small, rebuilt from the topic after a restart) and the result is
 * published to ingest-rate-1m, which IngestRateSink persists for the stats endpoint.
 */
@Configuration
@EnableKafkaStreams
public class IngestRateStream {

    @Bean
    KStream<String, String> ingestRate(StreamsBuilder builder, ObjectMapper json) {
        KStream<String, String> raw = builder.stream(KafkaConfig.RAW, Consumed.with(Serdes.String(), Serdes.String()));
        KStream<String, String> perSource = raw
                .map((key, value) -> KeyValue.pair(sourceOf(json, value), "1"))
                .filter((source, one) -> source != null);                    // unparseable records are the DLT's problem

        perSource
                .groupByKey(Grouped.with(Serdes.String(), Serdes.String()))
                .windowedBy(TimeWindows.ofSizeAndGrace(Duration.ofMinutes(1), Duration.ofSeconds(10)))
                .count(Materialized.<String, Long>as(
                                Stores.inMemoryWindowStore("ingest-rate-store", Duration.ofHours(1), Duration.ofMinutes(1), false))
                        .withKeySerde(Serdes.String()).withValueSerde(Serdes.Long()))
                .toStream()
                .map((window, count) -> KeyValue.pair(window.key() + "@" + window.window().start(), String.valueOf(count)))
                .to(KafkaConfig.RATE, Produced.with(Serdes.String(), Serdes.String()));
        return raw;
    }

    private static String sourceOf(ObjectMapper json, String value) {
        try {
            String s = json.readTree(value).path("source").asText(null);
            return s == null || s.isBlank() ? null : s.trim().toLowerCase();
        } catch (Exception e) {
            return null;
        }
    }

    /** A bug in one record must not kill the topology: replace the failed stream thread instead of stopping. */
    @Bean
    StreamsBuilderFactoryBeanConfigurer replaceFailedThreads() {
        return factory -> factory.setStreamsUncaughtExceptionHandler(
                e -> StreamsUncaughtExceptionHandler.StreamThreadExceptionResponse.REPLACE_THREAD);
    }
}
