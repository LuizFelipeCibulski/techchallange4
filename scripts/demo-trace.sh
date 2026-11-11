#!/usr/bin/env bash
# =====================================================================
# Demo de trace distribuído - UMA requisição que atravessa os 5 serviços
# ---------------------------------------------------------------------
# Cria uma flag NOVA (nome único) para garantir cache MISS no Redis do
# evaluation-service (o cache é por flag, 30 s). Com cache HIT o trace
# teria só evaluation + Redis; com MISS ele percorre tudo:
#
#   cliente -> Traefik -> evaluation-service  GET /evaluate      (SERVER)
#                          ├─ Redis GET                           (cache miss)
#                          ├─ targeting-service GET /rules/<flag> -> Postgres
#                          │     └─ auth-service GET /validate    -> Postgres
#                          ├─ flag-service GET /flags/<flag>      -> Postgres
#                          │     └─ auth-service GET /validate    -> Postgres
#                          ├─ Redis SET
#                          └─ SQS "evaluation publish"            (PRODUCER)
#                                └─ analytics-service "evaluation process" (CONSUMER)
#                                      └─ DynamoDB PutItem + SQS DeleteMessage
#
# Uso:
#   ./scripts/demo-trace.sh                 # flag demo-<hora>, usuário "apresentacao"
#   FLAG=minha-flag USUARIO=prof ./scripts/demo-trace.sh
# =====================================================================
set -euo pipefail

FLAG="${FLAG:-demo-$(date +%H%M%S)}"
USUARIO="${USUARIO:-apresentacao}"
URL="${URL:-https://$(kubectl get svc -n traefik traefik -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')}"
KEY="${SERVICE_API_KEY:-$(kubectl get secret -n evaluation-service evaluation-secrets -o jsonpath='{.data.SERVICE_API_KEY}' | base64 -d)}"
[ -z "$KEY" ] && { echo "Não achei a SERVICE_API_KEY (Secret evaluation-secrets)."; exit 1; }

azul() { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }

azul "1/4 Preparando a flag '$FLAG' (100% dos usuários)"
curl -sk -o /dev/null -w "  flag-service   POST /flags  -> %{http_code}\n" -X POST "$URL/flags/flags" \
  -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d "{\"name\":\"$FLAG\",\"description\":\"Demo de trace distribuído\",\"is_enabled\":true}"
curl -sk -o /dev/null -w "  targeting      POST /rules  -> %{http_code}\n" -X POST "$URL/target/rules" \
  -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d "{\"flag_name\":\"$FLAG\",\"is_enabled\":true,\"rules\":{\"type\":\"PERCENTAGE\",\"value\":100}}"

ANALYTICS=$(kubectl get deploy -n analytics-service analytics-service -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
if [ -z "$ANALYTICS" ] || [ "$ANALYTICS" = 0 ]; then
  echo "  ⚠ analytics-service está em 0 réplicas (KEDA scale-to-zero). O span CONSUMER"
  echo "    vai entrar no trace ~1 min depois, quando o KEDA subir o pod pela fila."
fi

azul "2/4 A requisição da demo"
echo "  curl -sk \"$URL/evaluation/evaluate?user_id=$USUARIO&flag_name=$FLAG\""
INICIO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
curl -sk -w "\n  HTTP %{http_code} em %{time_total}s\n" "$URL/evaluation/evaluate?user_id=$USUARIO&flag_name=$FLAG"

azul "3/4 trace_id (do log do evaluation-service)"
TRACE=""
for _ in 1 2 3 4 5; do
  TRACE=$(kubectl logs -n evaluation-service -l app=evaluation-service --since-time="$INICIO" --tail=-1 2>/dev/null \
          | grep "Cache MISS para flag '$FLAG'" | grep -oE 'trace_id=[0-9a-f]{32}' | head -1 | cut -d= -f2 || true)
  [ -n "$TRACE" ] && break; sleep 2
done
if [ -n "$TRACE" ]; then
  echo "  trace_id = $TRACE"
else
  echo "  (não achei no log - use a busca por flag no New Relic, abaixo)"
fi

azul "4/4 Onde mostrar"
cat <<EOF
  New Relic → APM & Services → Distributed tracing, e no campo de busca:
      feature_flag.key = '$FLAG'
${TRACE:+  ou, direto pelo ID:
      trace.id = '$TRACE'
}
  New Relic → Query your data (NRQL), lista de spans na ordem:
      SELECT entity.name, name, duration.ms, span.kind FROM Span
      WHERE trace.id = '${TRACE:-<trace_id>}' SINCE 30 minutes ago LIMIT 100

  Grafana → Explore → Loki (logs do mesmo trace, correlação log ↔ trace):
      {k8s_namespace_name=~".+-service"} |= "${TRACE:-<trace_id>}"

  Dica: os spans levam ~30-60 s para aparecer no New Relic (batch do Collector).
EOF
