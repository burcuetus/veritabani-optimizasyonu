-- ============================================================
-- Adım 6.3 — Tek shard sorgusu, scatter-gather, pushdown, async
-- Bağlantı: perflab (aksi yazılmadıkça)
-- SET ... satırlarını EXPLAIN ile BİRLİKTE seçip çalıştırın
-- (SQLTools ayrı çalıştırırsa oturum ayarı kaybolabilir).
-- ============================================================


-- ------------------------------------------------------------
-- 1) Shard key filtrede: tek shard + pushdown
-- ------------------------------------------------------------
EXPLAIN (ANALYZE, VERBOSE)
SELECT * FROM siparis_dagitik WHERE musteri_id = 12345;
-- Tek "Foreign Scan on siparis_dagitik_0"  -> pruning makineler arasında çalışıyor
-- Remote SQL: ... WHERE ((musteri_id = 12345))  -> filtre shard'a gönderildi
-- cost=100.00.. -> fdw_startup_cost: "uzağa gitmek başlı başına pahalı"
-- Execution Time: 11,2 ms   (yerel indeksle 0,07 ms -> ~150x yavaş)
-- Sharding tek sorgunun gecikmesini değil, toplam kapasiteyi iyileştirir.


-- ------------------------------------------------------------
-- 2) Shard key yok: scatter-gather
-- ------------------------------------------------------------
EXPLAIN (ANALYZE, VERBOSE)
SELECT count(*), sum(tutar)
FROM siparis_dagitik
WHERE olusturma >= '2026-09-01';
-- İki Foreign Scan, Append altında (sırayla!)
-- Remote SQL: SELECT tutar FROM ... WHERE (olusturma >= ...)
--   filtre gitti, TOPLAMA GİTMEDİ -> 61.927 satır ağdan taşındı
-- Tahmin rows=683, gerçek ~31.000 -> koordinatörün uzak tablo istatistiği yok
-- Execution Time: 535 ms


-- ------------------------------------------------------------
-- 3) Partition-wise aggregation
-- ------------------------------------------------------------
SET enable_partitionwise_aggregate = on;

EXPLAIN (ANALYZE, VERBOSE)
SELECT count(*), sum(tutar)
FROM siparis_dagitik
WHERE olusturma >= '2026-09-01';
-- Partial Aggregate + Finalize Aggregate çıktı, AMA Partial koordinatörde.
-- postgres_fdw (PG17) ara toplamayı shard'a gönderemiyor.
-- Append süresi 164 + 177 ≈ 341 ms -> shard'lar SIRAYLA sorgulanıyor.
-- Execution Time: 353 ms

RESET enable_partitionwise_aggregate;


-- ------------------------------------------------------------
-- 4) Asenkron (paralel) shard sorgusu
-- ------------------------------------------------------------
ALTER SERVER shard1_srv OPTIONS (ADD async_capable 'true');
ALTER SERVER shard2_srv OPTIONS (ADD async_capable 'true');

SELECT srvname, 'async_capable=true' = ANY(srvoptions) AS async_acik
FROM pg_foreign_server;

RESET enable_partitionwise_aggregate;   -- Partial Aggregate araya girerse async çalışmaz
EXPLAIN (ANALYZE, VERBOSE)
SELECT count(*), sum(tutar)
FROM siparis_dagitik
WHERE olusturma >= '2026-09-01';
-- "Async Foreign Scan" x2, ilk satır 3 ms'de
-- Execution Time: 216 ms  (süre ≈ en yavaş shard, toplam değil)
--
--   Varsayılan           535 ms
--   + partition-wise     353 ms
--   + async              216 ms


-- ------------------------------------------------------------
-- 5) Toplama ne zaman shard'a gidebilir? Shard key ile GROUP BY
-- ------------------------------------------------------------
SET enable_partitionwise_aggregate = on;

EXPLAIN (ANALYZE, VERBOSE)
SELECT musteri_id, count(*), sum(tutar)
FROM siparis_dagitik
WHERE olusturma >= '2026-09-01'
GROUP BY musteri_id;
-- Remote SQL: SELECT musteri_id, count(*), sum(tutar) ... GROUP BY 1
-- Relations: Aggregate on (...)  -> toplama shard'a devredildi, Partial/Finalize yok
-- KURAL: işlem ancak tek shard'ın verisiyle tamamlanabiliyorsa shard'a gider.
-- Execution Time: 1.371 ms (!)  -> 35.494 satır dönüyor; pushdown'ın faydası
-- işlemin veriyi ne kadar küçülttüğüne bağlı (burada ancak yarıya).


-- ------------------------------------------------------------
-- 6) Yavaşlığın teşhisi: katmanları ayırarak ölç
-- ------------------------------------------------------------
-- Hipotez 1: fetch_size (varsayılan 100 satırlık paketler)
ALTER SERVER shard1_srv OPTIONS (ADD fetch_size '10000');
ALTER SERVER shard2_srv OPTIONS (ADD fetch_size '10000');
-- Aynı sorgu: 1.120 ms -> hipotez büyük ölçüde YANLIŞ.
-- İpucu: Append actual time=665.969.. -> zaman ilk satırdan ÖNCE geçiyor.

-- Hipotez 2: shard'ın kendisi yavaş mı?
-- --- Bağlantı: shard1  (önce doğrula! aynı isimli tablo perflab'da da var)
SELECT current_database(), count(*) FROM siparis;   -- shard1 | ~990 bin
-- (İlk denemede yanlışlıkla perflab'da çalıştı: 1,98M satır, 24.373 sayfa.
--  Rakamlar mantıksızsa ilk soru: "doğru yerde miyim?")

EXPLAIN (ANALYZE, BUFFERS)
SELECT musteri_id, count(*), sum(tutar)
FROM siparis
WHERE olusturma >= '2026-09-01'
GROUP BY 1;
-- Parallel Seq Scan, Workers Launched: 2, shared hit=7286 -> ~80 ms

SET max_parallel_workers_per_gather = 0;   -- cursor'lar paralel sorgu kullanmaz
EXPLAIN (ANALYZE, BUFFERS)
SELECT musteri_id, count(*), sum(tutar)
FROM siparis
WHERE olusturma >= '2026-09-01'
GROUP BY 1;
-- Seq Scan -> 120 ms. Shard'ın kendisi hızlı.

-- Hipotez 3: async suçlu mu?
-- --- Bağlantı: perflab
SET enable_partitionwise_aggregate = on;
SET enable_async_append = off;
EXPLAIN (ANALYZE)
SELECT musteri_id, count(*), sum(tutar)
FROM siparis_dagitik
WHERE olusturma >= '2026-09-01'
GROUP BY musteri_id;
-- 1.818 ms -> async yardım ediyormuş.
-- Senkron modda: shard1 ilk satır 466 ms, shard2 ilk satır 629 ms.
-- Aynı sorgu doğrudan shard'da 120 ms, koordinatör üzerinden ilk satır 466 ms.
RESET enable_async_append;

-- SONUÇ (açık bırakıldı): Fark shard'ın sorguyu postgres_fdw oturumunda
-- (cursor) farklı çalıştırmasından geliyor. Sonraki adım: shard'da
-- auto_explain ile gerçekte çalışan planı log'a yazdırmak.
-- Ders: dağıtık sorgunun süresi parçalarının toplamı değildir.
