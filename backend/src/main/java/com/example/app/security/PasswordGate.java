package com.example.app.security;

import java.util.concurrent.Semaphore;
import java.util.concurrent.TimeUnit;
import java.util.function.Supplier;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Component;
import org.springframework.web.server.ResponseStatusException;

/**
 * Bulkhead around BCrypt. Hashing is deliberately CPU-heavy (~100 ms); without a cap, a burst of logins can
 * use every core and starve the feed endpoints. At most N hashes run at once per pod; callers wait briefly,
 * then get 503 so the client can retry, while reads keep flowing.
 */
@Component
public class PasswordGate {
    private final PasswordEncoder encoder;
    private final Semaphore permits;

    public PasswordGate(PasswordEncoder encoder, @Value("${app.auth.max-concurrent-hashes:4}") int max) {
        this.encoder = encoder;
        this.permits = new Semaphore(Math.max(1, max), true);
    }

    public String encode(String raw) {
        return guarded(() -> encoder.encode(raw));
    }

    public boolean matches(String raw, String hash) {
        return guarded(() -> encoder.matches(raw, hash));
    }

    private <T> T guarded(Supplier<T> work) {
        boolean acquired = false;
        try {
            acquired = permits.tryAcquire(2, TimeUnit.SECONDS);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
        if (!acquired) {
            throw new ResponseStatusException(HttpStatus.SERVICE_UNAVAILABLE, "auth busy, retry shortly");
        }
        try {
            return work.get();
        } finally {
            permits.release();
        }
    }
}
