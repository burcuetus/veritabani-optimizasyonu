-- ============================================================
-- Adım 6.3 — Koordinatör: postgres_fdw + dağıtık tablo + veri yükleme
-- Bağlantı: perflab
-- ============================================================

-- ------------------------------------------------------------
-- 1) Shard'lara nasıl ulaşılacak: EXTENSION / SERVER / USER MAPPING
-- ------------------------------------------------------------
--   EXTENSION    -> nasıl konuşacağım?
--   SERVER       -> nereye?
--   USER MAPPING -> kim olarak?
CREATE EXTENSION postgres_fdw;

-- port 5432, 5433 değil: bağlantıyı koordinatörün KENDİSİ, container içinden
-- kuruyor. 5433 sadece Windows -> container yönlendirmesi.
CREATE SERVER shard1_srv FOREIGN DATA WRAPPER postgres_fdw
  OPTIONS (host 'localhost', port '5432', dbname 'shard1');
CREATE SERVER shard2_srv FOREIGN DATA WRAPPER postgres_fdw
  OPTIONS (host 'localhost', port '5432', dbname 'shard2');

-- Parola yok: container içi localhost bağlantılarına imaj 'trust' ile izin veriyor.
-- Gerçek kurulumda: OPTIONS (user '...', password '...')
CREATE USER MAPPING FOR postgres SERVER shard1_srv OPTIONS (user 'postgres');
CREATE USER MAPPING FOR postgres SERVER shard2_srv OPTIONS (user 'postgres');


-- ------------------------------------------------------------
-- 2) Dağıtık tablo: partition'lar uzak tablolara açılan pencereler
-- ------------------------------------------------------------
CREATE SEQUENCE siparis_dagitik_id_seq;

CREATE TABLE siparis_dagitik (
    id          bigint         NOT NULL DEFAULT nextval('siparis_dagitik_id_seq'),
    musteri_id  int            NOT NULL,
    tutar       numeric(10,2)  NOT NULL,
    olusturma   timestamptz    NOT NULL
) PARTITION BY HASH (musteri_id);

ALTER SEQUENCE siparis_dagitik_id_seq OWNED BY siparis_dagitik.id;   -- 5.6'nın dersi

CREATE FOREIGN TABLE siparis_dagitik_0 PARTITION OF siparis_dagitik
  FOR VALUES WITH (MODULUS 2, REMAINDER 0)
  SERVER shard1_srv OPTIONS (table_name 'siparis');

CREATE FOREIGN TABLE siparis_dagitik_1 PARTITION OF siparis_dagitik
  FOR VALUES WITH (MODULUS 2, REMAINDER 1)
  SERVER shard2_srv OPTIONS (table_name 'siparis');

-- Bilerek PRIMARY KEY yok: foreign table'larda indeks olmaz, koordinatör
-- iki sunucu arasında benzersizliği denetleyemez. Global benzersizlik
-- tek bir sequence'e (tek bir noktaya) güveniyor.


-- ------------------------------------------------------------
-- 3) Veri yükleme: gidiş-dönüş sayısı
-- ------------------------------------------------------------
-- Varsayılan: her satır ayrı INSERT, ayrı gidiş-dönüş
EXPLAIN (ANALYZE, VERBOSE)
INSERT INTO siparis_dagitik (musteri_id, tutar, olusturma)
SELECT musteri_id, tutar, olusturma FROM siparis WHERE id <= 20000;
-- Execution Time: 5.626 ms  (~0,28 ms/satır = bir gidiş-dönüş)
-- Output satırında nextval(...) -> id koordinatörde üretiliyor

-- Toplu gönderim
ALTER SERVER shard1_srv OPTIONS (ADD batch_size '1000');
ALTER SERVER shard2_srv OPTIONS (ADD batch_size '1000');

EXPLAIN (ANALYZE, VERBOSE)
INSERT INTO siparis_dagitik (musteri_id, tutar, olusturma)
SELECT musteri_id, tutar, olusturma FROM siparis WHERE id BETWEEN 20001 AND 40000;
-- Execution Time: 225 ms  (25x)
-- Gidiş-dönüş 1000x azaldı, süre 25x: darboğaz ağdan gerçek işe (disk) döndü.
-- Aynı hastalık: döngüde tek tek INSERT, N+1 sorgu, satır başına API isteği.

-- Kalanı
INSERT INTO siparis_dagitik (musteri_id, tutar, olusturma)
SELECT musteri_id, tutar, olusturma FROM siparis WHERE id > 40000;

-- Dağılım (ilk scatter-gather sorgumuz)
SELECT tableoid::regclass AS shard, count(*) FROM siparis_dagitik GROUP BY 1;
-- siparis_dagitik_0 | 990.885
-- siparis_dagitik_1 | 988.314   (fark %0,3)
