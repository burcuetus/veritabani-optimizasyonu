-- ============================================================
-- Adım 1 — Veri diskte nasıl saklanır ve okunur
-- Bağlantı: perflab
-- Kaynak: perflab_setup.sql (kendi çalıştırdığım kurulum scripti)
-- ============================================================

-- --- dar tablo: 3 kolon, satır ~34 bayt, sayfa başına ~185 satır
DROP TABLE IF EXISTS dar;
CREATE TABLE dar (
  id     int,
  tutar  int,
  durum  smallint
);

INSERT INTO dar
SELECT g, (random() * 10000)::int, (g % 5)
FROM generate_series(1, 1000000) g;

-- --- genis tablo: 8 kolon, satır ~245 bayt, sayfa başına ~31 satır
DROP TABLE IF EXISTS genis;
CREATE TABLE genis (
  id         int,
  tutar      int,
  durum      smallint,
  aciklama   text,
  etiket     varchar(100),
  olusturma  timestamptz,
  guncelleme timestamptz,
  meta       text
);

INSERT INTO genis
SELECT g, (random() * 10000)::int, (g % 5),
       repeat('x', 120),
       'etiket-' || g,
       now(), now(),
       repeat('y', 60)
FROM generate_series(1, 1000000) g;

-- TEK BAŞINA çalıştırın:
VACUUM ANALYZE dar, genis;

-- --- MVCC testi için minik tablo
DROP TABLE IF EXISTS mvcc_test;
CREATE TABLE mvcc_test (id int, deger text);
INSERT INTO mvcc_test VALUES (1, 'ilk'), (2, 'ikinci'), (3, 'ucuncu');

-- --- Önbellek (ring buffer) testi için küçük tablo
DROP TABLE IF EXISTS kucuk;
CREATE TABLE kucuk AS SELECT * FROM dar LIMIT 100000;


-- ---------- Adım 1 sonuçları ----------
-- Tablo | Kolon | Boyut  | Sayfa  | Sayfa başına satır
-- dar   |   3   | 42 MB  |  5.406 | 185
-- genis |   8   | 251 MB | 32.158 |  31      -> 6x sayfa farkı
--
-- EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM dar;
--   Buffers: shared hit=32 read=5374 = 5.406 = relpages
--
-- EXPLAIN (ANALYZE, BUFFERS) SELECT count(id) FROM genis;
--   Yine 32.158 sayfa: satır yönelimli depolamada tek kolon istemek
--   disk okumasını azaltmaz (fayda ağ/bellek/sıralama tarafında).
-- Ayrıntı: notlar/calisma-notlari.md


-- ---------- Adım 1 ölçüm sorguları ----------

-- Sayfa sayısı ve yoğunluk
-- SELECT relname,
--        pg_size_pretty(pg_relation_size(oid))   AS boyut,
--        relpages                                AS sayfa_sayisi,
--        reltuples::bigint                       AS satir_sayisi,
--        (reltuples / NULLIF(relpages, 0))::int  AS sayfa_basina_satir
-- FROM pg_class
-- WHERE relname IN ('dar', 'genis')
-- ORDER BY relpages;

-- Sayfa başlığı
-- SELECT * FROM page_header(get_raw_page('dar', 0));

-- Sayfa içindeki satırlar (lp_off azalır: satırlar sondan başa dolar)
-- SELECT lp AS yuva_no, lp_off AS ofset, lp_len AS satir_uzunlugu,
--        lp_flags, t_xmin, t_xmax, t_ctid
-- FROM heap_page_items(get_raw_page('dar', 0))
-- LIMIT 15;

-- Tek sayfadaki satır sayısı ve ortalama satır boyutu
-- SELECT count(*) AS sayfadaki_satir, avg(lp_len)::int AS ortalama_satir_bayti
-- FROM heap_page_items(get_raw_page('dar', 0));

-- Ölü satır / şişme durumu
-- SELECT pg_size_pretty(pg_relation_size('dar')) AS boyut,
--        n_live_tup AS canli, n_dead_tup AS olu, last_autovacuum
-- FROM pg_stat_user_tables WHERE relname = 'dar';

-- SELECT * FROM pgstattuple('dar');

-- Önbellekte hangi tablonun kaç sayfası var
-- SELECT c.relname, count(*) AS onbellekteki_sayfa,
--        pg_size_pretty(count(*) * 8192) AS bellekte_kaplanan
-- FROM pg_buffercache b
-- JOIN pg_class c ON b.relfilenode = pg_relation_filenode(c.oid)
-- WHERE c.relname IN ('dar', 'genis', 'kucuk')
-- GROUP BY c.relname;
