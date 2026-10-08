package com.example.catalog.web;

import com.example.catalog.ingest.KafkaConfig;
import com.example.catalog.model.Model;
import com.example.catalog.model.Model.IngestRate;
import com.example.catalog.model.Model.IngestStat;
import com.example.catalog.model.Model.RawRecord;
import com.example.catalog.model.Model.TitlePage;
import com.example.catalog.model.Model.TitleView;
import com.example.catalog.query.TitleQueryService;
import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.List;
import java.util.Map;
import java.util.concurrent.TimeUnit;
import org.springframework.data.domain.Sort;
import org.springframework.data.mongodb.core.MongoTemplate;
import org.springframework.data.mongodb.core.query.Criteria;
import org.springframework.data.mongodb.core.query.Query;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.validation.annotation.Validated;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.server.ResponseStatusException;

public final class Controllers {
    private Controllers() {}

    /** Public, read-only. */
    @RestController
    @RequestMapping("/api")
    @Validated
    public static class Read {
        private final TitleQueryService titles;
        private final MongoTemplate mongo;

        public Read(TitleQueryService titles, MongoTemplate mongo) {
            this.titles = titles;
            this.mongo = mongo;
        }

        @GetMapping("/titles/{id}")
        public TitleView one(@PathVariable String id) {
            return titles.get(id).orElseThrow(() -> new ResponseStatusException(HttpStatus.NOT_FOUND, "no such title"));
        }

        @GetMapping("/titles")
        public TitlePage search(@RequestParam @NotBlank @Size(max = 100) String q,
                                @RequestParam(defaultValue = "20") int first,
                                @RequestParam(required = false) String after) {
            return titles.search(q, first, after);
        }

        /** Per-source ingest counts per minute, produced by the Kafka Streams job. */
        @GetMapping("/stats/ingest-rate")
        public List<IngestRate> ingestRate(@RequestParam(defaultValue = "15") int minutes) {
            int m = Math.min(Math.max(minutes, 1), 240);
            Query q = Query.query(Criteria.where("windowStart").gte(Instant.now().minus(m, ChronoUnit.MINUTES)))
                    .with(Sort.by(Sort.Direction.DESC, "windowStart")).limit(500);
            return mongo.find(q, IngestStat.class).stream()
                    .map(s -> new IngestRate(s.source, s.windowStart, s.count)).toList();
        }
    }

    /** Write entry point for feeds. Requires X-API-Key. Returns only after Kafka acknowledged (acks=all), else 503. */
    @RestController
    @RequestMapping("/api/ingest")
    @Validated
    public static class Ingest {
        private final KafkaTemplate<String, String> kafka;
        private final ObjectMapper json;

        public Ingest(KafkaTemplate<String, String> kafka, ObjectMapper json) {
            this.kafka = kafka;
            this.json = json;
        }

        @PostMapping
        public ResponseEntity<Map<String, Object>> one(@Valid @RequestBody RawRecord r) {
            publish(r);
            return ResponseEntity.accepted().body(Map.of("accepted", 1, "id", id(r)));
        }

        @PostMapping("/batch")
        public ResponseEntity<Map<String, Object>> batch(@RequestBody @Size(min = 1, max = 100) List<@Valid RawRecord> records) {
            records.forEach(this::publish);
            return ResponseEntity.accepted().body(Map.of("accepted", records.size()));
        }

        private static String id(RawRecord r) {
            return Model.canonicalId(r.type(), r.name(), r.year());
        }

        private void publish(RawRecord r) {
            try {
                // keyed by canonical id: all feeds about one title land on one partition, in order
                kafka.send(KafkaConfig.RAW, id(r), json.writeValueAsString(r)).get(3, TimeUnit.SECONDS);
            } catch (Exception e) {
                throw new ResponseStatusException(HttpStatus.SERVICE_UNAVAILABLE, "ingest temporarily unavailable, retry");
            }
        }
    }
}
