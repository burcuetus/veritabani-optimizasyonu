-- ============================================================
-- Adım 4 — İstatistikler, bakım ve konfigürasyon
-- Bağlantı: perflab (aksi yazılmadıkça)
-- Kaynak: perflab_setup.sql Bölüm 4, gözden geçirilmiş hali
-- Deneyler 29–30 Eylül 2026'da çalıştırıldı; sonuçlar "-- Sonuç:" satırlarında.
-- ============================================================


-- ---------- 4.1 İstatistikler bayatlayınca ----------
-- Optimizer tabloya bakmaz, ANALYZE'ın bıraktığı özete bakar.

DROP TABLE IF EXISTS bayat;
CREATE TABLE bayat (id int, kategori int, deger text)
  WITH (autovacuum_enabled = off);   -- SADECE deney için; üretimde asla

INSERT INTO bayat
SELECT g, (g % 100), repeat('x', 50)
FROM generate_series(1, 1000000) g;

CREATE INDEX idx_bayat_kategori ON bayat (kategori);
ANALYZE bayat;

EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM bayat WHERE kategori = 42;
-- Sonuç: tahmin 9.733, gerçek 10.000, Bitmap Heap Scan, 38 ms
--        Heap Blocks: exact=10000 -> 10 bin satır için 10 bin sayfa
--        (g % 100: aranan satırlar her sayfaya birer tane dağılmış)

-- Veri değişiyor, istatistik değişmiyor: 1M satır daha, hepsi kategori 42
INSERT INTO bayat
SELECT g, 42, repeat('x', 50)
FROM generate_series(1000001, 2000000) g;

EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM bayat WHERE kategori = 42;
-- Sonuç: tahmin 19.467, gerçek 1.010.000 (52x hata), Bitmap, 295 ms
--        Toplam satır dosya boyutundan GÜNCEL tahmin ediliyor (2M);
--        bayat olan DAĞILIM bilgisi (%1).
--        dirtied=4526: toplu INSERT sonrası ilk okuma hint bit yazar

-- Bayat mı? Üretimde bakılacak yer:
SELECT last_analyze, n_mod_since_analyze
FROM pg_stat_user_tables WHERE relname = 'bayat';
-- Sonuç: n_mod_since_analyze = 1.000.000

ANALYZE bayat;
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM bayat WHERE kategori = 42;
-- Sonuç: tahmin 1.012.933 (doğru), plan YİNE Bitmap (maliyet 49.096), 281 ms

-- ÜÇÜNÜ TEK BLOK halinde: Seq Scan ile karşılaştırma
SET enable_bitmapscan = off;
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM bayat WHERE kategori = 42;
RESET enable_bitmapscan;
-- Sonuç: Seq Scan maliyet 50.260 (%2 fark), 1.282 ms
--        Bitmap tablonun ~tamamını okurken maliyeti sıralı okumaya yakın.
-- DERS: Doğru istatistik her zaman planı değiştirmez; asıl zarar tahminin
--       başka kararları (JOIN türü, bellek) beslediği sorgularda çıkar.


-- ---------- 4.2 İstatistik çözünürlüğü ----------
-- MCV (en sık 100 değer) + 100 kovalık histogram.

DROP TABLE IF EXISTS carpik;
CREATE TABLE carpik AS
SELECT g AS id,
       (power(random(), 6) * 100000)::int AS deger   -- küçük değerler çok sık
FROM generate_series(1, 1000000) g;
ANALYZE carpik;

EXPLAIN (ANALYZE) SELECT count(*) FROM carpik WHERE deger = 50;
-- Sonuç: tahmin 900, gerçek 904   (değer MCV listesinde)
EXPLAIN (ANALYZE) SELECT count(*) FROM carpik WHERE deger = 5000;
-- Sonuç: tahmin 31, gerçek 23     (listede yok, "geri kalan" ortalaması)
--
-- Beklenen hata ÇIKMADI: dağılım düzgün çarpık; varsayılan 100 yetiyor.
-- SET STATISTICS ancak listenin DIŞINDA kalan bir değer beklenmedik
-- sıklıktaysa gerekir. Yöntem: önce tahmin/gerçek karşılaştır, sapma
-- görürsen o kolonda artır:
--   ALTER TABLE carpik ALTER COLUMN deger SET STATISTICS 1000;
--   ANALYZE carpik;


-- ---------- 4.3 Kolonlar arası bağımlılık (extended statistics) ----------
DROP TABLE IF EXISTS bagimli;
CREATE TABLE bagimli AS
SELECT g AS id,
       (g % 50) AS sehir,
       (g % 50) AS posta_kodu   -- sehir ile birebir aynı
FROM generate_series(1, 500000) g;

ANALYZE bagimli;

EXPLAIN (ANALYZE)
SELECT count(*) FROM bagimli WHERE sehir = 10 AND posta_kodu = 10;
-- Sonuç: tahmin 193, gerçek 10.000 (52x) -> 1/50 × 1/50 bağımsız varsayımı

CREATE STATISTICS stat_bagimli (dependencies, ndistinct)
  ON sehir, posta_kodu FROM bagimli;
ANALYZE bagimli;

EXPLAIN (ANALYZE)
SELECT count(*) FROM bagimli WHERE sehir = 10 AND posta_kodu = 10;
-- Sonuç: tahmin 10.450, gerçek 10.000 (%4)


-- ---------- 4.4 Autovacuum ----------
-- Tetikleme: 50 + 0.2 × satır ölü satır. Büyük tablolarda oranı düşür:
ALTER TABLE siparis SET (autovacuum_vacuum_scale_factor = 0.02);

SELECT relname, n_live_tup AS canli, n_dead_tup AS olu,
       round(n_dead_tup * 100.0 / NULLIF(n_live_tup + n_dead_tup, 0), 1) AS olu_yuzde,
       last_autovacuum, autovacuum_count
FROM pg_stat_user_tables WHERE n_dead_tup > 0
ORDER BY n_dead_tup DESC LIMIT 8;
-- Sonuç: boş. Container düzgün kapatılmadığı için (log: "not properly
--        shut down; automatic recovery") pg_stat sayaçları sıfırlanmıştı.


-- ---------- 4.5 Transaction wraparound ----------
SELECT datname, age(datfrozenxid) AS islem_yasi,
       2100000000 - age(datfrozenxid) AS kalan
FROM pg_database ORDER BY 2 DESC;
-- Sonuç: bütün veritabanlarında 201
-- Yaş SATIR değil İŞLEM sayısıyla artar: 2M satırlık INSERT tek işlem.
-- Risk, saniyede binlerce küçük işlem yapan sistemlerde.


-- ---------- 4.6 work_mem ----------
-- LIMIT YOK: LIMIT'li sorgu top-N heapsort ile birkaç KB'de biter.
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM siparis ORDER BY tutar;
-- Sonuç: external merge Disk: 146 MB, temp read/written ~36.5k sayfa, 3.084 ms

-- ÜÇÜNÜ TEK BLOK halinde:
SET work_mem = '512MB';
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM siparis ORDER BY tutar;
RESET work_mem;
-- Sonuç: quicksort Memory: 217 MB, temp yok, 2.197 ms (%29 hızlı)
--        Bellekte aynı iş daha fazla yer kaplıyor (146 -> 217 MB).
--        Kazanç küçük: temp dosyalar OS önbelleğinde kaldı ve tablo iki
--        seferde de diskten okundu (ring buffer).
-- DİKKAT: work_mem İŞLEM başına. 100 bağlantı × 217 MB ≈ 21 GB.


-- ---------- 4.7 random_page_cost ----------
EXPLAIN (ANALYZE, BUFFERS)
SELECT sum(id) FROM dar WHERE tutar BETWEEN 5000 AND 5200;
-- Sonuç: Bitmap, maliyet 6.044, read=5316, 286 ms

-- ÜÇÜNÜ TEK BLOK halinde:
SET random_page_cost = 1.1;
EXPLAIN (ANALYZE, BUFFERS)
SELECT sum(id) FROM dar WHERE tutar BETWEEN 5000 AND 5200;
RESET random_page_cost;
-- Sonuç: Bitmap, maliyet 5.992, hit=5316, 25 ms
-- 11x hızlanma AYARDAN DEĞİL, önbellekten (read -> hit). Plan aynı, çünkü
-- sorgu 5.406 sayfanın 5.295'ini açıyor. Karşılaştırmada Buffers'a bak!


-- ---------- 4.8 Bellek ayarları ----------
SELECT name, setting, unit FROM pg_settings
WHERE name IN ('shared_buffers','effective_cache_size','work_mem',
               'maintenance_work_mem','random_page_cost','max_connections');
-- Sonuç (hepsi varsayılan; unit '8kB' = sayfa):
--   shared_buffers 128 MB  (siparis 190 MB, sığmıyor)
--   work_mem 4 MB, maintenance_work_mem 64 MB
--   effective_cache_size 4 GB, random_page_cost 4, max_connections 100


-- ---------- 4.9 pg_stat_statements ----------
-- Liste ayarı TIRNAKSIZ yazılır. 'a,b' tek bir dosya adı sayılır ve
-- sunucu AÇILMAZ (bizde oldu: FATAL: could not access file
-- "pg_stat_statements,auto_explain").
-- TEK BAŞINA:
ALTER SYSTEM SET shared_preload_libraries = pg_stat_statements, auto_explain;
-- PowerShell:  docker restart pgperf
--
-- Sunucu açılmazsa kurtarma (container dururken):
--   docker run --rm --user postgres --volumes-from pgperf postgres:17 bash -c
--     "sed -i '/shared_preload_libraries/d' /var/lib/postgresql/data/postgresql.auto.conf"

CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- İş yükü: 500 indeksli sorgu + 1 ağır sorgu
DO $$
BEGIN
  FOR i IN 1..500 LOOP
    PERFORM count(*) FROM siparis WHERE musteri_id = i;
  END LOOP;
END $$;
SELECT count(*) FROM siparis WHERE abs(musteri_id) = 12345;

SELECT left(query, 50) AS sorgu, calls AS cagri,
       round(total_exec_time::numeric, 1) AS toplam_ms,
       round(mean_exec_time::numeric, 3) AS ortalama_ms
FROM pg_stat_statements
ORDER BY total_exec_time DESC LIMIT 5;
-- Sonuç 1: DO bloğu TEK satır; içindeki 500 sorgu görünmedi (track = top).
--          Fonksiyon içindeki yavaş sorgular varsayılan ayarla gizli kalır.
-- Sonuç 2: SET pg_stat_statements.track = 'all'; ile tekrar ->
--          "SELECT count(*) FROM siparis WHERE musteri_id = i" 500 çağrı,
--          tek satırda. Tek seferlik abs() Seq Scan'i yine listenin tepesinde.


-- ---------- 4.10 auto_explain: 6.3'teki açık soru ÇÖZÜLDÜ ----------
-- Soru: shard1'de doğrudan 120 ms süren GROUP BY, koordinatör üzerinden
-- neden ~466 ms+ sürüyordu?

ALTER DATABASE shard1 SET auto_explain.log_min_duration = 0;
ALTER DATABASE shard1 SET auto_explain.log_analyze = on;
ALTER DATABASE shard1 SET auto_explain.log_buffers = on;

-- Koordinatörden (TEK BLOK):
SET enable_partitionwise_aggregate = on;
EXPLAIN (ANALYZE)
SELECT musteri_id, count(*), sum(tutar)
FROM siparis_dagitik
WHERE olusturma >= '2026-09-01'
GROUP BY musteri_id;
-- PowerShell:  docker logs --since 2m pgperf
--
-- Sonuç (shard1 log):
--   Query Text: DECLARE c1 CURSOR FOR SELECT musteri_id, count(*) ...
--   GroupAggregate
--     -> Index Scan using siparis_musteri_id_idx
--          Rows Removed by Filter: 960092
--          Buffers: shared hit=980954 read=8456
--   duration: 2.438 ms
--
-- SEBEP: postgres_fdw sorguyu CURSOR ile çalıştırır. Cursor'lar için plan
-- ilk %10'u en hızlı getirecek şekilde seçilir (cursor_tuple_fraction=0.1)
-- -> indeks sırasıyla gruplama. Koordinatör ise sonucun TAMAMINI istiyor.

-- DÜZELTME (kalıcı):
ALTER DATABASE shard1 SET cursor_tuple_fraction = 1.0;
ALTER DATABASE shard2 SET cursor_tuple_fraction = 1.0;

-- Yeni ayarın geçerli olması için shard bağlantılarını yenile (TEK BLOK):
SELECT postgres_fdw_disconnect_all();
SET enable_partitionwise_aggregate = on;
EXPLAIN (ANALYZE)
SELECT musteri_id, count(*), sum(tutar)
FROM siparis_dagitik
WHERE olusturma >= '2026-09-01'
GROUP BY musteri_id;
-- Sonuç (shard1 log): HashAggregate -> Seq Scan, Buffers hit=7286, 144 ms
--        (önce 2.438 ms, ~989k buffer)

-- Teşhis bitince auto_explain'i kapat (her sorguyu ölçmek ek yük getirir):
ALTER DATABASE shard1 RESET auto_explain.log_min_duration;
ALTER DATABASE shard1 RESET auto_explain.log_analyze;
ALTER DATABASE shard1 RESET auto_explain.log_buffers;
