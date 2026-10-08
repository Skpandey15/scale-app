package com.example.catalog.query;

import com.mongodb.MongoException;
import io.github.resilience4j.circuitbreaker.CircuitBreakerConfig;
import io.github.resilience4j.circuitbreaker.CircuitBreakerRegistry;
import io.github.resilience4j.micrometer.tagged.TaggedCircuitBreakerMetrics;
import io.micrometer.core.instrument.MeterRegistry;
import java.time.Duration;
import java.util.concurrent.TimeoutException;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.dao.DataAccessException;

@Configuration
public class ResilienceConfig {

    /** Opens after 5+ calls with >=50% failures in the last 10; probes again after 10 s with 3 trial calls. */
    @Bean
    CircuitBreakerRegistry circuitBreakerRegistry(MeterRegistry metrics) {
        CircuitBreakerConfig config = CircuitBreakerConfig.custom()
                .slidingWindowType(CircuitBreakerConfig.SlidingWindowType.COUNT_BASED)
                .slidingWindowSize(10)
                .minimumNumberOfCalls(5)
                .failureRateThreshold(50)
                .waitDurationInOpenState(Duration.ofSeconds(10))
                .permittedNumberOfCallsInHalfOpenState(3)
                .recordExceptions(DataAccessException.class, MongoException.class, TimeoutException.class)
                .build();
        CircuitBreakerRegistry registry = CircuitBreakerRegistry.of(config);
        TaggedCircuitBreakerMetrics.ofCircuitBreakerRegistry(registry).bindTo(metrics);
        return registry;
    }
}
