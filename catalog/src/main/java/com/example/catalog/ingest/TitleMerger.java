package com.example.catalog.ingest;

import com.example.catalog.model.Model;
import com.example.catalog.model.Model.RawRecord;
import com.example.catalog.model.Model.TitleDoc;
import java.time.Instant;
import java.util.Locale;
import java.util.concurrent.ThreadLocalRandom;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.dao.OptimisticLockingFailureException;
import org.springframework.data.mongodb.core.MongoTemplate;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Service;

/**
 * Entity resolution + merge. Many feeds describe the same title; this folds them into one document.
 * Idempotent: replaying a record that adds nothing new writes nothing (no version bump), so Kafka's
 * at-least-once delivery and DLT replays are safe. Concurrent merges of the same title are resolved by
 * optimistic locking (@Version) with a bounded retry.
 */
@Service
public class TitleMerger {
    public static final String FRESH_PREFIX = "catalog:fresh:";

    private final MongoTemplate mongo;
    private final StringRedisTemplate redis;

    public TitleMerger(MongoTemplate mongo, StringRedisTemplate redis) {
        this.mongo = mongo;
        this.redis = redis;
    }

    public void merge(RawRecord r) {
        String id = Model.canonicalId(r.type(), r.name(), r.year());
        for (int attempt = 1; ; attempt++) {
            try {
                if (upsert(id, r)) evict(id);
                return;
            } catch (OptimisticLockingFailureException | DuplicateKeyException lost) {
                if (attempt >= 6) throw lost;               // give up: the error handler retries the record
                try {
                    Thread.sleep(ThreadLocalRandom.current().nextLong(5, 25) * attempt);   // jittered backoff
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    throw lost;
                }
            }
        }
    }

    /** @return true if the stored document changed */
    private boolean upsert(String id, RawRecord r) {
        TitleDoc t = mongo.findById(id, TitleDoc.class);
        boolean changed = false;
        if (t == null) {
            t = new TitleDoc();
            t.id = id;
            t.type = r.type().toLowerCase(Locale.ROOT);
            t.name = r.name().trim();
            t.year = r.year();
            changed = true;
        }
        if (r.description() != null && !r.description().isBlank()
                && (t.description == null || r.description().length() > t.description.length())) {
            t.description = r.description().trim();        // keep the richest description
            changed = true;
        }
        if (r.genres() != null) {
            for (String g : r.genres()) changed |= t.genres.add(titleCase(g.trim()));
        }
        changed |= t.sources.add(r.source().trim().toLowerCase(Locale.ROOT));
        if (!changed) return false;
        t.confidence = Math.min(100, 50 + 20 * t.sources.size());   // more independent sources agreeing = more trust
        t.updatedAt = Instant.now();
        mongo.save(t);                                      // insert when version == null, otherwise versioned update
        return true;
    }

    private static String titleCase(String g) {
        return g.isEmpty() ? g : g.substring(0, 1).toUpperCase(Locale.ROOT) + g.substring(1).toLowerCase(Locale.ROOT);
    }

    private void evict(String id) {
        try {
            redis.delete(FRESH_PREFIX + id);                 // the stale copy stays: it is the outage fallback
        } catch (RuntimeException ignored) {
            // cache is best-effort; the TTL bounds staleness
        }
    }
}
