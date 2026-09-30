-- ============================================================
-- Adım 6.4 — Shard'lar arası sorunlar: deneyler
-- Kurulum: 03-postgres-fdw (siparis_dagitik, shard1_srv, shard2_srv)
-- Kavramsal arka plan: 04-05-kavram-notlari.md
-- ============================================================


-- ------------------------------------------------------------
-- 6.4.1 JOIN
-- ------------------------------------------------------------
-- Bağlantı: perflab. musteri tablosu koordinatörde, siparişler shard'larda.
EXPLAIN (ANALYZE, VERBOSE)
SELECT m.ad, count(*)
FROM siparis_dagitik s
JOIN musteri m ON m.id = s.musteri_id
WHERE m.ad = 'Musteri 12345'
GROUP BY m.ad;
-- Sonuç: Remote SQL: SELECT musteri_id FROM public.siparis   (WHERE YOK)
--        ~1.980.000 satır ağdan taşındı, 39'u eşleşti, ~1.150 ms
--        Tahmin rows=5850 (foreign table istatistiği yok)

-- Çözüm: birlikte yerleştirme (co-location)
-- Bağlantı: shard1, sonra shard2
CREATE TABLE musteri (id int PRIMARY KEY, ad text);

-- Bağlantı: perflab
DROP TABLE IF EXISTS musteri_dagitik;
CREATE TABLE musteri_dagitik (id int NOT NULL, ad text) PARTITION BY HASH (id);
CREATE FOREIGN TABLE musteri_dagitik_0 PARTITION OF musteri_dagitik
  FOR VALUES WITH (MODULUS 2, REMAINDER 0) SERVER shard1_srv OPTIONS (table_name 'musteri');
CREATE FOREIGN TABLE musteri_dagitik_1 PARTITION OF musteri_dagitik
  FOR VALUES WITH (MODULUS 2, REMAINDER 1) SERVER shard2_srv OPTIONS (table_name 'musteri');
INSERT INTO musteri_dagitik SELECT id, ad FROM musteri;
ANALYZE siparis_dagitik;   -- foreign table'larda da çalışır (uzaktan örnekler)
ANALYZE musteri_dagitik;

-- TEK BLOK:
SET enable_partitionwise_join = on;
EXPLAIN (ANALYZE, VERBOSE)
SELECT m.ad, count(*)
FROM siparis_dagitik s
JOIN musteri_dagitik m ON m.id = s.musteri_id
WHERE m.ad = 'Musteri 12345'
GROUP BY m.ad;
-- Sonuç: Relations: (siparis_dagitik_0 s_1) INNER JOIN (musteri_dagitik_0 m_1)
--        Remote SQL: SELECT r6.ad FROM (siparis r4 INNER JOIN musteri r6
--                    ON r4.musteri_id = r6.id AND r6.ad = 'Musteri 12345')
--        Shard'lardan 39 + 0 satır, 20 ms  (~57x)
-- DERS: Soru "hangi tabloyu bölelim" değil, "hangi tablolar birlikte
--       sorgulanıyor". Birlikte sorgulananlar aynı anahtarla bölünür.


-- ------------------------------------------------------------
-- 6.4.2 Dağıtık transaction: COMMIT anında bir shard düşerse
-- ------------------------------------------------------------
-- Bağlantı: shard2 — sadece COMMIT anında çalışan tuzak
CREATE OR REPLACE FUNCTION commitde_patla() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.musteri_id < 0 THEN
    RAISE EXCEPTION 'shard2 commit aninda coktu (simulasyon)';
  END IF;
  RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER commitde_patla
  AFTER INSERT ON siparis
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION commitde_patla();

-- Bağlantı: perflab — tek ifade = tek transaction, iki shard'a yazar
INSERT INTO siparis_dagitik (musteri_id, tutar, olusturma)
VALUES (-1, 1, now()), (-2, 1, now()), (-3, 1, now()), (-4, 1, now());
-- Sonuç: HATA: shard2 commit aninda coktu (simulasyon)

SELECT musteri_id, tableoid::regclass FROM siparis_dagitik WHERE musteri_id < 0 ORDER BY 1;
-- Sonuç: -4, -3, -2 -> siparis_dagitik_0  (shard1'de KALICI)
--        -1 yok
-- İşlem "başarısız" ama 4 satırın 3'ü yazıldı. postgres_fdw shard'lara
-- sırayla COMMIT gönderir; shard1 commit etti, shard2 reddetti, geri dönüş yok.
-- Sıra tersi olsaydı sonuç tutarlı olurdu -> hata şansa bağlı, testte görünmeyebilir.
-- Çözüm: 2PC (PREPARE TRANSACTION / COMMIT PREPARED) veya işlemleri tek
-- shard'da tutan shard key. PG17 postgres_fdw 2PC yapmıyor.

-- Temizlik
-- perflab: DELETE FROM siparis_dagitik WHERE musteri_id < 0;
-- shard2:  DROP TRIGGER commitde_patla ON siparis; DROP FUNCTION commitde_patla();


-- ------------------------------------------------------------
-- 6.4.3 Global ID: sıralı bigint mi, rastgele UUID mi?
-- ------------------------------------------------------------
-- Bağlantı: perflab
DROP TABLE IF EXISTS id_bigint, id_uuid;
CREATE TABLE id_bigint (id bigint PRIMARY KEY, tutar int);
CREATE TABLE id_uuid   (id uuid   PRIMARY KEY, tutar int);

EXPLAIN (ANALYZE, BUFFERS)
INSERT INTO id_bigint SELECT g, 1 FROM generate_series(1, 2000000) g;
-- Sonuç: 4.422 ms, hit=4,2M, dirtied=16.297, written=16.342

EXPLAIN (ANALYZE, BUFFERS)
INSERT INTO id_uuid SELECT gen_random_uuid(), 1 FROM generate_series(1, 2000000) g;
-- Sonuç: 12.232 ms (2,8x), hit=8,0M, dirtied=22.594, written=37.077
--        written > dirtied: rastgele eklemeler indeksin her yerine düşüyor,
--        indeks önbelleğe sığmadığı için aynı sayfa defalarca yazılıyor.

SELECT 'bigint' AS tur,
       pg_size_pretty(pg_relation_size('id_bigint_pkey')) AS indeks_boyutu,
       (pgstatindex('id_bigint_pkey')).leaf_pages AS yaprak_sayfa
UNION ALL
SELECT 'uuid',
       pg_size_pretty(pg_relation_size('id_uuid_pkey')),
       (pgstatindex('id_uuid_pkey')).leaf_pages;
-- Sonuç: bigint 43 MB, 5.465 yaprak (~366 kayıt/sayfa, ~%90 dolu)
--        uuid   77 MB, 9.781 yaprak (~204 kayıt/sayfa, ~%70 dolu)
--        1,8x = 1,4x (kayıt boyutu 20 vs 28 bayt) × sayfa bölünmesi
-- Ara çözüm: UUID v7 (zaman sıralı; PG18'de uuidv7()).

DROP TABLE id_bigint, id_uuid;


-- ------------------------------------------------------------
-- 6.4.4 Yeniden dengeleme: 2 shard'dan 3'e
-- ------------------------------------------------------------
-- satisfies_hash_partition, PostgreSQL'in hash partition fonksiyonunun kendisi.
WITH s AS (
  SELECT
    CASE WHEN satisfies_hash_partition('siparis_dagitik'::regclass, 2, 0, musteri_id) THEN 0 ELSE 1 END AS eski,
    CASE WHEN satisfies_hash_partition('siparis_dagitik'::regclass, 3, 0, musteri_id) THEN 0
         WHEN satisfies_hash_partition('siparis_dagitik'::regclass, 3, 1, musteri_id) THEN 1
         ELSE 2 END AS mod3,
    satisfies_hash_partition('siparis_dagitik'::regclass, 4, 3, musteri_id) AS mod4_tasinan
  FROM siparis
)
SELECT count(*) AS toplam,
       count(*) FILTER (WHERE eski <> mod3) AS mod3_tasinan,
       round(100.0 * count(*) FILTER (WHERE eski <> mod3) / count(*), 1) AS mod3_yuzde,
       count(*) FILTER (WHERE mod4_tasinan) AS bolme_tasinan,
       round(100.0 * count(*) FILTER (WHERE mod4_tasinan) / count(*), 1) AS bolme_yuzde
FROM s;
-- Sonuç: toplam 1.979.199
--   hash % 3 ile baştan dağıtım : 1.312.440 taşınır (%66,3) -> 33/33/33
--   MODULUS 2 -> 4 bölme        :   493.892 taşınır (%25,0) -> 50/25/25 (dengesiz)
-- Alt sınır: dengeli 3 makine için en az %33 taşınmalı.
-- Gerçek çözüm: sanal shard'lar (ör. 32 parça). Makine eklenince parçalar
-- BÜTÜN olarak taşınır: ~%33 veri, dengeli dağılım. (Citus varsayılanı 32.)
