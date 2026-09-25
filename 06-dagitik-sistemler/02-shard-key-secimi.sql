-- ============================================================
-- Adım 6.2 — Shard key seçimi
-- Bağlantı: perflab
-- ============================================================
-- Veriyi taşımadan, her satırın 4 hayali shard'dan hangisine
-- düşeceğini hesaplayarak iki adayı karşılaştırıyoruz.
--
-- İyi shard key:
--   1. Eşit dağılım          3. En sık sorgu tek shard'a gider
--   2. Sıcak nokta yok       4. Değeri değişmez
--   5. Yüksek çeşitlilik (cardinality)


-- ------------------------------------------------------------
-- Aday 1: musteri_id üzerinden HASH
-- ------------------------------------------------------------
SELECT abs(hashint4(musteri_id)) % 4 AS shard,
       count(*) AS toplam,
       count(*) FILTER (WHERE olusturma >= (SELECT max(olusturma) FROM siparis) - interval '30 days') AS son_30_gun
FROM siparis
GROUP BY 1 ORDER BY 1;
-- shard | toplam  | son_30_gun
--   0   | 494.875 | 20.651
--   1   | 487.461 | 20.363
--   2   | 494.800 | 20.657
--   3   | 502.063 | 20.941
-- Hem depolama hem güncel yazma yükü eşit.


-- ------------------------------------------------------------
-- Aday 2: olusturma üzerinden RANGE (4 eşit zaman dilimi)
-- ------------------------------------------------------------
WITH s AS (SELECT min(olusturma) AS bas, max(olusturma) AS son FROM siparis)
SELECT width_bucket(extract(epoch FROM o.olusturma),
                    extract(epoch FROM s.bas),
                    extract(epoch FROM s.son) + 1, 4) - 1 AS shard,
       count(*) AS toplam,
       count(*) FILTER (WHERE o.olusturma >= s.son - interval '30 days') AS son_30_gun
FROM siparis o, s
GROUP BY 1 ORDER BY 1;
-- shard | toplam  | son_30_gun
--   0   | 494.368 | 0
--   1   | 495.246 | 0
--   2   | 494.302 | 0
--   3   | 495.283 | 82.612   <- SICAK NOKTA
-- Depolama eşit görünüyor ama bütün yeni yazmalar tek makineye gidiyor.
--
-- Partitioning'de (tek makine) tarih en iyi anahtardı; sharding'de
-- (çok makine) aynı yoğunlaşma amacın tersi. Hedef değişince cevap değişir.
--
-- Sorgu kalıbı:
--   "Müşterinin siparişleri" -> hash: tek shard    | range: 4 shard
--   "Dünün siparişleri"      -> hash: 4 shard      | range: tek shard
-- Yaygın tasarım: makineler arası musteri_id HASH + her shard içinde
-- olusturma RANGE partitioning (Citus'un kurduğu yapı).


-- ------------------------------------------------------------
-- Ünlü (celebrity) kontrolü: tek müşteri verinin büyük kısmı mı?
-- ------------------------------------------------------------
SELECT musteri_id, count(*),
       round(100.0 * count(*) / sum(count(*)) OVER (), 3) AS yuzde
FROM siparis
GROUP BY 1 ORDER BY 2 DESC LIMIT 5;
-- En büyük müşteri: 72 sipariş, %0,004 -> risk yok (sentetik veri)
