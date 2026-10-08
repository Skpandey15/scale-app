package com.example.catalog.web;

import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import jakarta.validation.ConstraintViolationException;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Map;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.http.converter.HttpMessageNotReadableException;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.servlet.HandlerInterceptor;
import org.springframework.web.servlet.config.annotation.InterceptorRegistry;
import org.springframework.web.servlet.config.annotation.WebMvcConfigurer;

@Configuration
public class WebConfig implements WebMvcConfigurer {
    private final byte[] apiKey;

    public WebConfig(@Value("${catalog.api-key}") String apiKey) {
        this.apiKey = apiKey.getBytes(StandardCharsets.UTF_8);
    }

    @Override
    public void addInterceptors(InterceptorRegistry registry) {
        registry.addInterceptor(new HandlerInterceptor() {
            @Override
            public boolean preHandle(HttpServletRequest req, HttpServletResponse res, Object handler) {
                String given = req.getHeader("X-API-Key");
                // constant-time comparison so response timing does not leak the key
                if (given != null && MessageDigest.isEqual(given.getBytes(StandardCharsets.UTF_8), apiKey)) return true;
                res.setStatus(HttpStatus.UNAUTHORIZED.value());
                return false;
            }
        }).addPathPatterns("/api/ingest/**");
    }

    @RestControllerAdvice
    static class Errors {
        @ExceptionHandler({ConstraintViolationException.class, MethodArgumentNotValidException.class,
                HttpMessageNotReadableException.class})
        ResponseEntity<Map<String, String>> badRequest(Exception e) {
            return ResponseEntity.badRequest().body(Map.of("error", "invalid request"));
        }
    }
}
