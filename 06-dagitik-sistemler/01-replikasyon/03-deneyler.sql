-- ============================================================
-- Adım 6.1 — Replikasyon deneyleri
-- İki bağlantı: [PRIMARY] perflab @ 5433   |   [REPLICA] perflab @ 5435
-- Her bloğun başında hangi bağlantıda çalışacağı yazılı.
-- ============================================================


-- ------------------------------------------------------------
-- Deney 0: Doğru yerde miyim?
-- ------------------------------------------------------------
-- [REPLICA]
SELECT pg_is_in_recovery(), count(*) FROM canli;
-- t | 500002   (primary'de pg_is_in_recovery() = f)


-- ------------------------------------------------------------
-- Deney 1: Replica'ya yazmak
-- ------------------------------------------------------------
-- [REPLICA]
INSERT INTO canli (musteri_id, tutar, olusturma) VALUES (1, 1, now());
-- HATA: cannot execute INSERT in a read-only transaction
-- Tek yazıcı kuralı: replica okuma kapasitesini ölçekler, yazmayı ölçeklemez.


-- ------------------------------------------------------------
-- Deney 2: Primary'de yaz, replica'da oku
-- ------------------------------------------------------------
-- Test işareti olarak gerçek veride olamayacak bir değer (-777) kullan.
-- (Önce 777 denendi; gerçek bir müşterinin yüzlerce siparişine karıştı.)

-- [PRIMARY]
INSERT INTO canli (musteri_id, tutar, olusturma)
VALUES (-777, 7.77, now())
RETURNING id, tableoid::regclass;
-- 702450 | canli_2025_09_2026_09

-- [REPLICA]
SELECT id, musteri_id, olusturma FROM canli WHERE musteri_id = -777;
-- 702450 -> anında göründü (DDL'ler, yeniden adlandırmalar da WAL ile geliyor)


-- ------------------------------------------------------------
-- Deney 3: Gecikmeyi görünür yapmak — "kaydettim ama göremiyorum"
-- ------------------------------------------------------------
-- [REPLICA] WAL'ı almaya devam et ama UYGULAMA
SELECT pg_wal_replay_pause();
SELECT pg_get_wal_replay_pause_state();   -- paused

-- [PRIMARY]
UPDATE canli SET tutar = 999.99 WHERE musteri_id = -777 RETURNING id, tutar;

-- [REPLICA]
SELECT id, tutar FROM canli WHERE musteri_id = -777;
-- Primary 999.99, replica 7.77  -> nihai tutarlılık (eventual consistency)

-- [PRIMARY] Gecikmeyi ölçmek
SELECT application_name,
       pg_wal_lsn_diff(sent_lsn, replay_lsn) AS geride_byte,
       write_lag, flush_lag, replay_lag
FROM pg_stat_replication;
-- walreceiver | 632 byte  (zaman bazlı lag boşta güvenilmez; byte farkına bak)

-- [REPLICA]
SELECT pg_wal_replay_resume();
SELECT id, tutar FROM canli WHERE musteri_id = -777;   -- 999.99, geride_byte = 0

-- Read-your-writes çözümleri:
--   1. Yazdıktan sonra birkaç saniye o kullanıcıyı primary'den oku
--   2. LSN takibi: pg_current_wal_lsn() vs pg_last_wal_replay_lsn()
--   3. Senkron replikasyon (aşağıda)


-- ------------------------------------------------------------
-- Deney 4: Senkron replikasyon
-- ------------------------------------------------------------
-- [PRIMARY]
ALTER SYSTEM SET synchronous_standby_names = 'walreceiver';
SELECT pg_reload_conf();
SELECT sync_state FROM pg_stat_replication;   -- sync

-- [REPLICA]
SELECT pg_wal_replay_pause();

-- [PRIMARY] synchronous_commit = on (varsayılan)
UPDATE canli SET tutar = 111.11 WHERE musteri_id = -777 RETURNING id, tutar;
-- ANINDA bitti!

-- [REPLICA]
SELECT id, tutar FROM canli WHERE musteri_id = -777;
-- 999.99  -> 'on' replica'nın DİSKE YAZMASINI (flush) bekler, UYGULAMASINI değil.
--            Senkronun varsayılan amacı dayanıklılık; görünürlük değil.

-- synchronous_commit seviyeleri:
--   off          : kendi diskini bile bekleme
--   local        : sadece kendi diski
--   remote_write : replica OS'e yazdı   (write)
--   on           : replica diske yazdı  (flush)  <- varsayılan
--   remote_apply : replica uyguladı     (replay) -> replica'dan okuyan yeniyi görür

-- [PRIMARY] (TEK BLOK)
BEGIN;
SET LOCAL synchronous_commit = remote_apply;
UPDATE canli SET tutar = 222.22 WHERE musteri_id = -777;
COMMIT;
-- COMMIT ASILI KALDI (replay duraklatılmış)

-- [PRIMARY — başka oturumdan / terminalden]
SELECT pid, state, wait_event_type, wait_event, left(query, 50) AS sorgu
FROM pg_stat_activity WHERE wait_event = 'SyncRep';
-- 304 | active | IPC | SyncRep

-- [REPLICA]
SELECT pg_wal_replay_resume();   -- asılı COMMIT anında tamamlandı
SELECT id, tutar FROM canli WHERE musteri_id = -777;   -- 222.22

-- Bedel: replica takılırsa primary'deki BÜTÜN yazmalar durur.
-- Gerçek hayatta çözüm quorum:
--   synchronous_standby_names = 'ANY 1 (replica1, replica2)'

--                      | async           | sync (on) | sync (remote_apply)
-- Primary çökerse kayıp | son işlemler    | yok       | yok
-- Replica'da eski veri  | olabilir        | olabilir  | olmaz
-- Replica çökerse yazma | devam           | DURUR     | DURUR


-- ------------------------------------------------------------
-- GERİ AL — atlanmamalı!
-- ------------------------------------------------------------
-- Aksi halde pgreplica durduğunda pgperf'teki her yazma asılı kalır.
-- [PRIMARY]
ALTER SYSTEM RESET synchronous_standby_names;
SELECT pg_reload_conf();
SELECT sync_state FROM pg_stat_replication;   -- async
