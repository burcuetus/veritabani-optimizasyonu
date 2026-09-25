-- ============================================================
-- Adım 5.4 — partition_bakim() fonksiyonu
-- Bağlantı: perflab
-- Kaynak: perflab_setup.sql (kendi çalıştırdığım kurulum scripti)
-- ============================================================

CREATE OR REPLACE FUNCTION partition_bakim(
  ana_tablo    text,
  ileri_ay     int DEFAULT 3,
  saklama_ay   int DEFAULT 24
) RETURNS void AS $$
DECLARE
  ay_basi    date;
  ay_sonu    date;
  p_adi      text;
  i          int;
  eski_sinir date;
  r          record;
BEGIN
  -- Gelecek partition'ları oluştur (idempotent)
  FOR i IN 0..ileri_ay LOOP
    ay_basi := date_trunc('month', now())::date + (i || ' months')::interval;
    ay_sonu := ay_basi + interval '1 month';
    p_adi   := ana_tablo || '_' || to_char(ay_basi, 'YYYY_MM');

    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = p_adi) THEN
      EXECUTE format(
        'CREATE TABLE %I PARTITION OF %I FOR VALUES FROM (%L) TO (%L)',
        p_adi, ana_tablo, ay_basi, ay_sonu
      );
      RAISE NOTICE 'Olusturuldu: %', p_adi;
    END IF;
  END LOOP;

  -- Saklama süresini geçmiş partition'ları kaldır
  eski_sinir := date_trunc('month', now())::date - (saklama_ay || ' months')::interval;

  FOR r IN
    SELECT c.relname
    FROM pg_class c
    JOIN pg_inherits inh ON inh.inhrelid = c.oid
    JOIN pg_class p ON p.oid = inh.inhparent
    WHERE p.relname = ana_tablo
      AND c.relname ~ '_\d{4}_\d{2}$'
      AND to_date(right(c.relname, 7), 'YYYY_MM') < eski_sinir
  LOOP
    EXECUTE format('ALTER TABLE %I DETACH PARTITION %I', ana_tablo, r.relname);
    EXECUTE format('DROP TABLE %I', r.relname);
    RAISE NOTICE 'Kaldirildi: %', r.relname;
  END LOOP;
END $$ LANGUAGE plpgsql;

-- Kullanım:
-- SELECT partition_bakim('siparis_p', 3, 24);

-- Zamanlama (Windows Task Scheduler / cron):
--   docker exec pgperf psql -U postgres -d perflab -c "SELECT partition_bakim('siparis_p', 3, 24)"

-- İZLEME: en ileri partition'a kaç gün kaldı? 30'un altı = alarm
-- SELECT max(to_date(right(c.relname, 7), 'YYYY_MM')) AS en_ileri_partition,
--        max(to_date(right(c.relname, 7), 'YYYY_MM')) - current_date AS kalan_gun
-- FROM pg_class c
-- JOIN pg_inherits i ON i.inhrelid = c.oid
-- JOIN pg_class p ON p.oid = i.inhparent
-- WHERE p.relname = 'siparis_p';
