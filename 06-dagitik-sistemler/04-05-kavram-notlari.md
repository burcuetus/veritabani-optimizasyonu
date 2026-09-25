# 6.4 ve 6.5: Kavram notları

Bu iki bölüm deney yapılmadan, kavram notu olarak yazıldı. 6.3'teki `siparis_dagitik` kurulumu, buradaki fikirleri denemek için kullanılabilir.

6.3'ün ana kuralı: **bir işlem, ancak tek bir shard'ın verisiyle tamamlanabiliyorsa shard'a gönderilebilir.** 6.4, bu kuralın çiğnendiği dört durumu anlatıyor.

---

## 6.4 Shard'lar arası sorunlar

### 1. JOIN

İki tablonun birleştirilmesi gereken satırları farklı makinelerdeyse, birinin verisi ağ üzerinden diğerine taşınmak zorunda. Üç yaygın çözüm var:

| Yöntem | Nasıl | Ne zaman |
|---|---|---|
| **Birlikte yerleştirme (co-location)** | İki tablo da aynı shard key ile bölünür (`siparis` ve `odeme`, ikisi de `musteri_id` ile). Bir müşterinin bütün satırları aynı shard'da olur, JOIN her shard'da yerel olarak çalışır. | Aynı varlığa ait tablolar |
| **Referans tablo** | Küçük ve az değişen tablolar (ülke, kategori, ürün listesi) her shard'a **tam kopya** olarak konur. | Küçük boyut tablolar |
| **Veri taşıma (broadcast / repartition)** | Koordinatör bir tarafı çekip diğer tarafa gönderir ya da iki tarafı da çeker. | Kaçınılmaz olduğunda; en pahalı yol |

postgres_fdw'de JOIN, ancak iki foreign table **aynı sunucudaysa** shard'a gönderilir. Partition bazında JOIN için `enable_partitionwise_join = on` gerekir. `musteri` tablosu koordinatörde durduğu sürece, `siparis_dagitik` ile yapılan JOIN'de koordinatör siparişleri shard'lardan çekmek zorunda kalır. Shard key'e göre sharding tasarımının asıl sorusu da bu: **hangi tablolar birlikte sorgulanıyor?**

### 2. Dağıtık transaction

Bir işlem iki shard'a yazıyorsa (müşteri A'dan B'ye transfer, A shard1'de, B shard2'de), iki sunucunun birlikte COMMIT etmesi gerekir. postgres_fdw, koordinatör COMMIT ettiğinde her shard'ı **ayrı ayrı** COMMIT eder. Shard1 COMMIT ettikten sonra shard2 çökerse, işlemin yarısı kalıcı olur, yarısı kaybolur.

- **İki aşamalı commit (2PC):** Önce her shard'a `PREPARE TRANSACTION` ("hazır mısın, diske yazdın mı?"), herkes evet derse `COMMIT PREPARED`. Tutarlılığı sağlar ama koordinatör iki aşamanın arasında çökerse shard'larda kilitli, askıda kalan işlemler kalır. PostgreSQL 17'deki postgres_fdw 2PC'yi kendiliğinden yapmıyor (`parallel_commit` sadece COMMIT'leri paralel gönderir).
- **Tasarımla kaçınmak:** En iyi dağıtık transaction, hiç olmayanıdır. Shard key, işlemlerin büyük çoğunluğu tek shard'da kalacak şekilde seçilir.
- **Saga / outbox:** Kaçınılamıyorsa, iş adımlara bölünür. Her adım kendi shard'ında tamamlanır, hata olursa telafi adımı çalıştırılır (para geri yatırılır). Anlık değil, **nihai tutarlılık**: 6.1'deki replikasyon dersinin uygulama katmanındaki karşılığı.

### 3. Global ID

6.3'te `id` benzersizliğini koordinatördeki tek bir sequence sağlıyordu. Bunun iki sorunu var: koordinatör çökerse kimse ID alamaz, ve her INSERT o tek noktadan geçmek zorunda.

| Yöntem | Artısı | Eksisi |
|---|---|---|
| **Shard başına aralıklı sequence** (`INCREMENT BY 2 START 1` ve `START 2`) | Basit, koordinatör gerekmez | Shard sayısı değişince aralıklar karışır |
| **UUID v4** (`gen_random_uuid()`) | Her yerde üretilir, çakışmaz | Rastgele olduğu için B-tree'nin her yerine yazılır: indeks sayfaları dağınıklaşır (2. adımdaki correlation dersi) |
| **UUID v7** (PostgreSQL 18'de `uuidv7()`) | Zaman sıralı: yeni ID'ler indeksin sonuna eklenir | 16 bayt (bigint 8 bayt) |
| **Snowflake** (zaman + makine no + sayaç, 64 bit) | Sıralı, küçük, merkezsiz | Makine numaralarını yönetmek ve saat senkronizasyonu gerekir |

### 4. Yeniden dengeleme (rebalancing)

Bizim kurulumumuz `hash % 2`. Üçüncü bir shard eklemek için `hash % 3`'e geçilirse satırların yaklaşık **üçte ikisinin** yer değiştirmesi gerekir, çünkü kalan değerlerin çoğu değişir. Canlı sistemde bu kabul edilemez.

- **Sanal shard'lar:** Baştan çok sayıda mantıksal shard açılır (ör. 32), bunlar az sayıda makineye dağıtılır. Makine eklendiğinde bazı mantıksal shard'lar **bütün olarak** yeni makineye taşınır, hiçbir satırın hash'i değişmez. Citus'un varsayılanı 32 mantıksal shard.
- **PostgreSQL HASH partitioning'de de mümkün:** Modüller birbirinin katı olabildiği için `MODULUS 2, REMAINDER 1` partition'ı DETACH edilip yerine `MODULUS 4, REMAINDER 1` ve `REMAINDER 3` açılabilir. Sadece o partition'ın verisi taşınır.
- **Tutarlı hashing (consistent hashing):** Düğüm eklenince sadece komşu aralıktaki veri taşınır. Cassandra ve DynamoDB bu yaklaşımı kullanır.
- **Taşımanın kendisi:** Mantıksal replikasyonla yeni makineye kopyala, yetişmesini bekle, kısa bir kesintiyle yönlendirmeyi değiştir. 5. adımdaki ATTACH stratejisiyle aynı fikir: veri önceden hazırlanır, geçiş anı sadece katalog değişikliğidir.

---

## 6.5 Gerçek sistemler: ne zaman hangisi

6.3'te elle kurduğumuz yapının sınırlarını gördük: ara toplama shard'a gidemedi, istatistik yoktu, 2PC yok, yeniden dengeleme elle. Gerçek sistemler bu boşlukları kapatıyor.

| Sistem | Ne | Güçlü olduğu yer | Bedeli |
|---|---|---|---|
| **Citus** | PostgreSQL eklentisi. Dağıtık tablo, referans tablo, co-location, ara toplamayı shard'a gönderme, çevrimiçi yeniden dengeleme | Çok kiracılı (multi-tenant) SaaS, gerçek zamanlı analitik. PostgreSQL ekosisteminden çıkmadan ölçeklemek | Shard key tasarımı hâlâ senin sorumluluğunda; shard'lar arası JOIN ve transaction'lar pahalı kalır |
| **Vitess** | MySQL için sharding katmanı (YouTube, Slack) | Çok büyük MySQL kurulumları | MySQL dünyası; bazı SQL özellikleri kısıtlı |
| **CockroachDB / YugabyteDB / Spanner** | Baştan dağıtık tasarlanmış SQL. Veri, otomatik bölünen aralıklara ayrılır; her aralık Raft konsensüsüyle 3 kopyada tutulur | Otomatik sharding ve dengeleme, dağıtık serializable transaction, bölgeler arası dayanıklılık | Her yazma bir konsensüs turu bekler (6.1'deki senkron replikasyonun bedeli, her işlemde); PostgreSQL uyumluluğu kısmi |

### Karar sırası

1. Sorgu ve indeks optimizasyonu (2.–3. adım)
2. İstatistik, bakım ve konfigürasyon (4. adım)
3. Partitioning (5. adım)
4. Okuma yükü için replica, gerekirse önbellek (6.1)
5. Daha büyük makine (dikey ölçekleme)
6. **Ancak bunlar yetmezse** sharding: PostgreSQL'de kalmak isteniyorsa Citus; otomatik dağıtım ve bölgeler arası dayanıklılık gerekiyorsa CockroachDB/YugabyteDB

Sharding bir performans ayarı değil, bir mimari karardır. Geri almak neredeyse imkânsızdır.
