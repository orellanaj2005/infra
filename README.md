# infra

Archivos Docker Compose de RutaExpress, uno por instancia EC2.

| Carpeta | Instancia | Contenido |
|---|---|---|
| `apps/` | ec2-apps | Microservicios, frontend y Oracle |
| `mq/` | ec2-mq | Clúster RabbitMQ de 2 nodos |
| `kafka/` | ec2-kafka | 3 Zookeeper, 3 brokers Kafka y kafka-ui |
| `local/` | PC de desarrollo | Todo lo anterior en un solo proyecto, para validar antes de desplegar |

## Entorno local

`local/compose.yml` levanta Oracle, el clúster RabbitMQ (mismo `mq/rabbitmq.conf`), Kafka y los 8
microservicios compilados desde los repositorios hermanos (`../../ms-rutaexpress-*`). Necesita
unos 10 GB de RAM libres para Docker.

### Levantar

```bash
cd local
cp .env.example .env      # completar TENANT_ID y API_CLIENT_ID
docker compose up -d --build
docker compose exec rabbit1 rabbitmqctl set_policy ha-cmd "^q\." '{"ha-mode":"all","ha-sync-mode":"automatic"}'
docker compose ps         # todos "Up"; oracle-db y rabbit1/2 "healthy"
```

Datos de ejemplo (opcional, una vez que shipments, catalog, audit y report arrancaron):

```bash
cd ../../ms-rutaexpress-db
docker compose -f ../infra/local/compose.yml exec -T oracle-db sqlplus -s catalog/catalog@//localhost:1521/XEPDB1 < seed/01_catalog_seed.sql
docker compose -f ../infra/local/compose.yml exec -T oracle-db sqlplus -s rutaexpress/rutaexpress@//localhost:1521/XEPDB1 < seed/02_shipments_seed.sql
docker compose -f ../infra/local/compose.yml exec -T oracle-db sqlplus -s audit_user/changeit@//localhost:1521/XEPDB1 < seed/03_audit_seed.sql
docker compose -f ../infra/local/compose.yml exec -T oracle-db sqlplus -s report_user/changeit@//localhost:1521/XEPDB1 < seed/04_report_seed.sql
```

Frontend: `cd frontend-rutaexpress && npm run dev` (http://localhost:5173). Se corre con Vite y no
en contenedor porque la URI de retorno registrada en Entra ID para local es `http://localhost:5173`.

| Servicio | Dirección |
|---|---|
| BFF | http://localhost:8080 |
| Panel RabbitMQ | http://localhost:15672 y :15673 (guest / guest) |
| kafka-ui | http://localhost:8090 |
| Oracle | Solo dentro de la red: `docker compose exec oracle-db sqlplus ...` (servicio XEPDB1) |

### Probar el flujo completo

1. **Compilar y probar**: `./mvnw verify` en cada microservicio.
2. **Comandos**: en el frontend (rol Admin) llevar un envío de EN_BODEGA a EN_RUTA. En los logs de
   notify (`docker compose logs notify-svc`) deben aparecer el correo y la etiqueta PDF.
3. **DLQ**: publicar un mensaje inválido y comprobar que llega a `q.cmd.email.dlq` y que audit deja
   un log ERROR y una fila en `DEAD_LETTER_EVENT`:
   ```bash
   curl -s -u guest:guest -H "content-type: application/json" -X POST \
     http://localhost:15672/api/exchanges/%2F/cmd.direct/publish \
     -d '{"properties":{},"routing_key":"email.send","payload":"no es json","payload_encoding":"string"}'
   ```
4. **Caída de un nodo**: `docker compose stop rabbit1`, cambiar el estado de otro envío y comprobar
   que notify lo procesa conectado a rabbit2. Después `docker compose start rabbit1`.
5. **Administrador**: desde la pantalla RabbitMQ del frontend, crear y eliminar una cola, un
   exchange y un binding de prueba.

## Clúster RabbitMQ (ec2-mq)

Dos nodos (`rabbit1` y `rabbit2`) que forman el clúster automáticamente
mediante `rabbitmq.conf` (`classic_config`). AMQP en 5672 y 5673, panel en 15672.

### Primer arranque o reconstrucción

```bash
cd mq
docker compose down -v      # borra los datos: solo en el primer arranque o para reconstruir
docker compose up -d
docker compose ps           # esperar a que ambos queden "healthy"
```

### Verificar el clúster

```bash
docker compose exec rabbit1 rabbitmqctl cluster_status
```

En **Running Nodes** deben aparecer `rabbit@rabbit1` y `rabbit@rabbit2`.

### Política de réplica (una sola vez tras crear el clúster)

```bash
docker compose exec rabbit1 rabbitmqctl set_policy ha-cmd "^q\." '{"ha-mode":"all","ha-sync-mode":"automatic"}'
```

### Unir rabbit2 a mano (si no aparece en el clúster)

```bash
docker compose exec rabbit2 rabbitmqctl stop_app
docker compose exec rabbit2 rabbitmqctl reset
docker compose exec rabbit2 rabbitmqctl join_cluster rabbit@rabbit1
docker compose exec rabbit2 rabbitmqctl start_app
```

### Conexión desde los microservicios

```properties
RABBITMQ_ADDRESSES=172.31.16.17:5672,172.31.16.17:5673
```

Si un nodo cae, los servicios se reconectan al otro.

## Kafka (ec2-kafka)

Cada broker tiene dos listeners:

| Listener | Dirección | Uso |
|---|---|---|
| INTERNAL | `kafkaN:29092` | Entre brokers y kafka-ui |
| EXTERNAL | `172.31.80.112:9092/9093/9094` | Desde ec2-apps |

```bash
docker network create rutaexpress-shared 2>/dev/null
cd kafka
docker compose up -d
```

En local, definir `KAFKA_EXTERNAL_HOST=localhost`. kafka-ui queda en el puerto 8090.

```properties
KAFKA_BOOTSTRAP_SERVERS=172.31.80.112:9092,172.31.80.112:9093,172.31.80.112:9094
```