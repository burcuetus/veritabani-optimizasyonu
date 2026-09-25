-- ============================================================
-- Adım 5.1 — RANGE partitioning (siparis_p)
-- Bağlantı: perflab
-- Kaynak: perflab_setup.sql (kendi çalıştırdığım kurulum scripti)
-- ============================================================

DROP TABLE IF EXISTS siparis_p;
CREATE TABLE siparis_p (
  id          bigint,
  musteri_id  int NOT NULL,
  durum       text NOT NULL,
  tutar       numeric(10,2) NOT NULL,
  olusturma   timestamptz NOT NULL,
  email       text
) PARTITION BY RANGE (olusturma);

-- 26 aylık partition (24 ay geriden başlayıp 2 ay ileriye)
DO $$
DECLARE
  baslangic date := date_trunc('month', now() - interval '24 months');
  i int;
  ay_basi date;
  ay_sonu date;
BEGIN
  FOR i IN 0..25 LOOP
    ay_basi := baslangic + (i || ' months')::interval;
    ay_sonu := ay_basi + interval '1 month';
    EXECUTE format(
      'CREATE TABLE siparis_p_%s PARTITION OF siparis_p FOR VALUES FROM (%L) TO (%L)',
      to_char(ay_basi, 'YYYY_MM'), ay_basi, ay_sonu
    );
  END LOOP;
END $$;

-- Tuple routing: her satır olusturma değerine göre doğru partition'a gider
INSERT INTO siparis_p SELECT * FROM siparis;

-- TEK BAŞINA:
VACUUM ANALYZE siparis_p;

-- Ana tabloya açılan indeks, her partition'a ayrı ayrı uygulanır
CREATE INDEX idx_p_musteri ON siparis_p (musteri_id);

-- Unique index partition anahtarını İÇERMEK ZORUNDA
-- (sadece (email) ile denerseniz hata alırsınız)
CREATE UNIQUE INDEX idx_p_email ON siparis_p (email, olusturma);

-- --- FK testi için müşteri tablosu
-- Not: veri üretimi 1..50001 arası ürettiği için 50001 de eklenmeli
DROP TABLE IF EXISTS musteri CASCADE;
CREATE TABLE musteri (id int PRIMARY KEY, ad text);
INSERT INTO musteri SELECT g, 'Musteri ' || g FROM generate_series(1, 50001) g;

ALTER TABLE siparis_p
  ADD CONSTRAINT fk_musteri FOREIGN KEY (musteri_id) REFERENCES musteri(id);
-- FK ana tabloda tanımlanır, her partition'da ayrı kısıt olarak uygulanır (27 kayıt)


-- ---------- Partitioning ölçüm sorguları ----------

-- PRUNING ÇALIŞIR: tek partition, 755 sayfa, 17 ms
-- EXPLAIN (ANALYZE, BUFFERS) SELECT count(*), sum(tutar) FROM siparis_p
-- WHERE olusturma >= '2026-09-01' AND olusturma < '2026-10-01';

-- PRUNING ÇALIŞMAZ (anahtar sorguda yok): 24.382 sayfa
-- EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM siparis_p WHERE musteri_id = 12345;

-- PRUNING ÇALIŞMAZ (fonksiyon sarmalı): 24.382 sayfa, 844 ms
-- EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM siparis_p
-- WHERE EXTRACT(year FROM olusturma) = 2026;

-- Aynı sorgunun doğru yazımı: 8.867 sayfa
-- EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM siparis_p
-- WHERE olusturma >= '2026-01-01' AND olusturma < '2027-01-01';

-- DELETE vs DETACH (1131 ms vs anlık)
-- BEGIN;
-- EXPLAIN (ANALYZE, BUFFERS) DELETE FROM siparis WHERE olusturma < now() - interval '24 months';
-- ROLLBACK;
--
-- BEGIN;
-- ALTER TABLE siparis_p DETACH PARTITION siparis_p_2024_09;
-- ROLLBACK;

-- Bir satırın hangi partition'da olduğunu görmek
-- SELECT id, olusturma, tableoid::regclass AS hangi_partition
-- FROM siparis_p WHERE id = 99999999;

-- Partition listesi
-- SELECT c.relname FROM pg_class c
-- JOIN pg_inherits i ON i.inhrelid = c.oid
-- JOIN pg_class p ON p.oid = i.inhparent
-- WHERE p.relname = 'siparis_p' ORDER BY c.relname;
