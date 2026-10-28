-- Isolated PostgreSQL benchmark for issue OpenLDES/LDESServer#15
\set ON_ERROR_STOP on
\timing on
CREATE TABLE pages (
    page_id bigint PRIMARY KEY,
    partial_url varchar(255) NOT NULL UNIQUE
);
INSERT INTO pages (page_id, partial_url)
SELECT n, '/streams/by-time?year=2026&month=03&day=21&hour=15&pageNumber=' || n
FROM generate_series(1, 100000) AS s(n);
ANALYZE pages;
CREATE OR REPLACE FUNCTION canonical_fragment_url(input_url text)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $func$
    SELECT CASE
        WHEN position('?' in input_url) = 0 THEN input_url
        ELSE split_part(input_url, '?', 1) || '?' ||
             COALESCE((
                 SELECT string_agg(part, '&' ORDER BY part COLLATE "C")
                 FROM unnest(string_to_array(split_part(input_url, '?', 2), '&')) AS items(part)
             ), '')
    END
$func$;
-- The index must use the *same* normalization function as the query.
CREATE INDEX idx_pages_canonical_fragment_url ON pages (canonical_fragment_url(partial_url));
ANALYZE pages;

\echo '--- Correctness: canonicalization is order-independent ---'
DO $$
DECLARE a text := '/streams/by-time?year=2026&month=03&day=21&hour=15&pageNumber=50000';
DECLARE b text := '/streams/by-time?pageNumber=50000&hour=15&day=21&month=03&year=2026';
DECLARE key_a text;
DECLARE key_b text;
BEGIN
    SELECT canonical_fragment_url(a) INTO key_a;
    SELECT canonical_fragment_url(b) INTO key_b;
    IF key_a IS DISTINCT FROM key_b THEN
        RAISE EXCEPTION 'Canonical keys differ';
    END IF;
    IF (SELECT count(*) FROM pages
         WHERE canonical_fragment_url(partial_url) = canonical_fragment_url(b)) != 1 THEN
        RAISE EXCEPTION 'Reordered URL did not return exactly one page';
    END IF;
    IF (SELECT count(*) FROM pages
         WHERE canonical_fragment_url(partial_url) =
           canonical_fragment_url('/streams/by-time?pageNumber=999999&hour=15&day=21&month=03&year=2026')) != 0 THEN
        RAISE EXCEPTION 'Nonexistent page was matched';
    END IF;
    IF canonical_fragment_url('/streams/by-time?x=1&x=2') =
       canonical_fragment_url('/streams/by-time?x=1') THEN
        RAISE EXCEPTION 'Duplicate parameters were collapsed';
    END IF;
    RAISE NOTICE 'Assertions passed';
END $$;

\echo '--- Indexed, reordered existing page ---'
EXPLAIN (ANALYZE, BUFFERS, COSTS ON)
SELECT partial_url FROM pages
WHERE canonical_fragment_url(partial_url) =
canonical_fragment_url('/streams/by-time?pageNumber=50000&hour=15&day=21&month=03&year=2026')
LIMIT 2;

\echo '--- Indexed, reordered nonexistent page ---'
EXPLAIN (ANALYZE, BUFFERS, COSTS ON)
SELECT partial_url FROM pages
WHERE canonical_fragment_url(partial_url) =
canonical_fragment_url('/streams/by-time?pageNumber=999999&hour=15&day=21&month=03&year=2026')
LIMIT 2;

\echo '--- Unindexed fallback, reordered nonexistent page (previous candidate) ---'
EXPLAIN (ANALYZE, BUFFERS, COSTS ON)
SELECT p.partial_url
FROM pages p
WHERE split_part(p.partial_url, '?', 1) = '/streams/by-time'
  AND (
    SELECT string_agg(param.pair, '&' ORDER BY param.pair COLLATE "C")
    FROM unnest(string_to_array(split_part(p.partial_url, '?', 2), '&')) AS param(pair)
  ) = 'day=21&hour=15&month=03&pageNumber=999999&year=2026'
LIMIT 2;
