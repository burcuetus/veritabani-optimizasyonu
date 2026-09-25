-- ============================================================
-- Adım 6.1 — Primary hazırlığı
-- Bağlantı: perflab (primary, localhost:5433)
-- ============================================================

-- Ayrı kullanıcı: en az yetki ilkesi. REPLICATION yetkisi sadece
-- WAL akışını okumaya izin verir, tablolara erişim vermez.
CREATE ROLE replikator WITH REPLICATION LOGIN PASSWORD '<REPL_PAROLA>';  -- kendi parolanızı yazın

-- PostgreSQL 10+ varsayılanları yeterli
SELECT name, setting FROM pg_settings
WHERE name IN ('wal_level', 'max_wal_senders', 'max_replication_slots');
-- wal_level = replica, max_wal_senders = 10, max_replication_slots = 10

-- pg_hba.conf nerede? (tahmin etme, sor)
SHOW hba_file;
-- /var/lib/postgresql/data/pg_hba.conf

-- (01-kurulum.ps1 adım 2 ile kural eklendikten sonra)
-- Yüklemeden ÖNCE diskteki dosyayı doğrula; bozuk dosya reload'da
-- sessizce reddedilir, sadece log'a yazılır.
SELECT line_number, type, database, user_name, address, auth_method, error
FROM pg_hba_file_rules
WHERE database::text LIKE '%replication%';

SELECT pg_reload_conf();   -- yeniden başlatmaz, bağlantılar kopmaz


-- (Replica başladıktan sonra) Primary'den bağlı replica'ları görmek
SELECT client_addr, usename, application_name, state, sync_state,
       sent_lsn, write_lsn, flush_lsn, replay_lsn
FROM pg_stat_replication;
-- replikator | walreceiver | streaming | async
-- sent -> write -> flush -> replay : WAL kaydının replica'daki 4 aşaması
