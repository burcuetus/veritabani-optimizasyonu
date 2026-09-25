-- ============================================================
-- Adım 5.3 — PK / UNIQUE / FK kısıtları
-- Bağlantı: perflab
-- Kaynak: perflab_setup.sql (kendi çalıştırdığım kurulum scripti)
-- ============================================================

-- HATA VERİR: "unique constraint on partitioned table must include
-- all partitioning columns"
-- CREATE TABLE test_pk (
--   id        bigint PRIMARY KEY,
--   olusturma timestamptz NOT NULL
-- ) PARTITION BY RANGE (olusturma);

-- DOĞRUSU:
DROP TABLE IF EXISTS test_pk;
CREATE TABLE test_pk (
  id        bigint,
  olusturma timestamptz NOT NULL,
  PRIMARY KEY (id, olusturma)
) PARTITION BY RANGE (olusturma);

-- id ARTIK TEK BAŞINA BENZERSİZ DEĞİL - kanıt:
DROP TABLE IF EXISTS cakisma;
CREATE TABLE cakisma (
  id        int,
  olusturma timestamptz NOT NULL,
  PRIMARY KEY (id, olusturma)
) PARTITION BY RANGE (olusturma);

CREATE TABLE cakisma_01 PARTITION OF cakisma
  FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE cakisma_02 PARTITION OF cakisma
  FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');

INSERT INTO cakisma VALUES (1, '2026-01-15');
INSERT INTO cakisma VALUES (1, '2026-02-15');   -- ikisi de başarılı: id=1 iki kez var
