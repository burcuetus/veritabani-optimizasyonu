-- ============================================================
-- Adım 5.6 — ATTACH sonrası: eksikler, sequence, DEFAULT partition
-- Bağlantı: perflab
-- ============================================================
-- Taşıma bitti gibi görünüyordu; gerçek bir test INSERT'ü iki gizli
-- sorunu ortaya çıkardı. Ders: taşıma sonrası MUTLAKA gerçek bir
-- INSERT ile test et.


-- ------------------------------------------------------------
-- 1) Gelecek ayların partition'ları
-- ------------------------------------------------------------
-- Tek partition 2026-10-01'de bitiyordu (üst sınır dahil değil).
-- Ekim'in ilk INSERT'ü "no partition of relation found for row" ile düşerdi.
-- Sınırlar UTC (+00). İstanbul (UTC+3) saatiyle 1 Ekim 01:00 kaydı
-- UTC'de 30 Eylül 22:00'dir -> Eylül partition'ına düşer.

CREATE TABLE canli_2026_10 PARTITION OF canli
  FOR VALUES FROM ('2026-10-01 00:00:00+00') TO ('2026-11-01 00:00:00+00');

CREATE TABLE canli_2026_11 PARTITION OF canli
  FOR VALUES FROM ('2026-11-01 00:00:00+00') TO ('2026-12-01 00:00:00+00');


-- ------------------------------------------------------------
-- 2) Kayıp DEFAULT: id artık otomatik üretilmiyor
-- ------------------------------------------------------------
-- Test INSERT'ü hata verdi:
--   null value in column "id" of relation "canli_2026_10" violates not-null constraint
-- Hata mesajı routing'in doğru çalıştığını da gösteriyor (canli_2026_10).
-- Sebep: canli_yeni "id bigint" olarak kuruldu; eski tablonun
-- bigserial DEFAULT'u yeni ana tabloya taşınmadı.

-- Eski sequence'i bul (yenisini açma, sayaç kaldığı yerden devam etmeli):
SELECT pg_get_serial_sequence(oid::regclass::text, 'id') AS sequence_adi
FROM pg_class WHERE relname LIKE 'canli_2025_09%';
-- -> public.canli_id_seq

ALTER TABLE canli ALTER COLUMN id SET DEFAULT nextval('public.canli_id_seq');

-- Sahiplik: sequence eski partition'a aitti. partition_bakim() o partition'ı
-- bir gün DROP etseydi sequence de silinir, bütün INSERT'ler dururdu.
ALTER SEQUENCE public.canli_id_seq OWNED BY canli.id;

-- Test
INSERT INTO canli (musteri_id, tutar, olusturma)
VALUES (12345, 99.90, '2026-10-15 12:00:00+03')
RETURNING id, tableoid::regclass;
-- Sonuç: id 702447, canli_2026_10
-- (500 bin değil: sequence'ler geri gitmez; boşluklar normaldir)

SELECT tableoid::regclass, count(*) FROM canli GROUP BY 1;


-- ------------------------------------------------------------
-- 3) Partition'ı olmayan ay -> INSERT reddedilir
-- ------------------------------------------------------------
INSERT INTO canli (musteri_id, tutar, olusturma)
VALUES (12345, 50.00, '2026-12-10 12:00:00+03');
-- HATA: no partition of relation "canli" found for row
-- (Bu başarısız INSERT de sequence'ten 702448'i tüketti.)


-- ------------------------------------------------------------
-- 4) DEFAULT partition: emniyet ağı ve bedeli
-- ------------------------------------------------------------
CREATE TABLE canli_default PARTITION OF canli DEFAULT;

INSERT INTO canli (musteri_id, tutar, olusturma)
VALUES (12345, 50.00, '2026-12-10 12:00:00+03')
RETURNING id, tableoid::regclass;
-- Sonuç: id 702449, canli_default  (hata yok)

-- Bedel: artık Aralık partition'ı açılamaz
CREATE TABLE canli_2026_12 PARTITION OF canli
  FOR VALUES FROM ('2026-12-01 00:00:00+00') TO ('2027-01-01 00:00:00+00');
-- HATA: updated partition constraint for default partition "canli_default"
--       would be violated by some row
-- İçi boş olsa bile her yeni partition açılışında DEFAULT baştan sona taranır
-- ve kilitlenir. Kural: DEFAULT çöp kutusu değil, alarm zili.
--   İzleme: SELECT count(*) FROM canli_default;  -- > 0 ise alarm


-- ------------------------------------------------------------
-- 5) Kurtarma: DETACH -> CREATE -> taşı -> ATTACH  (TEK BLOK)
-- ------------------------------------------------------------
BEGIN;

ALTER TABLE canli DETACH PARTITION canli_default;

CREATE TABLE canli_2026_12 PARTITION OF canli
  FOR VALUES FROM ('2026-12-01 00:00:00+00') TO ('2027-01-01 00:00:00+00');

INSERT INTO canli
SELECT * FROM canli_default
WHERE olusturma >= '2026-12-01 00:00:00+00' AND olusturma < '2027-01-01 00:00:00+00';

DELETE FROM canli_default
WHERE olusturma >= '2026-12-01 00:00:00+00' AND olusturma < '2027-01-01 00:00:00+00';

ALTER TABLE canli ATTACH PARTITION canli_default DEFAULT;

COMMIT;
-- Not: blok açıkken DEFAULT bağlı değildir; aralık dışı INSERT'ler hata verir.

-- Doğrulama
SELECT id, olusturma, tableoid::regclass
FROM canli WHERE musteri_id = 12345 ORDER BY id;
-- 702447 -> canli_2026_10, 702449 -> canli_2026_12 (id korundu)

SELECT pg_get_expr(relpartbound, oid) AS sinir,
       (SELECT count(*) FROM canli_default) AS satir
FROM pg_class WHERE relname = 'canli_default';
-- DEFAULT | 0


-- ------------------------------------------------------------
-- Temizlik (isteğe bağlı)
-- ------------------------------------------------------------
-- DELETE FROM canli WHERE musteri_id = 12345 AND id IN (702447, 702449);
