-- ============================================================
-- Adım 2 — Execution plan okuma
-- Bağlantı: perflab
-- Kaynak: perflab_setup.sql (kendi çalıştırdığım kurulum scripti)
-- ============================================================

CREATE INDEX idx_dar_id    ON dar (id);
CREATE INDEX idx_dar_durum ON dar (durum);
CREATE INDEX idx_dar_tutar ON dar (tutar);

-- TEK BAŞINA:
VACUUM ANALYZE dar;

-- ---------- Adım 2 ölçüm sorguları ----------

-- Seq Scan (indeks öncesi) vs Index Scan
-- EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM dar WHERE durum = 3;
-- EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM dar WHERE id = 500000;

-- Optimizer'ı belli bir plana zorlamak (ÜÇÜNÜ TEK BLOK halinde çalıştırın)
-- SET enable_bitmapscan = off;
-- SET enable_seqscan = off;
-- EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM dar WHERE durum = 3;
-- RESET enable_bitmapscan; RESET enable_seqscan;

-- Optimizer'ın tablo hakkında bildikleri
-- SELECT attname AS kolon, n_distinct AS farkli_deger_sayisi,
--        correlation AS fiziksel_siralilik
-- FROM pg_stats WHERE tablename = 'dar';

-- Correlation etkisi: aynı ölçekte satır, çok farklı sayfa sayısı
-- (indekste olmayan kolon istendiği için tabloya gitmek zorunlu)
-- EXPLAIN (ANALYZE, BUFFERS)
-- SELECT sum(tutar) FROM dar WHERE id BETWEEN 500000 AND 501000;    -- corr=1  -> ~12 sayfa
-- EXPLAIN (ANALYZE, BUFFERS)
-- SELECT sum(id) FROM dar WHERE tutar BETWEEN 5000 AND 5010;        -- corr~0  -> ~1007 sayfa

-- Fiziksel sıralamayı değiştirmek (bir tablo tek düzende durabilir!)
-- CLUSTER dar USING idx_dar_tutar;   -- tutar corr=1 olur, id corr~0 olur
-- VACUUM ANALYZE dar;
-- CLUSTER dar USING idx_dar_id;      -- geri al
