# Çalışma notları (Adım 1–5)

Ölçüm sonuçları ve dersler. Kodlar ilgili klasörlerdeki .sql dosyalarında.

## 1. Adım: Veri diskte nasıl saklanır ve okunur

### Temel fikir

Veritabanı veriyi satır satır değil, sabit boyutlu **sayfalar** halinde saklar. PostgreSQL'de sayfa boyutu 8 KB'dir (8192 bayt) ve değişmez.

Bunun sonucu şu: tek bir satır istendiğinde, o satırı içeren sayfanın tamamı diskten okunur. Disk açısından tek bir satırı okumak ile o sayfadaki 185 satırı okumak arasında fark yoktur.

> Maliyetin ölçü birimi "kaç satır" değil, "kaç sayfa". Bütün çalışma bu cümlenin etrafında dönüyor.

### Deney 1: Satır genişliği sayfa sayısını belirler

İki tabloda da aynı sayıda satır var (1 milyon), ama satır genişlikleri farklı:

| Tablo | Kolon | Boyut | Sayfa | Sayfa başına satır |
|---|---|---|---|---|
| dar | 3 | 42 MB | 5.406 | 185 |
| genis | 8 | 251 MB | 32.158 | 31 |

Aradaki fark altı kat. `EXPLAIN (ANALYZE, BUFFERS)` ile taramanın tam olarak `relpages` kadar buffer okuduğunu doğruladık: `Buffers: shared hit=32 read=5374`, toplam 5.406.

### Tek kolon istemek okumayı azaltmaz

```sql
SELECT count(id) FROM genis;
```

`genis` tablosunun sekiz kolonundan sadece birini istedik. Okunan sayfa sayısı yine **32.158** çıktı, hiç değişmedi.

Sebebi **satır yönelimli depolama**. Bir satırın bütün kolonları sayfada yan yana durur. Tek bir kolona ulaşmak için o satırı barındıran sayfanın tamamı belleğe gelir.

- `SELECT *` yerine az kolon seçmek yine de faydalıdır. Ama bu fayda disk I/O'sunda değil; ağ trafiğinde, bellek kullanımında ve sıralama/hash maliyetinde görülür.
- Disk maliyetini düşürmenin yolları: tabloyu dar tutmak, covering index ve partitioning. Üçü de sonraki adımlarda denendi.
- ClickHouse, DuckDB ve Parquet gibi sütun yönelimli sistemler kolonları ayrı ayrı saklar. Bu yüzden tek kolonluk bir sorgu gerçekten sadece o kolonun baytlarını okur. Analitik sorgularda hızlı olmalarının sebebi bu.


## 2. Adım: Execution plan okuma
Deney 5 — İndekssiz başlangıç

dar tablosunda (1M satır, 5.406 sayfa) iki sorgu çalıştırdık:

Sorgu	Dönen satır	Sayfa	Süre
durum = 3	200.000	5.406	120 ms
id = 500000	1	5.406	204 ms

Ders: Tek satır aramak ile 200 bin satır aramak aynı maliyette çıktı. WHERE filtresi okunan sayfa sayısını azaltmıyor, sadece okuduktan sonra eliyor. Rows Removed by Filter: 999999 satırı bunu gösteriyordu.

İlk indeks
sql
CREATE INDEX idx_dar_id ON dar (id);

Aynı sorgu: 4 sayfa, 0,092 ms. 1.350 kat az sayfa.

4 sayfanın açıklaması: B-tree'nin kök + iç düğüm + yaprak sayfaları, artı tablonun tek bir sayfası. Bir milyon satır için ağaç sadece 3 seviye derinliğinde.

Öğrendiğimiz ayrım: Index Cond koşulu indekste arama yaparken kullanılır ve okumayı azaltır. Filter ise okuduktan sonra uygulanır, azaltmaz.

İkinci indeks ve Bitmap Scan
sql
CREATE INDEX idx_dar_durum ON dar (durum);

Optimizer ne Seq Scan ne Index Scan seçti; Bitmap Scan kullandı. Önce indeksten adresleri toplayıp bir harita çıkardı, sonra tabloyu sayfa sırasına göre okudu. Böylece rastgele okumayı sıralı okumaya çevirdi.

Sonuç 5.580 sayfa, 78 ms. İndekse rağmen sayfa sayısı düşmedi, kazanç sadece CPU'dan geldi.

Seçicilik kuralı:

Dönen oran	Uygun yöntem
%1'den az	Index Scan
%1–20	Bitmap Scan
%20'den fazla	Seq Scan

durum kolonunda 5 farklı değer olduğu için indeks pek işe yaramadı. Düşük çeşitlilikli kolonlara indeks genelde boşa masraf.

Index Only Scan ve visibility map

enable_bitmapscan ve enable_seqscan kapatınca Index Only Scan çıktı, ama Heap Fetches: 200000 gösterdi. Yani "tabloya gitmiyorum" derken 200 bin kez gitmiş.

Sebebi: bir satırın canlı olup olmadığı bilgisi indekste değil, tabloda. VACUUM ANALYZE dar çalıştırdıktan sonra:

	Sayfa	Süre
VACUUM öncesi	5.580	72 ms
VACUUM sonrası	175	35 ms

VACUUM visibility map'i güncelledi; PostgreSQL artık "bu sayfadaki her satır görünür" bilgisine güvenip tabloya hiç gitmedi.

Pratik not: Planda Index Only Scan gördüğünüzde hemen Heap Fetches satırına bakın. Yüksekse gizli bir tablo taraması var demektir.

İstatistikler: n_distinct ve correlation
sql
SELECT attname, n_distinct, correlation FROM pg_stats WHERE tablename = 'dar';
Kolon	n_distinct	correlation
id	-1 (benzersiz)	1,0
tutar	9.965	-0,002
durum	5	0,198

n_distinct optimizer'ın kaç satır döneceğini tahmin etmesini sağlıyor. correlation ise kolonun diskteki fiziksel sırayla ne kadar uyumlu olduğunu gösteriyor.

Correlation deneyi

Yaklaşık aynı sayıda satır döndüren iki aralık sorgusu:

Sorgu	Plan	Sayfa	Süre
id aralığı (corr=1)	Index Scan	12	0,4 ms
tutar aralığı (corr≈0)	Bitmap Scan	1.007	5,3 ms

84 kat fark. tutar sorgusunda 1.149 satır için 1.003 farklı sayfa açıldı; neredeyse her satır ayrı sayfadaydı.

CLUSTER ve temel kısıt
sql
CLUSTER dar USING idx_dar_tutar;

Sonuçlar tersine döndü:

	Öncesi	Sonrası
tutar correlation	-0,002	1,0
id correlation	1,0	0,008
tutar sorgusu	1.007 sayfa	11 sayfa
id sorgusu	12 sayfa	913 sayfa

Ders: Bir tablo diskte tek bir düzende durabilir. Birini optimize etmek diğerini bozar. Partitioning'e giden köprü burada kuruldu.

## 3. Adım: İndeksleme ve sorgu yazımı

Yeni tablo: siparis, 2 milyon satır, 190 MB, 24.373 sayfa.

Bileşik indekste kolon sırası

İki indeks oluşturup ayrı ayrı test ettik.

Her iki kolon da eşitlikle filtreleniyorsa fark yok:

İndeks	musteri_id=? AND durum=?
(musteri_id, durum)	4 sayfa
(durum, musteri_id)	4 sayfa

Tek kolonla filtrelendiğinde uçurum:

İndeks	musteri_id=?
(musteri_id, durum)	4 sayfa
(durum, musteri_id)	2.743 sayfa

686 kat fark. İkincide müşterinin kayıtları beş durum bloğuna dağıldığı için indeksin tamamı tarandı.

Leftmost prefix kuralı: (a,b,c) indeksi a, a+b, a+b+c sorgularını karşılar; b veya c tek başına sorgularını karşılamaz.

Sargability

Üç mantıksal olarak özdeş sorgu:

Sorgu	Plan satırı	Sayfa	Süre
musteri_id = 12345	Index Cond	4	0,07 ms
musteri_id + 0 = 12345	Filter	2.743	169 ms
abs(musteri_id) = 12345	Filter	2.743	156 ms

Kolonun etrafına fonksiyon veya aritmetik koymak indeksi devre dışı bırakıyor. Gerçek hayattaki karşılıkları:

sql
WHERE EXTRACT(year FROM olusturma) = 2026     -- kötü
WHERE olusturma >= '2026-01-01' 
  AND olusturma < '2027-01-01'                 -- iyi

WHERE email LIKE '%ornek.com'                  -- kötü
WHERE email LIKE 'ali%'                        -- iyi

Expression index denedik: lower(email) indeksi sadece lower(email) filtresini hızlandırdı; upper(email) sorgusu Seq Scan'e düşüp 1.140 ms sürdü.

Covering index
sql
CREATE INDEX idx_kapsayan ON siparis (musteri_id) INCLUDE (tutar);
	Plan	Sayfa
Normal indeks	Bitmap Heap Scan	42
INCLUDE ile	Index Only Scan	4

INCLUDE kolonu indeksin yapraklarında taşıyor ama sıralama anahtarı yapmıyor; filtrelemeyeceğiniz kolonlar için doğru seçim.

İndeksin bedeli
sql
SELECT indexrelname, pg_size_pretty(...), idx_scan FROM pg_stat_user_indexes ...

Tablo 190 MB, indeksler 219 MB. İki indeks hiç kullanılmamıştı (idx_scan = 0). idx_siparis_email_lower tek başına 95 MB, çünkü metin kolonları indekste bütün olarak saklanıyor.

## 5. Adım: Partitioning
Kurulum

siparis_p tablosunu PARTITION BY RANGE (olusturma) ile oluşturduk, bir DO bloğuyla 26 aylık partition ürettik, INSERT ... SELECT ile veriyi taşıdık. Her satır olusturma değerine göre doğru partition'a yönlendirildi (tuple routing).

Partition pruning
	Plan	Sayfa	Süre
Normal tablo	Seq Scan on siparis	24.373	259 ms
Partition'lı	Seq Scan on siparis_p_2026_09	755	17 ms

Append düğümü yoktu; 25 partition plana dahil bile edilmedi.

Pruning'in çalışmadığı durumlar
Sorgu	Sayfa	Süre
musteri_id = 12345 (anahtar yok)	24.382	278 ms
EXTRACT(year FROM olusturma) = 2026	24.382	844 ms
olusturma >= '2026-01-01' AND < '2027-01-01'	8.867	248 ms

Sargability kuralı pruning için de geçerli. Fonksiyon sarmalı hem indeksi hem pruning'i öldürüyor.

Takasın ölçüsü

Partition'lara indeks ekledikten sonra:

Sorgu tipi	Normal	Partition'lı	Kazanan
Tarih aralığı	24.373	755	Partition (32×)
Müşteri araması	4	73	Normal (18×)

Partition anahtarını içermeyen sorgular 26 ayrı B-tree'de arama yapmak zorunda. Partitioning bedava hızlanma değil, bir takas.

Asıl süper güç: veri silme
	Okunan	Kirletilen	Süre
DELETE FROM siparis WHERE olusturma < ...	59.192	14.019	1.131 ms
DETACH PARTITION	~0	0	anlık

DELETE her satırı ölü işaretliyor, WAL yazıyor, ardından VACUUM gerekiyor, alan geri gelmiyor. DETACH sadece bir katalog kaydı güncelliyor.

Birçok projede partitioning'e geçme sebebi budur; sorgu hızı ikincil kazanç.

Kısıtlar

Primary key partition anahtarını içermek zorunda. PRIMARY KEY (id) yerine PRIMARY KEY (id, olusturma). Sebebi: benzersizlik 26 ayrı indeks arasında denetlenemez. Sonucu: id tek başına benzersiz değil; bunu cakisma tablosuyla kanıtladık (aynı id iki farklı ayda yan yana durdu).

Unique constraint aynı kurala tabi. "E-posta benzersiz olsun" kuralını tarihe göre bölünmüş tabloda uygulayamazsınız.

Foreign key çalışıyor ama her partition'da ayrı bir kısıt olarak. pg_constraint sorgusunda 27 kayıt gördük: 1 ana + 26 partition. Hata mesajı da siparis_p_2024_10 için gelmişti.

HASH partitioning
	id = 500000	Tarih aralığı	id tek PK
Normal	4 sayfa	24.373	✓
RANGE (tarih)	73 sayfa	755	✗
HASH (id)	7 sayfa	14.554	✓

HASH, PK'yi kurtarıyor ve eşitlik sorgularında pruning sağlıyor; ama tarih pruning'i ve DETACH ile toplu silme imkânını kaybediyorsunuz.

Otomatik yönetim

partition_bakim() fonksiyonunu yazdık: gelecek aylar için eksik partition'ları oluşturuyor, saklama süresini aşanları DETACH + DROP ediyor.

Çalıştırdıktan sonra partition sayısı 27'de sabit kaldı; en eski silindi, yenileri eklendi. Ardından Aralık 2026 tarihli bir kayıt eklemeyi denedik ve başarılı oldu. tableoid kolonuyla kaydın siparis_p_2026_12 partition'ına düştüğünü doğruladık.

Zamanlama için pg_cron, işletim sistemi cron'u veya uygulama zamanlayıcısı kullanılabilir. Kritik olan izleme: en ileri partition'a kaç gün kaldığını ölçen bir alarm.
