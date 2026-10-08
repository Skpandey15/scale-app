package com.example.app;

import java.time.Duration;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Component;

/**
 * Sliding-window counter in Redis, shared by every replica: estimate = current window count +
 * previous window count weighted by how much of it still overlaps. Removes the 2x burst a plain fixed window
 * allows at a boundary. Fails open (allows) if Redis is unavailable.
 */
@Component
public class RateLimiter {
    private final StringRedisTemplate redis;

    public RateLimiter(StringRedisTemplate redis) {
        this.redis = redis;
    }

    public boolean allow(String key, int windowSeconds, int limit) {
        try {
            long windowMs = windowSeconds * 1000L;
            long now = System.currentTimeMillis();
            long bucket = now / windowMs;
            double elapsed = (now % windowMs) / (double) windowMs;
            String current = key + ":" + bucket;
            Long c = redis.opsForValue().increment(current);
            if (c == null) return true;
            if (c == 1) redis.expire(current, Duration.ofSeconds(windowSeconds * 2L));
            String prev = redis.opsForValue().get(key + ":" + (bucket - 1));
            double previous = prev == null ? 0 : Double.parseDouble(prev);
            return c + previous * (1 - elapsed) <= limit;
        } catch (Exception e) {
            return true;
        }
    }
}
