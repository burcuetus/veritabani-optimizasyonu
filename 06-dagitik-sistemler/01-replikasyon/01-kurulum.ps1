# ============================================================
# Adım 6.1 — Streaming replikasyon kurulumu (PowerShell)
# ============================================================
#   pgperf (primary, localhost:5433)  --WAL-->  pgreplica (replica, localhost:5435)
#
# Önce 02-primary-hazirlik.sql'deki SQL adımlarını çalıştırın
# (replikasyon kullanıcısı). Sıra: 1 -> SQL -> 2 -> 3 -> 4.
#
# NOT: <REPL_PAROLA> yerine 02-primary-hazirlik.sql'de verdiğiniz parolayı yazın. Gerçek ortamda
#      güçlü parola + secret manager kullanılır.

# --- 1) Ortak Docker ağı: container'lar birbirini isimle bulsun
#        (pgperf yeniden başlatılmaz, bağlantılar kopmaz)
docker network create pglab
docker network connect pglab pgperf

# --- 2) pg_hba.conf: replikasyon bağlantısına izin
#        >> = sona ekle ( > dosyayı silip üzerine yazardı!)
docker exec pgperf bash -c "echo 'host replication replikator samenet scram-sha-256' >> /var/lib/postgresql/data/pg_hba.conf"
#        Ardından SQL tarafında: pg_hba_file_rules ile kontrol + pg_reload_conf()

# --- 3) Temel kopya (base backup)
#   -X stream : kopya sırasında oluşan WAL'ı da çeker (tutarlı kopya)
#   -R        : standby.signal + primary_conninfo yazar (kopya replica olarak açılır)
#   postgres:17 : ana sürüm primary ile aynı olmak ZORUNDA
docker volume create pgreplica_data
docker run --rm --network pglab -v pgreplica_data:/var/lib/postgresql/data -e PGPASSWORD=<REPL_PAROLA> postgres:17 pg_basebackup -h pgperf -U replikator -D /var/lib/postgresql/data -R -X stream -P
# Sonuç: ~1,2 GB, "waiting for checkpoint" ile başladı

# --- 4) Replica'yı başlat
docker run -d --name pgreplica --network pglab -p 5435:5432 -v pgreplica_data:/var/lib/postgresql/data postgres:17
docker logs pgreplica
# Beklenen log satırları:
#   Skipping initialization
#   database system was interrupted        (normal: canlı sunucudan kopya)
#   entering standby mode
#   consistent recovery state reached
#   database system is ready to accept read-only connections
#   started streaming WAL from primary

# --- Replica'ya terminalden bağlanmak
#   docker exec -it pgreplica psql -U postgres -d perflab

# --- Kaldırmak
#   docker rm -f pgreplica
#   docker volume rm pgreplica_data
#   docker network disconnect pglab pgperf
#   docker network rm pglab
