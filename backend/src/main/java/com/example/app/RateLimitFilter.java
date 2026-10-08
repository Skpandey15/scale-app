package com.example.app;

import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

/**
 * Per-client limiter (shared across replicas via Redis, sliding window): a global per-second limit, plus a
 * stricter per-minute limit on login/register. Per-ACCOUNT login limiting lives in AuthController, because the
 * client address is only as reliable as the network path in front of the app.
 *
 * Client identity: the LAST X-Forwarded-For entry, i.e. the address the trusted ingress saw. Earlier entries
 * are client-supplied and ignored, so a caller cannot dodge the limit by sending a fake header. Behind a cloud
 * load balancer this is the real client; in the local k3d setup the ingress path rewrites it to rotating
 * internal hop addresses, which makes per-IP limits approximate there.
 */
@Component
public class RateLimitFilter extends OncePerRequestFilter {
    private final RateLimiter limiter;
    private final int limitPerSecond;
    private final int authLimitPerMinute;
    private final Counter rejectedGlobal;
    private final Counter rejectedAuth;

    public RateLimitFilter(RateLimiter limiter,
                           @Value("${app.rate-limit-per-second}") int limitPerSecond,
                           @Value("${app.rate-limit-auth-per-minute:10}") int authLimitPerMinute,
                           MeterRegistry metrics) {
        this.limiter = limiter;
        this.limitPerSecond = limitPerSecond;
        this.authLimitPerMinute = authLimitPerMinute;
        this.rejectedGlobal = Counter.builder("ratelimit.rejected").tag("scope", "global").register(metrics);
        this.rejectedAuth = Counter.builder("ratelimit.rejected").tag("scope", "auth_ip").register(metrics);
    }

    @Override
    protected boolean shouldNotFilter(HttpServletRequest req) {
        return req.getRequestURI().startsWith("/actuator");
    }

    @Override
    protected void doFilterInternal(HttpServletRequest req, HttpServletResponse res, FilterChain chain)
            throws ServletException, IOException {
        String client = clientAddress(req);
        if ("POST".equals(req.getMethod()) && req.getRequestURI().startsWith("/api/auth/")
                && !limiter.allow("rla:" + client, 60, authLimitPerMinute)) {
            rejectedAuth.increment();
            reject(res, 60);
            return;
        }
        if (!limiter.allow("rl:" + client, 1, limitPerSecond)) {
            rejectedGlobal.increment();
            reject(res, 1);
            return;
        }
        chain.doFilter(req, res);
    }

    private static void reject(HttpServletResponse res, int retryAfterSeconds) {
        res.setStatus(429);
        res.setHeader("Retry-After", String.valueOf(retryAfterSeconds));
    }

    static String clientAddress(HttpServletRequest req) {
        String fwd = req.getHeader("X-Forwarded-For");
        if (fwd == null || fwd.isBlank()) return req.getRemoteAddr();
        String[] parts = fwd.split(",");
        return parts[parts.length - 1].trim();
    }
}
