# Como executar a Fase 4 (do zero ao incidente auto-curado)

Roteiro operacional, na ordem. Todos os comandos rodam **a partir da raiz deste
repositório**. Para o porquê de cada peça, veja [`FASE4.md`](FASE4.md) e
[`TUTORIAL.md`](TUTORIAL.md).

```
0. Credenciais do Lab ──► 1. OpenTofu (infra) ──► 2. Tokens do monitoramento
        ──► 3. GitHub Actions (imagens no ECR) ──► 4. Traefik + Argo CD
        ──► 5. GitOps (root) ──► 6. Verificação ──► 7. Prova real
```

Tempo total: **~45 min**. A maior parte é o `tofu apply` (~20 min) e os pipelines (~10 min).

---

## 0. Pré-requisitos e credenciais do AWS Academy

Ferramentas: `aws`, `tofu` 1.11+, `kubectl`, `helm`, `gh` (logado), `jq`, `openssl`.
Contas: New Relic (Free, região **US**), PagerDuty (Free) e um servidor Discord seu.

1. No Learner Lab: **Start Lab** → espere a bolinha ficar verde → **AWS Details** →
   **AWS CLI: Show**.
2. Cole o bloco em `~/.aws/credentials` (substitui o anterior):

   ```ini
   [default]
   aws_access_key_id=ASIA...
   aws_secret_access_key=...
   aws_session_token=...
   ```

3. Confira a conta:

   ```bash
   aws sts get-caller-identity --query Account --output text
   ```

> ⚠️ **O resultado precisa ser `198518420325`**. Esse ID está fixo no backend
> (`iac/providers.tf`) e nos manifests (imagens do ECR, URL da fila SQS).
> Se a conta for outra, troque antes de seguir:
> ```bash
> NOVA=$(aws sts get-caller-identity --query Account --output text)
> grep -rl 198518420325 iac kubernetes | xargs sed -i "s/198518420325/$NOVA/g"
> git commit -am "chore: aponta para a conta $NOVA" && git push
> ```

As credenciais do Lab **expiram a cada sessão** (~4 h). Quando aparecer
`ExpiredToken`, repita os passos 1 e 2 (veja também a [seção 8](#8-voltando-numa-nova-sessão-do-lab)).

---

## 1. Infraestrutura com OpenTofu

```bash
cd iac
./bootstrap-backend.sh        # bucket S3 + tabela de lock do state (só na 1ª vez; se já existe, ele pula)
echo "public_access_cidrs = [\"$(curl -s https://checkip.amazonaws.com)/32\"]" > terraform.tfvars
tofu init
tofu plan                     # confira: ~60 recursos a criar
tofu apply                    # ~20 min, responda "yes"
aws eks update-kubeconfig --region us-east-1 --name togglemaster-prod
kubectl get nodes             # esperado: 3 nós Ready
cd ..
```

O apply cria a VPC, o EKS, os RDS, o Redis, o DynamoDB, a fila SQS, os 6 repositórios
ECR e os cofres do Secrets Manager. O cofre `togglemaster/prod/observability` é
criado **vazio de propósito** e é preenchido no próximo passo.

> O `terraform.tfvars` é ignorado pelo git (tem o seu IP). Se o seu IP mudar, o
> `kubectl` para de responder: gere o arquivo de novo e rode `tofu apply`.

---

## 2. Tokens do monitoramento (New Relic, PagerDuty, Discord)

Pegue os 3 valores:

| Serviço | Onde | O que copiar |
|---|---|---|
| **New Relic** | canto inferior esquerdo → *API Keys* | chave **INGEST - LICENSE** (40 caracteres, termina em `NRAL`). Não use a `NRAK-...`, que dá 403 |
| **PagerDuty** | *Services* → *New Service* "ToggleMaster" → *Integrations* → **Events API V2** | **Integration Key** (32 caracteres) |
| **Discord** | canal → ⚙️ *Editar canal* → *Integrações* → *Webhooks* → *Novo webhook* | **Copiar URL do webhook** |

Grave os três no Secrets Manager:

```bash
./scripts/set-observability-secrets.sh
```

- A entrada é oculta: o valor não aparece na tela nem no histórico.
- O script também gera a senha do Grafana e o token do self-healer.
- Agora ele termina com
  *"cluster ainda sem a stack de observabilidade - o ESO aplica quando ela subir"*.
  Isso é o esperado: o Argo ainda não subiu nada.
- Para trocar só um token depois, rode de novo: ENTER mantém o valor atual.

---

## 3. GitHub Actions: colocar as imagens no ECR

Os manifests apontam para imagens no ECR. Se os repositórios do ECR estão
vazios (conta nova ou depois de um `destroy`), os pods ficam em `ImagePullBackOff`.
Os pipelines constroem as imagens, publicam no ECR e commitam a tag nova nos manifests.

Confira se já existem imagens:

```bash
for s in auth-service flag-service targeting-service evaluation-service analytics-service self-healer; do
  printf "%-20s " $s; aws ecr describe-images --repository-name $s --query 'length(imageDetails)' --output text 2>/dev/null || echo "sem repo"
done
```

Se todos tiverem `> 0` e as tags dos manifests existirem, pule para o passo 4. Senão:

### 3.1 Configurar o repositório (uma vez)

```bash
REPO=LuizFelipeCibulski/techchallange4
./update-secrets-aws.sh ~/.aws/credentials     # 3 chaves do Lab + variável AWS_MODE=academy

# IP liberado no endpoint do EKS (o seu gh não tem "gh variable", por isso gh api)
gh api -X POST repos/$REPO/actions/variables -f name=EKS_PUBLIC_ACCESS_CIDRS \
  -f "value=[\"$(curl -s https://checkip.amazonaws.com)/32\"]"
```

No navegador, em **Settings** do repositório:
- **Actions → General → Workflow permissions** → *Read and write permissions* → Save.
  Sem isso, o passo de GitOps não consegue commitar a tag nova.
- **Environments → New environment** → `production` → *Required reviewers*: você.
  Isso é o gate de aprovação do `terraform.yml`.

### 3.2 Disparar os 6 pipelines

O `workflow_dispatch` (botão *Run workflow*) está comentado nos workflows.
Descomentar faz duas coisas:
- habilita o botão para as próximas vezes;
- já dispara os 6 pipelines, porque o próprio `.yml` está no `paths:` de cada um.

```bash
sed -i 's/^#  workflow_dispatch:/  workflow_dispatch:/' .github/workflows/{auth,flag,targeting,evaluation,analytics}-service.yml .github/workflows/self-healer.yml
git commit -am "ci: habilita workflow_dispatch nos pipelines dos serviços"
git push
```

Acompanhe com `gh run list -R $REPO` ou pela aba **Actions**. São ~10 min:
build → lint → SAST → SCA → Trivy → push ECR → commit da tag.
Quando terminarem, **traga os commits de tag** que o bot fez na `main`:

```bash
git pull
grep -h "image:" kubernetes/*/deployment.yaml kubernetes/self-healing/self-healer.yaml   # tags novas
```

> Algum pipeline falhou com `ExpiredToken`? Renove o `~/.aws/credentials` e rode
> `./update-secrets-aws.sh ~/.aws/credentials`. Depois use **Re-run failed jobs**.

---

## 4. Traefik e Argo CD

Estes não ficam no GitOps, porque quem gerencia o GitOps não é gerenciado por ele.

```bash
# Gateway API + Traefik (cria o Load Balancer público)
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.0/standard-install.yaml
helm repo add traefik https://traefik.github.io/charts && helm repo update
helm upgrade --install traefik traefik/traefik -n traefik --create-namespace \
  -f kubernetes/traefik/values.yaml --wait

# Argo CD servido em /argocd
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl patch configmap argocd-cmd-params-cm -n argocd --type merge -p '{"data":{"server.rootpath":"/argocd"}}'
kubectl rollout restart deployment argocd-server -n argocd
kubectl apply -f kubernetes/argocd/ingressroute.yaml

# metrics-server (sem ele o HPA fica "cpu: <unknown>")
kubectl apply -f kubernetes/metrics-server/deploment.yaml
```

---

## 5. GitOps: uma linha sobe tudo

```bash
kubectl apply -f kubernetes/argocd/apps/root.yaml
kubectl get applications -n argocd -w          # Ctrl+C quando estabilizar (~5-10 min)
```

O Argo lê **este repositório** (`repoURL: .../techchallange4`) e sobe em ondas:

| Onda | O que sobe |
|---|---|
| `-20` | External Secrets Operator, KEDA |
| `-10` | ClusterSecretStore (liga o ESO ao Secrets Manager) |
| `-8` | config da observabilidade (dashboard, alertas, contact points) |
| `-6` | Prometheus + Grafana, Loki |
| `-5` | OTel Collector (1 por nó) |
| `20` | auth-service |
| `30` | flag-service, targeting-service |
| `40` | evaluation-service, analytics-service |
| `50` | self-healer |

Quando os namespaces das apps existirem, aplique as rotas públicas:

```bash
kubectl apply -f kubernetes/traefik/middleware.yaml -f kubernetes/traefik/ingressroute.yaml
```

Os tokens do passo 2 chegam sozinhos: o ESO lê o cofre ao subir. Se você rodou o
`set-observability-secrets.sh` **depois** do Argo, o próprio script força a
sincronização e reinicia Grafana, Collector e self-healer.

---

## 6. Verificação e acessos

```bash
ELB=$(kubectl get svc -n traefik traefik -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "Grafana: https://$ELB/grafana    Argo CD: https://$ELB/argocd"

# Senhas
aws secretsmanager get-secret-value --secret-id togglemaster/prod/observability \
  --query SecretString --output text | jq -r .GRAFANA_ADMIN_PASSWORD        # Grafana, usuário admin
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d; echo                           # Argo CD, usuário admin
```

O certificado é autoassinado: aceite o aviso do navegador.

| Verificação | Comando | Esperado |
|---|---|---|
| Nós | `kubectl get nodes` | 3 Ready |
| Cofre | `kubectl get clustersecretstore` | `Valid / True` |
| Secrets | `kubectl get externalsecret -A` | todos `SecretSynced` |
| Argo CD | `kubectl get applications -n argocd` | 14 × Synced / Healthy |
| Observabilidade | `kubectl get pods -n observability` | `kps-*`, `loki-0`, `otel-collector-agent-*` (1 por nó) |
| Collector | `kubectl logs -n observability -l app.kubernetes.io/name=opentelemetry-collector --since=2m \| grep -c 'Exporting failed'` | `0` |
| Rotas | `curl -sk -o /dev/null -w '%{http_code}\n' https://$ELB/auth/health` | `200` (analytics: `503` = escalado a zero pelo KEDA, normal) |
| KEDA | `kubectl get hpa -n analytics-service` | `keda-hpa-sqs-scaledobject` |

No Grafana:
- **Dashboards → ToggleMaster → Saúde do Ecossistema** tem dados depois de gerar tráfego.
- **Alerting → Alert rules** mostra 3 regras, health OK.
- **Alerting → Contact points** → **Test** em cada um: a mensagem chega no Discord
  e abre um incidente no PagerDuty.

No New Relic: **APM & Services** mostra os 5 serviços alguns minutos depois do tráfego.

---

## 7. A prova real (o ciclo de incidente)

Use três terminais:

```bash
# terminal 1 - tráfego contínuo
./scripts/gerar-trafego.sh

# terminal 2 - ver o pod ser trocado
kubectl get pods -n auth-service -w

# terminal 3 - injetar a falha e ver a automação agir
./scripts/chaos.sh on 0.5          # 50% de HTTP 500 no auth-service
kubectl logs -n self-healing deploy/self-healer -f
```

Linha do tempo esperada (validada em 07/11: **4m18s** do início ao fim):

1. ~1 min com 5xx > 5% → alerta *Pending* → *Firing* no Grafana.
2. Incidente aberto no PagerDuty e mensagem no Discord.
3. O self-healer loga `SELF-HEALING` e faz `rollout restart`.
4. O pod novo nasce (terminal 2) e o Discord recebe "Rollout concluído".
5. 5xx volta a 0 → alerta *Normal* → incidente resolvido no PagerDuty.

Ao final: `./scripts/chaos.sh off`.
Se algo sair diferente, use o [`RUNBOOK.md`](RUNBOOK.md) e a Parte 14 do
[`TUTORIAL.md`](TUTORIAL.md) (os 8 problemas reais e como foram resolvidos).

---

## 8. Voltando numa nova sessão do Lab

O Lab desliga ao fim da sessão e as credenciais trocam. Ao voltar:

```bash
# 1. ~/.aws/credentials com as chaves novas (passo 0)
# 2. GitHub com as chaves novas
./update-secrets-aws.sh ~/.aws/credentials
# 3. kubeconfig (e IP, se mudou)
aws eks update-kubeconfig --region us-east-1 --name togglemaster-prod
kubectl get nodes || (cd iac && echo "public_access_cidrs = [\"$(curl -s https://checkip.amazonaws.com)/32\"]" > terraform.tfvars && tofu apply)
```

Se o IP mudou, atualize também a variável do CI:

```bash
gh api -X PATCH repos/LuizFelipeCibulski/techchallange4/actions/variables/EKS_PUBLIC_ACCESS_CIDRS \
  -f name=EKS_PUBLIC_ACCESS_CIDRS -f "value=[\"$(curl -s https://checkip.amazonaws.com)/32\"]"
```

---

## 9. Desligar tudo (economizar o crédito do Lab)

Siga a ordem. O Load Balancer do Traefik e as imagens do ECR não pertencem ao
state do OpenTofu e **travam o `destroy`** se ficarem:

```bash
kubectl delete -f kubernetes/argocd/apps/root.yaml     # o finalizer remove as apps filhas
helm uninstall traefik -n traefik                      # remove o Load Balancer
for s in auth-service flag-service targeting-service evaluation-service analytics-service self-healer; do
  ids=$(aws ecr list-images --repository-name $s --query 'imageIds[*]' --output json)
  [ "$ids" != "[]" ] && aws ecr batch-delete-image --repository-name $s --image-ids "$ids" >/dev/null
done
cd iac && tofu destroy
```

Os cofres do Secrets Manager usam `recovery_window_in_days = 0`, então o próximo
`apply` pode recriá-los com o mesmo nome logo em seguida. Os tokens precisam ser
gravados de novo (passo 2).
