package com.example.catalog.ingest;

import com.example.catalog.model.Model.RawRecord;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.validation.ConstraintViolation;
import jakarta.validation.Validator;
import java.util.Set;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.stereotype.Component;

/** Consumes raw feed records, validates them, and folds them into the curated Mongo collection. */
@Component
public class MetadataNormalizer {
    private final ObjectMapper json;
    private final Validator validator;
    private final TitleMerger merger;

    public MetadataNormalizer(ObjectMapper json, Validator validator, TitleMerger merger) {
        this.json = json;
        this.validator = validator;
        this.merger = merger;
    }

    @KafkaListener(topics = KafkaConfig.RAW, groupId = "catalog-normalizer")
    public void onRecord(String payload) throws JsonProcessingException {
        RawRecord r = json.readValue(payload, RawRecord.class);            // unparseable -> DLT (non-retryable)
        Set<ConstraintViolation<RawRecord>> violations = validator.validate(r);
        if (!violations.isEmpty()) {
            throw new IllegalArgumentException("invalid record: " + violations.iterator().next().getMessage());
        }
        merger.merge(r);                                                   // Mongo trouble -> retried until it recovers
    }
}
