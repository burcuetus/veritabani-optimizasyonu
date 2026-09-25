-- ============================================================
-- Adım 6.3 — Elle sharding: shard veritabanları ve tabloları
-- ============================================================
--
--                 perflab (koordinatör)
--          siparis_dagitik  PARTITION BY HASH (musteri_id)
--             ┌──────────────┴──────────────┐
--   siparis_dagitik_0 (foreign)   siparis_dagitik_1 (foreign)
--             │ postgres_fdw                │ postgres_fdw
--             ▼                             ▼
--        shard1 veritabanı             shard2 veritabanı
--
-- Aynı sunucuda iki ayrı veritabanı = "ayrı makine" simülasyonu.
-- postgres_fdw normal bir istemci gibi bağlandığı için mantık aynı.


-- --- Bağlantı: perflab   (her biri TEK BAŞINA; transaction içinde çalışmaz)
CREATE DATABASE shard1;
CREATE DATABASE shard2;


-- --- Bağlantı: shard1, sonra AYNI DOSYA shard2'de
-- (SQLTools: localhost / 5433 / veritabanı shard1 veya shard2 / postgres)
--
-- Her shard aynı şemayı taşır; şema değişikliği her shard'da ayrı ayrı
-- yapılmak zorunda (sharding'in operasyonel yükü).
-- id için bigserial YOK: her shard kendi sequence'ini kullansaydı
-- iki shard'da aynı id oluşurdu. Numarayı koordinatör verecek.
CREATE TABLE siparis (
    id          bigint PRIMARY KEY,
    musteri_id  int            NOT NULL,
    tutar       numeric(10,2)  NOT NULL,
    olusturma   timestamptz    NOT NULL
);

CREATE INDEX ON siparis (musteri_id);
