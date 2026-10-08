package com.example.app.web;

import com.example.app.domain.Models.Post;
import com.example.app.domain.Models.PostRepo;
import com.example.app.domain.Models.User;
import com.example.app.domain.Models.UserRepo;
import com.example.app.domain.PostDto;
import com.example.app.events.PostEvents;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Instant;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class PostService {
    private final PostRepo posts;
    private final UserRepo users;
    private final JdbcTemplate jdbc;
    private final ObjectMapper json;

    public PostService(PostRepo posts, UserRepo users, JdbcTemplate jdbc, ObjectMapper json) {
        this.posts = posts;
        this.users = users;
        this.jdbc = jdbc;
        this.json = json;
    }

    /** Post and its event commit atomically (transactional outbox); Kafka is not on the request path. */
    @Transactional
    public PostDto create(String username, String content) {
        User u = users.findByUsername(username).orElseThrow();
        Post p = new Post();
        p.userId = u.id;
        p.content = content;
        posts.save(p);
        PostDto dto = new PostDto(p.id, u.username, p.content, Instant.now());
        try {
            jdbc.update("insert into outbox(topic, msg_key, payload) values (?, ?, ?)",
                    PostEvents.TOPIC, u.username, json.writeValueAsString(dto));
        } catch (JsonProcessingException e) {
            throw new IllegalStateException(e);
        }
        return dto;
    }
}
