package com.example.app.web;

import com.example.app.domain.Models.PostRepo;
import com.example.app.domain.PostDto;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;
import java.time.Duration;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.TimeUnit;
import org.springframework.data.domain.PageRequest;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.http.CacheControl;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.Authentication;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/posts")
public class PostController {
    public record NewPost(@NotBlank @Size(max = 500) String content) {}
    public record Page(List<PostDto> items, Long nextCursor) {}

    private static final Duration HOT_PAGE_TTL = Duration.ofSeconds(5);

    private final PostRepo posts;
    private final PostService postService;
    private final StringRedisTemplate redis;
    private final ObjectMapper json;
    /** One in-flight DB load per hot key per pod: a cache miss no longer triggers a stampede of identical queries. */
    private final ConcurrentHashMap<String, CompletableFuture<Page>> inflight = new ConcurrentHashMap<>();

    public PostController(PostRepo posts, PostService postService, StringRedisTemplate redis, ObjectMapper json) {
        this.posts = posts;
        this.postService = postService;
        this.redis = redis;
        this.json = json;
    }

    /** Keyset (cursor) pagination: O(log n) at any depth, unlike OFFSET. */
    @GetMapping
    ResponseEntity<Page> feed(@RequestParam(required = false) Long before,
                              @RequestParam(defaultValue = "20") int size) {
        int n = Math.min(Math.max(size, 1), 50);
        Page page;
        if (before == null) {
            // Only the hot first page is cached in Redis; deep pages are cheap index scans.
            String key = "feed:first:" + n;
            page = readCache(key);
            if (page == null) page = loadSingleFlight(key, n);
        } else {
            page = query(before, n);
        }
        // CDN / browser can absorb repeat reads too.
        return ResponseEntity.ok().cacheControl(CacheControl.maxAge(Duration.ofSeconds(3)).cachePublic()).body(page);
    }

    @PostMapping
    ResponseEntity<PostDto> create(@Valid @RequestBody NewPost body, Authentication auth) {
        return ResponseEntity.ok(postService.create(auth.getName(), body.content()));
    }

    private Page query(Long before, int n) {
        var pr = PageRequest.of(0, n);
        List<PostDto> items = before == null ? posts.latest(pr) : posts.before(before, pr);
        return new Page(items, items.size() == n ? items.get(items.size() - 1).id() : null);
    }

    private Page loadSingleFlight(String key, int n) {
        CompletableFuture<Page> mine = new CompletableFuture<>();
        CompletableFuture<Page> leader = inflight.putIfAbsent(key, mine);
        if (leader != null) {
            try {
                return leader.get(3, TimeUnit.SECONDS); // piggy-back on the load already running
            } catch (Exception e) {
                return query(null, n);                    // leader failed or was slow: do our own load
            }
        }
        try {
            Page page = query(null, n);
            writeCache(key, page);
            mine.complete(page);
            return page;
        } catch (RuntimeException e) {
            mine.completeExceptionally(e);
            throw e;
        } finally {
            inflight.remove(key, mine);
        }
    }

    private Page readCache(String key) {
        try {
            String s = redis.opsForValue().get(key);
            return s == null ? null : json.readValue(s, new TypeReference<Page>() {});
        } catch (Exception e) {
            return null;
        }
    }

    private void writeCache(String key, Page page) {
        try {
            redis.opsForValue().set(key, json.writeValueAsString(page), HOT_PAGE_TTL);
        } catch (Exception ignored) {
        }
    }
}
