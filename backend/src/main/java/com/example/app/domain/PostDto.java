package com.example.app.domain;

import java.time.Instant;

public record PostDto(long id, String author, String content, Instant createdAt) {}
