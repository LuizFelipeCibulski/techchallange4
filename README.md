# ToggleMaster — Tech Challenge Fase 4 (POSTECH DevOps e Arquitetura Cloud)

Repositório da Fase 4, separado do monorepo de estudos
[`DEVOPS-ARQCLOUD`](https://github.com/LuizFelipeCibulski/DEVOPS-ARQCLOUD) com o histórico de commits preservado.

## Documentação

- [`FASE4.md`](FASE4.md) — o que a fase 4 entrega (observabilidade e resposta ativa)
- [`TUTORIAL.md`](TUTORIAL.md) — passo a passo para replicar
- [`RUNBOOK.md`](RUNBOOK.md) — resposta a incidentes
- [`ARQUITETURA.md`](ARQUITETURA.md) — arquitetura e configuração completa
- [`FLUXO.md`](FLUXO.md) — fluxo operacional (push, bootstrap, depuração)
- [`.github/workflows/README.md`](.github/workflows/README.md) — pipelines de CI/CD
- [`iac/README.md`](iac/README.md) — infraestrutura (Terraform/OpenTofu)

## Estrutura

```
docker/       código e Dockerfile dos microsserviços
kubernetes/   manifests (aplicados pelo Argo CD)
iac/          Terraform/OpenTofu da infraestrutura AWS
scripts/      tráfego, caos e geração de dashboard
.github/      pipelines do GitHub Actions
```
