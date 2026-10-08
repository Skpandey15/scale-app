package com.example.catalog.query;

import com.example.catalog.ingest.TitleMerger;
import com.example.catalog.model.Model.TitlePage;
import com.example.catalog.model.Model.TitleDoc;
import com.example.catalog.model.Model.TitleView;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.github.resilience4j.circuitbreaker.CallNotPermittedException;
import io.github.resilience4j.circuitbreaker.CircuitBreaker;
import io.github.resilience4j.circuitbreaker.CircuitBreakerRegistry;
import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import java.time.Duration;
import java.util.List;
import java.util.Optional;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.dao.DataAccessException;
import org.springframework.data.domain.Sort;
import org.springframework.data.mongodb.core.MongoTemplate;
import org.springframework.data.mongodb.core.query.Criteria;
import org.springframework.data.mongodb.core.query.TextCriteria;
import org.springframework.data.mongodb.core.query.TextQuery;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.web.server.ResponseStatusException;

/**
 * Read path: cache-aside in Redis behind a circuit breaker around Mongo.
 *  - fresh cache hit      -> no database call
 *  - miss                 -> Mongo (through the breaker), then refresh both caches
 *  - Mongo failing / breaker open -> serve the STALE copy if we have one (flagged stale=true), otherwise 503 fast
 * A dead dependency therefore degrades the service instead of making every request wait for a timeout.
 */
@Service
public class TitleQueryService {
    private static final String STALE_PREFIX = "catalog:stale:";
    private static final Duration STALE_TTL = Duration.ofDays(1);

    private final MongoTemplate mongo;
    private final StringRedisTemplate redis;
    private final ObjectMapper json;
    private final CircuitBreaker breaker;
    private final Duration freshTtl;
    private final Counter servedStale;
    private final Counter rejected;

    public TitleQueryService(MongoTemplate mongo, StringRedisTemplate redis, ObjectMapper json,
                             CircuitBreakerRegistry breakers, MeterRegistry metrics,
                             @Value("${catalog.cache-ttl-seconds}") long ttlSeconds) {
        this.mongo = mongo;
        this.redis = redis;
        this.json = json;
        this.breaker = breakers.circuitBreaker("mongo");
        this.freshTtl = Duration.ofSeconds(ttlSeconds);
        this.servedStale = Counter.builder("catalog.stale.served").register(metrics);
        this.rejected = Counter.builder("catalog.unavailable").register(metrics);
    }

    public Optional<TitleView> get(String id) {
        String fresh = cacheGet(TitleMerger.FRESH_PREFIX + id);
        if (fresh != null) return Optional.of(parse(fresh));
        try {
            TitleDoc d = breaker.executeSupplier(() -> mongo.findById(id, TitleDoc.class));
            if (d == null) return Optional.empty();
            TitleView v = TitleView.from(d);
            String body = write(v);
            cachePut(TitleMerger.FRESH_PREFIX + id, body, freshTtl);
            cachePut(STALE_PREFIX + id, body, STALE_TTL);
            return Optional.of(v);
        } catch (CallNotPermittedException | DataAccessException e) {
            String stale = cacheGet(STALE_PREFIX + id);
            if (stale != null) {
                servedStale.increment();
                return Optional.of(parse(stale).asStale());
            }
            throw unavailable();
        }
    }

    public TitlePage search(String q, int first, String after) {
        int n = Math.min(Math.max(first, 1), 50);                      // never let a client ask for an unbounded page
        try {
            List<TitleDoc> docs = breaker.executeSupplier(() -> {
                TextQuery query = TextQuery.queryText(TextCriteria.forDefaultLanguage().matching(q));
                if (after != null && !after.isBlank()) query.addCriteria(Criteria.where("_id").gt(after));
                query.with(Sort.by("_id")).limit(n + 1);
                return mongo.find(query, TitleDoc.class);
            });
            boolean more = docs.size() > n;
            List<TitleView> items = docs.stream().limit(n).map(TitleView::from).toList();
            return new TitlePage(items, more ? items.get(items.size() - 1).id() : null);
        } catch (CallNotPermittedException | DataAccessException e) {
            throw unavailable();                                        // no useful stale answer for a search
        }
    }

    private ResponseStatusException unavailable() {
        rejected.increment();
        return new ResponseStatusException(HttpStatus.SERVICE_UNAVAILABLE, "catalog temporarily unavailable");
    }

    private String cacheGet(String key) {
        try {
            return redis.opsForValue().get(key);
        } catch (RuntimeException e) {
            return null;                                                // Redis down: fall through to Mongo
        }
    }

    private void cachePut(String key, String value, Duration ttl) {
        try {
            redis.opsForValue().set(key, value, ttl);
        } catch (RuntimeException ignored) {
        }
    }

    private String write(TitleView v) {
        try {
            return json.writeValueAsString(v);
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }

    private TitleView parse(String s) {
        try {
            return json.readValue(s, TitleView.class);
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }
}
