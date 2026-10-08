package com.example.app.web;

import com.example.app.RateLimiter;
import com.example.app.domain.Models.User;
import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import com.example.app.domain.Models.UserRepo;
import com.example.app.security.JwtService;
import com.example.app.security.PasswordGate;
import jakarta.validation.Valid;
import org.springframework.beans.factory.annotation.Value;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/auth")
public class AuthController {
    public record Creds(@NotBlank @Size(max = 50) String username, @NotBlank @Size(min = 8, max = 72) String password) {}
    public record Token(String token, String username) {}

    private final int loginAttemptsPerMinute;

    private final UserRepo users;
    private final PasswordGate passwords;
    private final JwtService jwt;
    private final RateLimiter limiter;
    private final Counter rejectedAccount;

    public AuthController(UserRepo users, PasswordGate passwords, JwtService jwt, RateLimiter limiter,
                          MeterRegistry metrics,
                          @Value("${app.rate-limit-login-per-account-per-minute:5}") int loginAttemptsPerMinute) {
        this.loginAttemptsPerMinute = loginAttemptsPerMinute;
        this.users = users;
        this.passwords = passwords;
        this.jwt = jwt;
        this.limiter = limiter;
        this.rejectedAccount = Counter.builder("ratelimit.rejected").tag("scope", "auth_account").register(metrics);
    }

    @PostMapping("/register")
    ResponseEntity<?> register(@Valid @RequestBody Creds c) {
        User u = new User();
        u.username = c.username();
        u.passwordHash = passwords.encode(c.password());
        try {
            users.save(u);
        } catch (DataIntegrityViolationException e) {
            return ResponseEntity.status(HttpStatus.CONFLICT).body("username taken");
        }
        return ResponseEntity.ok(new Token(jwt.issue(u.id, u.username), u.username));
    }

    @PostMapping("/login")
    ResponseEntity<?> login(@Valid @RequestBody Creds c) {
        // Per-account throttle, independent of how reliably we can identify the caller's IP: guessing one
        // account's password is capped at loginAttemptsPerMinute across all replicas and all source addresses.
        if (!limiter.allow("rlu:" + c.username().toLowerCase(), 60, loginAttemptsPerMinute)) {
            rejectedAccount.increment();
            return ResponseEntity.status(HttpStatus.TOO_MANY_REQUESTS).header("Retry-After", "60")
                    .body("too many attempts for this account, retry later");
        }
        return users.findByUsername(c.username())
                .filter(u -> passwords.matches(c.password(), u.passwordHash))
                .<ResponseEntity<?>>map(u -> ResponseEntity.ok(new Token(jwt.issue(u.id, u.username), u.username)))
                .orElseGet(() -> ResponseEntity.status(HttpStatus.UNAUTHORIZED).body("bad credentials"));
    }
}
