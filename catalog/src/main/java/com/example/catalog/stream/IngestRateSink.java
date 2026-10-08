package com.example.catalog.stream;

import com.example.catalog.ingest.KafkaConfig;
import com.example.catalog.model.Model.IngestStat;
import java.time.Instant;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.springframework.data.mongodb.core.MongoTemplate;
import org.springframework.data.mongodb.core.query.Criteria;
import org.springframework.data.mongodb.core.query.Query;
import org.springframework.data.mongodb.core.query.Update;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.stereotype.Component;

/** Persists the windowed counts. Streams emits the running total for a window, so this is "set", which is idempotent. */
@Component
public class IngestRateSink {
    private final MongoTemplate mongo;

    public IngestRateSink(MongoTemplate mongo) {
        this.mongo = mongo;
    }

    @KafkaListener(topics = KafkaConfig.RATE, groupId = "catalog-rate-sink")
    public void onRate(ConsumerRecord<String, String> record) {
        String key = record.key();                                   // "<source>@<windowStartMillis>"
        int at = key.lastIndexOf('@');
        String source = key.substring(0, at);
        long windowStart = Long.parseLong(key.substring(at + 1));
        mongo.upsert(Query.query(Criteria.where("_id").is(key)),
                new Update().set("source", source)
                        .set("windowStart", Instant.ofEpochMilli(windowStart))
                        .set("count", Long.parseLong(record.value())),
                IngestStat.class);
    }
}
