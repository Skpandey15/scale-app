package com.example.catalog.model;

import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;
import java.text.Normalizer;
import java.time.Instant;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.TreeSet;
import org.springframework.data.annotation.Id;
import org.springframework.data.annotation.Version;
import org.springframework.data.mongodb.core.index.Indexed;
import org.springframework.data.mongodb.core.index.TextIndexed;
import org.springframework.data.mongodb.core.mapping.Document;

/** Types shared by the write path (Kafka -> Mongo) and the read path (REST / GraphQL). */
public final class Model {
    private Model() {}

    /** What a feed or crawler sends before curation. */
    public record RawRecord(
            @NotBlank @Size(max = 50) String source,
            @NotBlank @Pattern(regexp = "(?i)movie|series|episode") String type,
            @NotBlank @Size(max = 300) String name,
            @NotNull @Min(1888) @Max(2100) Integer year,
            @Size(max = 20) List<@NotBlank @Size(max = 40) String> genres,
            @Size(max = 4000) String description) {}

    /** One curated, de-duplicated title. The id is the canonical key, so replays and duplicates converge on one document. */
    @Document("titles")
    public static class TitleDoc {
        @Id public String id;
        @Version public Long version;
        public String type;
        @TextIndexed(weight = 3) public String name;
        public Integer year;
        public Set<String> genres = new TreeSet<>();
        @TextIndexed public String description;
        public Set<String> sources = new TreeSet<>();
        public int confidence;
        public Instant updatedAt;
    }

    /** Per-source ingest count for one 1-minute window, written by the Kafka Streams job's sink. */
    @Document("ingest_stats")
    public static class IngestStat {
        @Id public String id;                 // "<source>@<windowStartMillis>"
        public String source;
        @Indexed public Instant windowStart;
        public long count;
    }

    public record TitleView(String id, String type, String name, Integer year, List<String> genres, String description,
                            List<String> sources, int confidence, boolean stale) {
        public static TitleView from(TitleDoc d) {
            return new TitleView(d.id, d.type, d.name, d.year, List.copyOf(d.genres), d.description,
                    List.copyOf(d.sources), d.confidence, false);
        }

        public TitleView asStale() {
            return new TitleView(id, type, name, year, genres, description, sources, confidence, true);
        }
    }

    public record TitlePage(List<TitleView> items, String nextCursor) {}

    public record IngestRate(String source, Instant windowStart, long count) {}

    /**
     * Canonical key: "The Matrix" (1999) and "THE MATRIX!" (1999) from different feeds resolve to the same id.
     * Lower-cased, accents and punctuation removed. (Not fuzzy: "Matrix, The" would not match; a real system adds
     * alias tables or similarity matching on top.)
     */
    public static String canonicalId(String type, String name, Integer year) {
        String folded = Normalizer.normalize(name.toLowerCase(Locale.ROOT), Normalizer.Form.NFD)
                .replaceAll("\\p{M}", "")
                .replaceAll("[^\\p{L}\\p{Nd}]", "");
        return type.toLowerCase(Locale.ROOT) + ":" + folded + ":" + year;
    }
}
