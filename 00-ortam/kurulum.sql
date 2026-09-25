-- ============================================================
-- Adım 0 — Ortam kurulumu
-- Bağlantı: önce postgres, sonra perflab veritabanı
-- Kaynak: perflab_setup.sql (kendi çalıştırdığım kurulum scripti)
-- ============================================================

-- PowerShell'de (tek satır):
--   docker run -d --name pgperf -e POSTGRES_PASSWORD=<PAROLA> -p 5433:5432 postgres:17
-- Durmuşsa yeniden başlatmak için:
--   docker start pgperf
--
-- Bağlantı bilgileri: localhost / 5433 / postgres / <PAROLA>

-- postgres veritabanına bağlıyken:
-- CREATE DATABASE perflab;

-- perflab veritabanına bağlandıktan sonra:
CREATE EXTENSION IF NOT EXISTS pageinspect;     -- sayfa içini okumak
CREATE EXTENSION IF NOT EXISTS pg_buffercache;  -- önbellekteki sayfalar
CREATE EXTENSION IF NOT EXISTS pgstattuple;     -- ölü satır / şişme ölçümü

-- Buffer sayaçlarının tek süreçte toplanması için (ölçümleri sadeleştirir).
-- Etkili olması için bağlantıyı kesip yeniden bağlanın.
ALTER DATABASE perflab SET max_parallel_workers_per_gather = 0;
