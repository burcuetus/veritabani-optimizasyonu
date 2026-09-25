-- ============================================================
-- Adım 5.2 — HASH partitioning (siparis_h)
-- Bağlantı: perflab
-- Kaynak: perflab_setup.sql (kendi çalıştırdığım kurulum scripti)
-- ============================================================

-- HASH'te partition anahtarı id olduğu için PRIMARY KEY (id) TEK BAŞINA çalışır
DROP TABLE IF EXISTS siparis_h;
CREATE TABLE siparis_h (
  id          bigint,
  musteri_id  int NOT NULL,
  tutar       numeric(10,2) NOT NULL,
  olusturma   timestamptz NOT NULL,
  PRIMARY KEY (id)
) PARTITION BY HASH (id);

CREATE TABLE siparis_h_0 PARTITION OF siparis_h FOR VALUES WITH (MODULUS 4, REMAINDER 0);
CREATE TABLE siparis_h_1 PARTITION OF siparis_h FOR VALUES WITH (MODULUS 4, REMAINDER 1);
CREATE TABLE siparis_h_2 PARTITION OF siparis_h FOR VALUES WITH (MODULUS 4, REMAINDER 2);
CREATE TABLE siparis_h_3 PARTITION OF siparis_h FOR VALUES WITH (MODULUS 4, REMAINDER 3);

INSERT INTO siparis_h SELECT id, musteri_id, tutar, olusturma FROM siparis;

-- TEK BAŞINA:
VACUUM ANALYZE siparis_h;

-- id = ? -> pruning çalışır (7 sayfa) | tarih aralığı -> çalışmaz (14.554 sayfa)
