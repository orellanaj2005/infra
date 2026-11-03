#!/usr/bin/env bash
# Crea los tópicos de RutaExpress según la tabla 3.3 del plan de trabajo Kafka.
#
# Es idempotente:
#   - kafka-topics --create --if-not-exists no falla si el tópico ya existe.
#   - kafka-configs --alter vuelve a aplicar retención, cleanup.policy y
#     min.insync.replicas, así un tópico que ya existía queda igual a la tabla.
#
# Uso:
#   - Automático: servicio kafka-init de ../compose.yml.
#   - Manual:     BOOTSTRAP_SERVERS=kafka1:29092 bash create-topics.sh
#                 (o con docker compose run --rm kafka-init)
set -euo pipefail

BOOTSTRAP="${BOOTSTRAP_SERVERS:-kafka1:29092,kafka2:29092,kafka3:29092}"
# En las imágenes de Confluent el comando no lleva .sh; en la distribución de Apache sí.
KAFKA_TOPICS="${KAFKA_TOPICS_CMD:-kafka-topics}"
KAFKA_CONFIGS="${KAFKA_CONFIGS_CMD:-kafka-configs}"
EXPECTED_BROKERS="${EXPECTED_BROKERS:-3}"

PARTITIONS=3
REPLICAS=3
MIN_ISR=2

DAY_MS=86400000
RET_7_DAYS=$((7 * DAY_MS))     # 604800000
RET_14_DAYS=$((14 * DAY_MS))   # 1209600000
RET_30_DAYS=$((30 * DAY_MS))   # 2592000000

log() { echo "[create-topics] $*"; }

# Espera a que los 3 brokers estén registrados; con menos, un tópico de 3 réplicas no se puede crear.
wait_for_brokers() {
  local attempt=1 max_attempts=30 count
  while (( attempt <= max_attempts )); do
    count=$(kafka-broker-api-versions --bootstrap-server "$BOOTSTRAP" 2>/dev/null | grep -c '(id:' || true)
    if (( count >= EXPECTED_BROKERS )); then
      log "Brokers disponibles: $count"
      return 0
    fi
    log "Esperando brokers ($count/$EXPECTED_BROKERS), intento $attempt/$max_attempts..."
    sleep 5
    attempt=$((attempt + 1))
  done
  log "ERROR: no se encontraron $EXPECTED_BROKERS brokers en $BOOTSTRAP"
  exit 1
}

# create_topic <nombre> <cleanup.policy> <retention.ms>
create_topic() {
  local name="$1" policy="$2" retention="$3"

  log "Creando $name (particiones=$PARTITIONS, réplicas=$REPLICAS, cleanup.policy=$policy, retention.ms=$retention)"
  "$KAFKA_TOPICS" --bootstrap-server "$BOOTSTRAP" --create --if-not-exists \
    --topic "$name" \
    --partitions "$PARTITIONS" \
    --replication-factor "$REPLICAS" \
    --config "cleanup.policy=$policy" \
    --config "retention.ms=$retention" \
    --config "min.insync.replicas=$MIN_ISR"

  # Si el tópico ya existía, se alinea su configuración con la tabla.
  # kafka-configs exige corchetes para valores con coma (compact,delete).
  "$KAFKA_CONFIGS" --bootstrap-server "$BOOTSTRAP" --alter \
    --entity-type topics --entity-name "$name" \
    --add-config "cleanup.policy=[$policy],retention.ms=$retention,min.insync.replicas=$MIN_ISR"
}

wait_for_brokers

# Tópico               cleanup.policy   retención
create_topic shipments.events delete         "$RET_7_DAYS"
create_topic audit.timeline   compact,delete "$RET_30_DAYS"
create_topic notify.DLT       delete         "$RET_14_DAYS"
create_topic audit.DLT        delete         "$RET_14_DAYS"
create_topic report.DLT       delete         "$RET_14_DAYS"

log "Tópicos actuales:"
"$KAFKA_TOPICS" --bootstrap-server "$BOOTSTRAP" --describe \
  --topic 'shipments.events|audit.timeline|notify.DLT|audit.DLT|report.DLT'

log "Listo."
