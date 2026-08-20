# ORBITALFREIGHT — app do condutor (Flutter)

Cliente multiplataforma que substitui progressivamente o `apps/driver-ios/`. Faz quatro coisas:
mostra as atribuições do condutor, mostra a rota, regista leituras e comprovativos de entrega, e
mantém tudo isso a funcionar sem rede.

## Com que serviços fala

Só com estes, e só pelos caminhos de §3 do `SPEC.md`:

| Serviço | O que a app lhe pede |
|---|---|
| identity-service | `POST /v1/auth/token`, `/refresh`, `/revoke`, `GET /v1/users/{user_id}/effective-roles` |
| fleet-service | `GET /v1/assignments`, `GET /v1/vehicles/{vehicle_id}`, `GET /v1/drivers/{driver_id}/availability`, `POST /v1/drivers/{driver_id}/hours-of-service` |
| container-registry | `GET /v1/shipments/{shipment_id}`, `POST /v1/containers/{container_id}/scans`, `PATCH /v1/shipments/{shipment_id}/status` |
| routing-service | `GET /v1/shipments/{shipment_id}/route`, `GET /v1/routes/{route_id}`, `POST /v1/eta/batch` |
| document-service | `POST /v1/documents`, `GET /v1/documents` |
| notification-service | `PUT /v1/users/{user_id}/preferences` |

Não fala com geo-service nem com audit-ledger: são folhas internas do cluster (§1.2) e o que
precisamos deles chega-nos pela mão de outro serviço. Também não fala com telemetry-ingest — os
pontos de GPS que a app recolhe são para uso local e não são telemetria.

## O modelo offline

Tudo o que muda estado passa por `local_outbox`, escrito na mesma transação SQLite que o estado
local. O `SyncEngine` drena essa fila; cada linha leva sempre a mesma `X-OF-Idempotency-Key` com
que nasceu, o que torna a retentativa inofensiva (§7 regra 5).

O caso não trivial é o comprovativo de entrega, que são três linhas encadeadas por `depends_on`:

```
leitura proof_of_delivery ──▶ assinatura (owner_type='scan') ──▶ PATCH status=delivered
```

A ordem é obrigatória: o document-service confirma o `owner_id` junto do container-registry antes
de aceitar o ficheiro, e o billing-service só desbloqueia a faturação quando vê o
`shipment.scanned` com `scan_type = 'proof_of_delivery'`.

## Notificações

Consumimos por push, através do notification-service, cinco eventos de §4:
`fleet.assignment.created`, `fleet.assignment.released`, `shipment.status.changed`,
`telemetry.alert.raised` e `route.replanned`. A deduplicação é feita no `event_id`, como manda a
regra 1 de §4.19.

## Compilar

As chaves de compilação usam o prefixo `DRIVER_`, exceto `OF_ENVIRONMENT` e `OF_REGION_CODE`, que
mantêm a grafia de §5 porque são carimbadas nos relatórios de diagnóstico:

```
flutter build apk --release \
  --dart-define=OF_ENVIRONMENT=production \
  --dart-define=OF_REGION_CODE=eu-west \
  --dart-define=DRIVER_API_BASE_URL=https://mobile.orbitalfreight.example
```
