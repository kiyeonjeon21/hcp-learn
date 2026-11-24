# 07. Waypoint, Infragraph, HVN: Terraform과 AWS에 묶인 것들

[← 목차](./)

## Waypoint

포털 Waypoint 메뉴를 누르면 바로 활성화(activate) 화면이 나온다.
상단 배너:

> Waypoint capabilities are transitioning to Terraform Developer Portal.

활성화 조건:

- HCP Terraform **team token** (모든 워크스페이스 관리 권한)
- HCP Terraform 조직 이름

Waypoint 템플릿은 HCP Terraform private registry의 no-code 모듈 위에 만들어진다.
즉 Waypoint는 독립 서비스라기보다 HCP Terraform 위의 셀프서비스 레이어이고, 그마저 "Terraform Developer Portal"로 흡수되는 중이다.
[03편](03-terraform-account.md)에서 HCP Terraform 조직을 만들지 못해 여기서 멈췄다.

## Infragraph (Beta)

프로젝트 대시보드의 "Go to Infragraph"는 조직 단위 활성화 화면으로 간다.

> Verify your Terraform plan — Infragraph is included with Terraform Standard and Premium tiers.

- HCP Terraform **Standard 이상** 플랜과 team token이 필요하다.
- 활성화하면 클라우드와 HashiCorp 도구에서 데이터를 받아 인프라 리스크를 그래프로 보여 준다고 한다.
- IAM에는 이미 `roles/infragraph.infragraph-admin`, `roles/infragraph.infragraph-connection-admin` 역할이 있다.

Free 조직조차 못 만든 상태라 여기도 진행 불가.

## HVN (HashiCorp Virtual Network)

HCP 관리형 클러스터(Vault Dedicated 등)가 사는 HCP 쪽 VPC다.

| 항목 | 값 |
| --- | --- |
| ID | `hvn` |
| Provider / Region | AWS / ca-central-1 |
| CIDR | 172.25.16.0/20 |
| 상태 | Stable |
| 연결 | 없음 |

- "Create connection"으로 AWS VPC peering 또는 Transit Gateway 연결을 만든다.
- 연결이 있어야 Vault의 **private** 엔드포인트를 내 VPC에서 쓸 수 있다.
- 지금 Vault 클러스터는 public 엔드포인트를 켜 둬서 연결 없이도 노트북에서 접근했다.
- CIDR은 내 VPC와 겹치면 안 된다.
  HVN을 만들 때 정하고 바꿀 수 없으니 처음에 잘 골라야 한다.

## 정리: HCP 서비스 의존 관계

```
HCP Terraform ─┬─ Waypoint (→ Terraform Developer Portal)
               ├─ Infragraph (Standard+)
               └─ Packer 채널 소비 (hcp_packer_artifact)

HVN ─── Vault Dedicated (private 엔드포인트, peering/TGW)

독립: Packer 레지스트리, Boundary, Vault Radar, IAM
```

HCP 포털 안에 있어도 Terraform 계열은 `app.terraform.io`라는 별개 시스템과 계정에 의존한다는 게 이번에 가장 크게 체감한 점이다.
