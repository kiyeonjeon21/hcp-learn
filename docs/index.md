# HCP Learn

HashiCorp Cloud Platform(HCP)의 서비스를 처음부터 끝까지 직접 써보면서 남기는 기록이다.
형식 없이, 진행 순서대로 적는다.

## 환경

- HCP 조직 1개, 프로젝트 `default-project` 1개.
- Trial 결제 모델 (약 $500 크레딧, 결제수단 미등록).
- 로컬: macOS (Apple Silicon), Terraform, Vault, Packer, Boundary, `hcp` CLI.
- 문서에서 org/project ID, 클러스터 주소, 시크릿은 모두 가렸다.

## 기록

1. [시작: 포털 둘러보기, 계정 상태, CLI 준비](00-portal.md)
2. [Vault Dedicated](01-vault-dedicated.md)
3. [HCP Packer](02-packer.md)
