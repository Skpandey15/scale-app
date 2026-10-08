package com.example.catalog.web;

import com.example.catalog.model.Model.TitlePage;
import com.example.catalog.model.Model.TitleView;
import com.example.catalog.query.TitleQueryService;
import graphql.analysis.MaxQueryComplexityInstrumentation;
import graphql.analysis.MaxQueryDepthInstrumentation;
import java.util.List;
import org.springframework.boot.autoconfigure.graphql.GraphQlSourceBuilderCustomizer;
import org.springframework.context.annotation.Bean;
import org.springframework.graphql.data.method.annotation.Argument;
import org.springframework.graphql.data.method.annotation.QueryMapping;
import org.springframework.stereotype.Controller;

/** GraphQL read API over the same service as REST (same cache, same circuit breaker). */
@Controller
public class GraphQlApi {
    private final TitleQueryService titles;

    public GraphQlApi(TitleQueryService titles) {
        this.titles = titles;
    }

    @QueryMapping
    public TitleView title(@Argument String id) {
        return titles.get(id).orElse(null);
    }

    @QueryMapping
    public TitlePage searchTitles(@Argument String q, @Argument Integer first, @Argument String after) {
        if (q == null || q.isBlank() || q.length() > 100) throw new IllegalArgumentException("q must be 1-100 characters");
        return titles.search(q, first == null ? 20 : first, after);
    }

    /** GraphQL lets one request ask for a lot: bound the depth and cost of a query so one client cannot hog the service. */
    @Bean
    GraphQlSourceBuilderCustomizer queryLimits() {
        return builder -> builder.instrumentation(List.of(
                new MaxQueryDepthInstrumentation(6),
                new MaxQueryComplexityInstrumentation(100)));
    }
}
