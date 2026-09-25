# PostgreSQL Veri Optimizasyonu, Partitioning ve Sharding

PostgreSQL 17 üzerinde, Docker'da kurulmuş bir laboratuvarda yaptığım deneyler. Diskteki sayfa yapısından başlayıp, execution plan okuma, indeksleme ve partitioning üzerinden replikasyon ile elle sharding'e kadar ilerliyor. Her adımda bir şey ölçüldü, sonuç tabloları aşağıda.

## Ortam

| Container | İmaj | Port | Rol |
|---|---|---|---|
| `pgperf` | `postgres:17` | 5433 | Ana laboratuvar (`perflab` veritabanı), primary, sharding koordinatörü |
| `pgreplica` | `postgres:17` | 5435 | Streaming replica (6.1) |

Kurulum: [`00-ortam/kurulum.sql`](00-ortam/kurulum.sql). Sorgular VS Code + SQLTools ile çalıştırıldı.

## Plan

| # | Konu | Klasör | Durum |
|---|---|---|---|
| 1 | Veri diskte nasıl saklanır ve okunur | `01-sayfa-yapisi` | ✅ |
| 2 | Execution plan okuma | `02-execution-plan` | ✅ |
| 3 | İndeksleme ve sorgu yazımı | `03-indeksleme` | ✅ |
| 4 | İstatistikler, bakım, konfigürasyon | — | ⏳ sırada |
| 5 | Partitioning | `05-partitioning` | ✅ |
| 6 | Dağıtık sistemler, sharding | `06-dagitik-sistemler` | 6.1–6.3 ✅, 6.4–6.5 ⏳ |

Ayrıntılı notlar `notlar/` klasöründe. Dosyalar numara sırasıyla çalıştırılır. Her dosyanın başında hangi bağlantıda çalışacağı yazılıdır.

## Öne çıkan ölçümler

### 1. Sayfa yapısı
| Tablo | Kolon | Boyut | Sayfa | Sayfa başına satır |
|---|---|---|---|---|
| `dar` | 3 | 42 MB | 5.406 | 185 |
| `genis` | 8 | 251 MB | 32.158 | 31 |

`SELECT count(id) FROM genis` da 32.158 sayfa okudu. Satır yönelimli depolamada tek kolon istemek disk okumasını azaltmaz.

### 2. Execution plan
| Deney | Önce | Sonra |
|---|---|---|
| `id = 500000`, indeks yok → B-tree | 5.406 sayfa, 204 ms | 4 sayfa, 0,09 ms |
| Index Only Scan, VACUUM öncesi → sonrası | 5.580 sayfa (Heap Fetches 200k) | 175 sayfa |
| Aralık sorgusu, correlation 1 vs ≈0 | 12 sayfa | 1.007 sayfa |

Bir tablo diskte tek bir düzende durabilir: `CLUSTER` bir kolonun correlation'ını düzeltirken diğerininkini bozdu.

### 3. İndeksleme
| Deney | Sonuç |
|---|---|
| `(musteri_id, durum)` vs `(durum, musteri_id)`, sadece `musteri_id` ile filtre | 4 vs 2.743 sayfa (686×) |
| `musteri_id = 12345` vs `musteri_id + 0 = 12345` | Index Cond 4 sayfa vs Filter 2.743 sayfa |
| Covering index (`INCLUDE (tutar)`) | 42 → 4 sayfa |
| İndeks maliyeti | Tablo 190 MB, indeksler 219 MB; iki indeks hiç kullanılmamış |

### 5. Partitioning
| Deney | Normal tablo | Partition'lı |
|---|---|---|
| Tek ay (pruning) | 24.373 sayfa, 259 ms | 755 sayfa, 17 ms |
| Müşteri araması (anahtar yok) | 4 sayfa | 73 sayfa |
| Eski veriyi silmek | DELETE 1.131 ms + VACUUM | DETACH, anlık |

- PK / UNIQUE partition anahtarını içermek zorunda; `id` tek başına benzersiz kalmıyor.
- Canlı tablo, veri kopyalanmadan `ATTACH` ile partition'landı (CHECK kısıtı doğrulama taramasını atlattı).
- Sonradan yapılan test INSERT'ü iki gizli sorunu yakaladı: kayıp `id` DEFAULT'u ve eski partition'a ait sequence.
- DEFAULT partition emniyet ağı ama içi dolunca yeni partition açılamıyor; DETACH → CREATE → taşı → ATTACH ile kurtarıldı.

### 6.1 Replikasyon
- Replica yazma kabul etmiyor: okuma ölçeklenir, yazma ölçeklenmez.
- WAL replay duraklatılınca primary `999.99`, replica `7.77` gösterdi (632 byte gecikme).
- `synchronous_commit = on` replica'nın **diske yazmasını** bekliyor, uygulamasını değil; replica eski veriyi göstermeye devam etti.
- `remote_apply` ile COMMIT, replica duraklatıldığı sürece asılı kaldı (`wait_event = SyncRep`). Senkronun bedeli kullanılabilirlik.

### 6.2 Shard key
| Aday | Toplam veri | Son 30 günün yazmaları |
|---|---|---|
| `musteri_id` HASH, 4 shard | ~495k × 4 | ~20k × 4 |
| `olusturma` RANGE, 4 shard | ~495k × 4 | 0 / 0 / 0 / **82.612** |

Tek makinede en iyi partition anahtarı olan tarih, çok makinede sıcak nokta yaratıyor.

### 6.3 postgres_fdw ile elle sharding
| Deney | Süre |
|---|---|
| 20k satır INSERT, `batch_size` 1 → 1000 | 5.626 → 225 ms |
| Tek müşteri (tek shard, filtre pushdown) | 11 ms (yerelde 0,07 ms) |
| Scatter-gather `count/sum`: varsayılan → partition-wise → async | 535 → 353 → 216 ms |
| Shard key ile `GROUP BY` (toplama shard'a gitti) | 1.120 ms; aynı sorgu shard'da doğrudan 120 ms |

Son satırdaki fark açık bırakıldı: koordinatör üzerinden gelen sorgu shard'da farklı çalışıyor. Sonraki adım `auto_explain`.

## Temel dersler

1. Maliyet okunan **sayfa** sayısıdır; WHERE filtresi okumayı azaltmaz, indeks azaltır.
2. Kolonu fonksiyona sarmak hem indeksi hem partition pruning'i öldürür.
3. Her indeks, her partition, her shard bir takastır; bir sorgu tipini hızlandırırken diğerini yavaşlatır.
4. Partitioning'in asıl süper gücü sorgu hızı değil, veriyi anında silebilmek.
5. Taşıma sonrası gerçek bir INSERT ile test et.
6. Dağıtık sistemlerde maliyeti gidiş-dönüş sayısı belirler.
7. Rakamlar mantıksız görünüyorsa ilk soru: "doğru veritabanında mıyım?"
