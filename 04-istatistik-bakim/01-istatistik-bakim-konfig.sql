-- ============================================================
-- Adım 4 — İstatistikler, bakım ve konfigürasyon
-- Bağlantı: perflab (aksi yazılmadıkça)
-- Kaynak: perflab_setup.sql Bölüm 4, gözden geçirilmiş hali
--
-- DURUM: Deneyler henüz çalıştırılmadı. Sonuçlar ölçüldükçe
-- "-- Sonuç:" satırları eklenecek.
--
-- Orijinal plandan düzeltilenler:
--   4.1  autovacuum tabloyu kendiliğinden ANALYZE edip bayatlığı
--        siliyordu -> tabloda autovacuum kapatıldı, veri ANALYZE'dan
--        SONRA büyük ölçüde değiştiriliyor.
--   4.2  'durum' kolonunda 5 değer var; 100 kova zaten yetiyor, deney
--        fark göstermezdi -> çok değerli, çarpık dağılımlı yeni kolon.
--   4.6  ORDER BY ... LIMIT 100 top-N heapsort kullanır, diske hiç
--        taşmaz -> LIMIT'siz sıralama (EXPLAIN ANALYZE satır göndermez).
--   4.9  pg_stat_statements postgres:17 imajında mevcut; sadece
--        shared_preload_libraries + yeniden başlatma gerekiyor.
--   4.10 auto_explain eklendi (6.3'te açık kalan soru için).
-- ============================================================


-- ---------- 4.1 İstatistikler bayatlayınca ----------
-- Optimizer tabloya bakmaz, ANALYZE'ın bıraktığı özete bakar.
-- Veri değişip özet eski kalırsa, artık var olmayan bir tablo için
-- plan yapılır. "Dün hızlıydı, bugün yavaş" sorunlarının en yaygın sebebi.

DROP TABLE IF EXISTS bayat;
CREATE TABLE bayat (id int, kategori int, deger text)
  WITH (autovacuum_enabled = off);   -- SADECE deney için; üretimde asla

INSERT INTO bayat
SELECT g, (g % 100), repeat('x', 50)
FROM generate_series(1, 1000000) g;

CREATE INDEX idx_bayat_kategori ON bayat (kategori);
ANALYZE bayat;

-- Başlangıç: 100 kategori x 10.000 satır, istatistik doğru
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM bayat WHERE kategori = 42;
-- Beklenen: tahmin ≈ gerçek ≈ 10.000, Bitmap Scan

-- Veri değişiyor, istatistik değişmiyor: 1M satır daha, hepsi kategori 42
INSERT INTO bayat
SELECT g, 42, repeat('x', 50)
FROM generate_series(1000001, 2000000) g;

EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM bayat WHERE kategori = 42;
-- Beklenen: tahmin ~%1 (≈20.000), gerçek ~1.010.000
-- -> yarım tabloyu indeks üzerinden okumaya çalışan yanlış plan

ANALYZE bayat;
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM bayat WHERE kategori = 42;
-- Beklenen: tahmin düzelir, Seq Scan'e geçer

-- Tahmin/gerçek oranı 10x'i aşıyorsa ilk şüpheli bayat istatistiktir:
-- SELECT relname, last_analyze, last_autoanalyze, n_mod_since_analyze
-- FROM pg_stat_user_tables WHERE relname = 'bayat';


-- ---------- 4.2 İstatistik çözünürlüğü ----------
-- Varsayılan: kolon başına 100 MCV + 100 kovalık histogram.
-- Az değerli kolonlarda (ör. durum: 5 değer) zaten yeterli.
-- Çok değerli ve çarpık dağılımlı kolonlarda yetmeyebilir.

-- SHOW default_statistics_target;   -- 100

DROP TABLE IF EXISTS carpik;
CREATE TABLE carpik AS
SELECT g AS id,
       (power(random(), 6) * 100000)::int AS deger   -- küçük değerler çok sık
FROM generate_series(1, 1000000) g;
ANALYZE carpik;

EXPLAIN (ANALYZE) SELECT count(*) FROM carpik WHERE deger = 500;
-- Tahmin vs gerçek not edilecek

ALTER TABLE carpik ALTER COLUMN deger SET STATISTICS 1000;
ANALYZE carpik;

EXPLAIN (ANALYZE) SELECT count(*) FROM carpik WHERE deger = 500;
-- Beklenen: tahmin gerçeğe yaklaşır (daha fazla değer MCV listesine girer)

-- SELECT attname, n_distinct, array_length(most_common_vals::text::text[], 1) AS mcv_sayisi
-- FROM pg_stats WHERE tablename = 'carpik';

-- Bedeli: ANALYZE uzar, planlama yavaşlar. Sadece sorunlu kolonlarda yapın.


-- ---------- 4.3 Kolonlar arası bağımlılık (extended statistics) ----------
-- Optimizer kolonları BAĞIMSIZ varsayar ve olasılıkları çarpar.
-- İlişkili kolonlarda tahmin çöker.

DROP TABLE IF EXISTS bagimli;
CREATE TABLE bagimli AS
SELECT g AS id,
       (g % 50) AS sehir,
       (g % 50) AS posta_kodu   -- sehir ile birebir aynı
FROM generate_series(1, 500000) g;

ANALYZE bagimli;

-- Tahmin: 1/50 × 1/50 = 1/2500 -> ~200 satır.  Gerçek: 10.000
EXPLAIN (ANALYZE)
SELECT count(*) FROM bagimli WHERE sehir = 10 AND posta_kodu = 10;

CREATE STATISTICS stat_bagimli (dependencies, ndistinct)
  ON sehir, posta_kodu FROM bagimli;
ANALYZE bagimli;

EXPLAIN (ANALYZE)
SELECT count(*) FROM bagimli WHERE sehir = 10 AND posta_kodu = 10;
-- Beklenen: tahmin ≈ 10.000

-- Gerçek şemalarda: ülke/şehir, marka/model, kategori/alt-kategori.
-- 6.3'te koordinatörün foreign table tahmini (683 vs ~31.000) aynı
-- kökten: optimizer'ın elinde doğru istatistik yok.


-- ---------- 4.4 Autovacuum ayarları ----------
-- Tetikleme: eşik = autovacuum_vacuum_threshold + scale_factor × satır
-- Varsayılan scale_factor = 0.2: tablonun %20'si ölü satır olmadan
-- çalışmaz. 100M satırlık tabloda 20M ölü satır!

-- SHOW autovacuum_vacuum_scale_factor;   -- 0.2
-- SHOW autovacuum_vacuum_threshold;      -- 50

ALTER TABLE siparis SET (autovacuum_vacuum_scale_factor = 0.02);

-- İzleme: olu_yuzde sürekli yüksekse autovacuum yetişemiyor
SELECT relname, n_live_tup AS canli, n_dead_tup AS olu,
       round(n_dead_tup * 100.0 / NULLIF(n_live_tup + n_dead_tup, 0), 1) AS olu_yuzde,
       last_autovacuum, autovacuum_count
FROM pg_stat_user_tables WHERE n_dead_tup > 0
ORDER BY n_dead_tup DESC;


-- ---------- 4.5 Transaction wraparound ----------
-- İşlem numaraları (t_xmin) 32 bit; ~2 milyar işlemde başa döner.
-- Eski satırlar freeze edilmezse veritabanı YAZMAYI DURDURUR.
-- autovacuum_freeze_max_age (200M) aşılınca agresif freeze başlar.

SELECT datname,
       age(datfrozenxid) AS islem_yasi,
       2100000000 - age(datfrozenxid) AS kalan
FROM pg_database ORDER BY age(datfrozenxid) DESC;


-- ---------- 4.6 work_mem: sıralama diske taşarsa ----------
-- SHOW work_mem;   -- 4MB

-- LIMIT YOK: LIMIT'li sorgu top-N heapsort ile birkaç KB'de biter,
-- diske taşmaz. EXPLAIN ANALYZE satırları istemciye göndermez.
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM siparis ORDER BY tutar;
-- Beklenen: Sort Method: external merge  Disk: ... kB  + temp read/written

-- ÜÇÜNÜ TEK BLOK halinde:
SET work_mem = '512MB';
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM siparis ORDER BY tutar;
RESET work_mem;
-- Beklenen: Sort Method: quicksort  Memory: ... kB, temp yok

-- Karşılaştırma için:
-- EXPLAIN (ANALYZE) SELECT * FROM siparis ORDER BY tutar LIMIT 100;
-- -> top-N heapsort Memory: ~25kB

-- DİKKAT: work_mem bağlantı başına DEĞİL, İŞLEM başına.
-- 100 bağlantı × 3 sort/hash × 256MB = 75 GB. Global değeri ölçülü
-- tutup ihtiyaç duyan sorguda oturum bazında artırın.


-- ---------- 4.7 random_page_cost: SSD gerçeği ----------
-- 4.0 dönen disk varsayımı; SSD'de gerçek oran ~1.1.
-- Not: dar tablosu 2. adımda CLUSTER edildi; tutar/id correlation'ı
-- o anki duruma göre farklı plan verebilir. Önce pg_stats'a bakın.

EXPLAIN (ANALYZE, BUFFERS)
SELECT sum(id) FROM dar WHERE tutar BETWEEN 5000 AND 5200;

-- ÜÇÜNÜ TEK BLOK halinde:
SET random_page_cost = 1.1;
EXPLAIN (ANALYZE, BUFFERS)
SELECT sum(id) FROM dar WHERE tutar BETWEEN 5000 AND 5200;
RESET random_page_cost;

-- Ayar "daha hızlı" değil, "gerçeğe daha yakın" yapıyor.


-- ---------- 4.8 Bellek ayarları özeti ----------
--   Parametre              Varsayılan  Öneri            Ne yapar
--   shared_buffers         128MB       RAM'in %25'i     Sayfa önbelleği
--   effective_cache_size   4GB         RAM'in %50-75'i  Sadece hesap; bellek ayırmaz
--   work_mem               4MB         16-64MB          Sort/hash (İŞLEM başına!)
--   maintenance_work_mem   64MB        512MB-2GB        VACUUM, CREATE INDEX hızı
--   random_page_cost       4.0         1.1 (SSD)        Plan seçimi

SELECT name, setting, unit FROM pg_settings
WHERE name IN ('shared_buffers','effective_cache_size','work_mem',
               'maintenance_work_mem','random_page_cost','seq_page_cost');


-- ---------- 4.9 pg_stat_statements ----------
-- postgres:17 imajında mevcut; yüklenmesi için yeniden başlatma şart.
-- TEK BAŞINA (ALTER SYSTEM transaction içinde çalışmaz):
ALTER SYSTEM SET shared_preload_libraries = 'pg_stat_statements,auto_explain';

-- PowerShell:  docker restart pgperf
-- (pgreplica kısa süre bağlantıyı kaybeder, sonra kendiliğinden yetişir)

CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- TOPLAM SÜREYE göre sıralayın, ortalamaya göre değil:
-- 5 ms süren ama saniyede 1000 kez çağrılan sorgu, 2 saniyelik
-- günlük rapordan çok daha fazla yük yaratır.
SELECT round(total_exec_time::numeric, 1) AS toplam_ms,
       calls AS cagri,
       round(mean_exec_time::numeric, 2) AS ortalama_ms,
       shared_blks_read AS disk_sayfa,
       left(query, 80) AS sorgu
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 10;

-- SELECT pg_stat_statements_reset();   -- sayaçları sıfırla


-- ---------- 4.10 auto_explain: uygulamadan gelen sorgunun planı ----------
-- "Elle çalıştırınca hızlı, uygulamadan gelince yavaş" sorununun aracı.
-- Belli sürenin üstündeki her sorgunun GERÇEK planını log'a yazar.
-- 6.3'te açık kalan soru: koordinatörden gelen sorgu shard'da neden
-- 120 ms değil ~466 ms sürüyor?

-- Sadece shard1'e gelen sorgular için (perflab'da çalıştırın):
ALTER DATABASE shard1 SET auto_explain.log_min_duration = 0;
ALTER DATABASE shard1 SET auto_explain.log_analyze = on;
ALTER DATABASE shard1 SET auto_explain.log_buffers = on;

-- Koordinatörden sorguyu tekrar çalıştırın (partition-wise GROUP BY),
-- sonra PowerShell:  docker logs --tail 60 pgperf
-- Log'daki plan ile doğrudan shard1'de alınan planı karşılaştırın.

-- Geri almak:
-- ALTER DATABASE shard1 RESET ALL;
