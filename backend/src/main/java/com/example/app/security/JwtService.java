package com.example.app.security;

import io.jsonwebtoken.Jwts;
import io.jsonwebtoken.security.Keys;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.Date;
import javax.crypto.SecretKey;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

/** Stateless auth: any node can verify a token, so no sticky sessions or session store. */
@Service
public class JwtService {
    private final SecretKey key;
    private final Duration ttl;

    public JwtService(@Value("${app.jwt-secret}") String secret, @Value("${app.jwt-ttl-minutes}") long ttlMinutes) {
        this.key = Keys.hmacShaKeyFor(secret.getBytes(StandardCharsets.UTF_8));
        this.ttl = Duration.ofMinutes(ttlMinutes);
    }

    public String issue(long userId, String username) {
        long now = System.currentTimeMillis();
        return Jwts.builder().subject(username).claim("uid", userId)
                .issuedAt(new Date(now)).expiration(new Date(now + ttl.toMillis()))
                .signWith(key).compact();
    }

    /** Returns the username, or null if the token is invalid/expired. */
    public String verify(String token) {
        try {
            return Jwts.parser().verifyWith(key).build().parseSignedClaims(token).getPayload().getSubject();
        } catch (Exception e) {
            return null;
        }
    }
}
