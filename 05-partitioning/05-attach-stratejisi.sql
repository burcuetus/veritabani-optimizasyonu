-- ============================================================
-- Adım 5.5 — Canlı tabloyu ATTACH ile partition'lamak
-- Bağlantı: perflab
-- Kaynak: perflab_setup.sql (kendi çalıştırdığım kurulum scripti)
-- DİKKAT: ADIM 5 (partition_bakim('canli')) bu yapıda doğrudan çalışmaz;
-- eski partition Eylül 2026'yı kapsadığı için canli_2026_09 çakışır.
-- Gelecek partition'lar 06-attach-sonrasi.sql'de elle açıldı.
-- ============================================================

-- Amaç: veriyi KOPYALAMADAN mevcut tabloyu partition'lı yapıya geçirmek.
-- Mevcut tablo, yeni yapının ilk partition'ı olur. Kesinti milisaniyeler.

-- --- Başlangıç durumu: "canlı" bir tablo
DROP TABLE IF EXISTS canli CASCADE;
CREATE TABLE canli (
  id         bigserial PRIMARY KEY,
  musteri_id int NOT NULL,
  tutar      numeric(10,2) NOT NULL,
  olusturma  timestamptz NOT NULL DEFAULT now()
);

INSERT INTO canli (musteri_id, tutar, olusturma)
SELECT (random() * 1000)::int + 1,
       (random() * 500)::numeric(10,2),
       now() - (random() * 365 || ' days')::interval
FROM generate_series(1, 500000) g;

CREATE INDEX idx_canli_musteri ON canli (musteri_id);

-- TEK BAŞINA:
VACUUM ANALYZE canli;


-- --- ADIM 1: Yeni (boş) partition'lı yapı
DROP TABLE IF EXISTS canli_yeni;
CREATE TABLE canli_yeni (
  id         bigint NOT NULL,
  musteri_id int NOT NULL,
  tutar      numeric(10,2) NOT NULL,
  olusturma  timestamptz NOT NULL,
  PRIMARY KEY (id, olusturma)
) PARTITION BY RANGE (olusturma);


-- --- ADIM 2: PK'yi uyumlu hale getir
-- Partition'lı tablonun PK'si (id, olusturma). Mevcut tablodaki (id)
-- PK'si ile çakışır: "multiple primary keys for table are not allowed"
ALTER TABLE canli DROP CONSTRAINT canli_pkey;
ALTER TABLE canli ADD PRIMARY KEY (id, olusturma);

-- ÜRETİMDE kilit süresini kısaltma kalıbı (her biri TEK BAŞINA):
--   CREATE UNIQUE INDEX CONCURRENTLY canli_yeni_pkey ON canli (id, olusturma);
--   ALTER TABLE canli DROP CONSTRAINT canli_pkey;
--   ALTER TABLE canli ADD PRIMARY KEY USING INDEX canli_yeni_pkey;
-- USING INDEX = "yeni indeks kurma, hazır olanı devral" -> kilit milisaniyeler


-- --- ADIM 3: CHECK kısıtı (ATTACH'in doğrulama taramasını atlatır)
-- Önce gerçek sınırları öğrenin:
--   SELECT min(olusturma), max(olusturma) FROM canli;
-- Sonra sınırları kapsayan bir CHECK ekleyin (tarihleri kendinize göre ayarlayın):
ALTER TABLE canli ADD CONSTRAINT canli_tarih_check
  CHECK (olusturma >= '2025-09-01' AND olusturma < '2026-10-01');

-- Üretimde tarama ertelenebilir:
--   ALTER TABLE canli ADD CONSTRAINT ... CHECK (...) NOT VALID;
--   ALTER TABLE canli VALIDATE CONSTRAINT canli_tarih_check;


-- --- ADIM 4: Atomik geçiş (TEK BLOK halinde çalıştırın)
BEGIN;

ALTER TABLE canli_yeni ATTACH PARTITION canli
  FOR VALUES FROM ('2025-09-01') TO ('2026-10-01');

ALTER TABLE canli RENAME TO canli_2025_09_2026_09;
ALTER TABLE canli_yeni RENAME TO canli;

COMMIT;


-- --- ADIM 5: Gelecek partition'ları aç
-- SELECT partition_bakim('canli', 3, 24);


-- --- İsteğe bağlı temizlik: CHECK artık gereksiz (partition sınırı aynı garantiyi verir)
-- DO $$
-- DECLARE k text;
-- BEGIN
--   SELECT conname INTO k FROM pg_constraint
--   WHERE conrelid = 'canli_2025_09_2026_09'::regclass AND contype = 'c'
--   LIMIT 1;
--   IF k IS NOT NULL THEN
--     EXECUTE format('ALTER TABLE canli_2025_09_2026_09 DROP CONSTRAINT %I', k);
--     RAISE NOTICE 'Silindi: %', k;
--   END IF;
-- END $$;


-- --- Doğrulama
-- SELECT count(*) FROM canli;                        -- 500000 olmalı
-- SELECT relname, relkind FROM pg_class
-- WHERE relname IN ('canli', 'canli_2025_09_2026_09');  -- p = partition'lı, r = normal
