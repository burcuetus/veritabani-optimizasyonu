-- ============================================================
-- Adım 3 — İndeksleme ve sorgu yazımı
-- Bağlantı: perflab
-- Kaynak: perflab_setup.sql (kendi çalıştırdığım kurulum scripti)
-- ============================================================

DROP TABLE IF EXISTS siparis;
CREATE TABLE siparis (
  id          bigserial PRIMARY KEY,
  musteri_id  int NOT NULL,
  durum       text NOT NULL,
  tutar       numeric(10,2) NOT NULL,
  olusturma   timestamptz NOT NULL,
  email       text
);

-- 2M satır, 50k müşteri, 2 yıla yayılmış tarihler (~190 MB, 24.373 sayfa)
INSERT INTO siparis (musteri_id, durum, tutar, olusturma, email)
SELECT (random() * 50000)::int + 1,
       (ARRAY['yeni','hazirlaniyor','kargoda','teslim','iptal'])[(random()*4)::int + 1],
       (random() * 5000)::numeric(10,2),
       now() - (random() * 730 || ' days')::interval,
       'kullanici' || g || '@ornek.com'
FROM generate_series(1, 2000000) g;

-- TEK BAŞINA:
VACUUM ANALYZE siparis;

-- --- Bileşik indeks: kolon sırası deneyi
CREATE INDEX idx_musteri_durum ON siparis (musteri_id, durum);
CREATE INDEX idx_durum_musteri ON siparis (durum, musteri_id);   -- "yanlış" sıra

-- Tek kolonla filtrelendiğinde fark 686 kat:
--   (musteri_id, durum) -> 4 sayfa   |   (durum, musteri_id) -> 2743 sayfa
-- Test için birini geçici olarak düşürün (TEK BLOK):
--   BEGIN;
--   DROP INDEX idx_durum_musteri;
--   EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM siparis WHERE musteri_id = 12345;
--   ROLLBACK;

-- --- Expression index (sargability)
CREATE INDEX idx_siparis_email_lower ON siparis (lower(email));

-- lower() indeksi SADECE lower() filtresini hızlandırır:
-- EXPLAIN (ANALYZE, BUFFERS)
-- SELECT count(*) FROM siparis WHERE lower(email) = 'kullanici500000@ornek.com';  -- 4 sayfa
-- EXPLAIN (ANALYZE, BUFFERS)
-- SELECT count(*) FROM siparis WHERE upper(email) = 'KULLANICI500000@ORNEK.COM';  -- Seq Scan, 1140 ms

-- Sargability karşılaştırması (Index Cond vs Filter):
-- WHERE musteri_id = 12345        -> Index Cond, 4 sayfa
-- WHERE musteri_id + 0 = 12345    -> Filter, 2743 sayfa
-- WHERE abs(musteri_id) = 12345   -> Filter, 2743 sayfa

-- --- Covering index
CREATE INDEX idx_kapsayan ON siparis (musteri_id) INCLUDE (tutar);
-- Bitmap Heap Scan (42 sayfa) -> Index Only Scan (4 sayfa)
-- EXPLAIN (ANALYZE, BUFFERS) SELECT sum(tutar) FROM siparis WHERE musteri_id = 12345;

-- --- İndeks maliyetini görmek
-- SELECT indexrelname AS indeks,
--        pg_size_pretty(pg_relation_size(indexrelid)) AS boyut,
--        idx_scan AS kullanim_sayisi
-- FROM pg_stat_user_indexes WHERE relname = 'siparis'
-- ORDER BY pg_relation_size(indexrelid) DESC;

-- SELECT pg_size_pretty(pg_relation_size('siparis')) AS tablo,
--        pg_size_pretty(pg_indexes_size('siparis'))  AS indeksler;
-- Sonuç: tablo 190 MB, indeksler 219 MB
