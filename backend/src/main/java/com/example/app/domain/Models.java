package com.example.app.domain;

import jakarta.persistence.*;
import java.time.Instant;
import java.util.List;
import java.util.Optional;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

public final class Models {
    private Models() {}

    @Entity(name = "User")
    @Table(name = "users")
    public static class User {
        @Id @GeneratedValue(strategy = GenerationType.IDENTITY)
        public Long id;
        public String username;
        @Column(name = "password_hash")
        public String passwordHash;
    }

    @Entity(name = "Post")
    @Table(name = "posts")
    public static class Post {
        @Id @GeneratedValue(strategy = GenerationType.IDENTITY)
        public Long id;
        @Column(name = "user_id")
        public Long userId;
        public String content;
        @Column(name = "created_at", insertable = false, updatable = false)
        public Instant createdAt;
    }

    public interface UserRepo extends JpaRepository<User, Long> {
        Optional<User> findByUsername(String username);
    }

    public interface PostRepo extends JpaRepository<Post, Long> {
        String SELECT = "select new com.example.app.domain.PostDto(p.id, u.username, p.content, p.createdAt) "
                + "from Post p join User u on u.id = p.userId ";

        @Query(SELECT + "order by p.id desc")
        List<PostDto> latest(Pageable page);

        @Query(SELECT + "where p.id < :before order by p.id desc")
        List<PostDto> before(@Param("before") long before, Pageable page);
    }
}
