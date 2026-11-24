# 00. 시작: 포털 둘러보기, 계정 상태, CLI 준비

[← 목차](./)

## 포털 첫인상

`portal.cloud.hashicorp.com`에 로그인하면 조직(org) → 프로젝트(project) 계층으로 들어간다.
조직이 결제와 IAM의 최상위 단위이고, 프로젝트는 리소스를 묶는 단위다.
처음 만든 조직에는 `default-project`가 자동으로 있다.

왼쪽 사이드바에 보이는 서비스 목록 (2026-11 기준):

- Boundary
- Packer
- Terraform
- Vagrant Registry
- Vault Dedicated
- Vault Radar (Trial 배지)
- Waypoint
- 그 외: Infragraph (Beta), Access control (IAM), HashiCorp Virtual Networks (HVN), Project settings

Consul Dedicated는 이미 사이드바에서 사라졌다.
예전에 있던 Vault Secrets도 메뉴에는 없고, `hcp` CLI에 `vault-secrets` 명령만 남아 있다.

## 결제 상태

조직 billing summary에서 확인한 내용:

- 결제 모델: **Trial**, 남은 크레딧 약 $490 (시작 $500).
- 결제수단을 등록하지 않으면 trial이 끝날 때 리소스가 사라진다.
- 이번 달 사용액은 이미 띄워져 있던 Vault Dedicated 클러스터 비용뿐이었다.

포털 URL을 짐작해서 들어가려 하면 404가 자주 난다.
billing은 `/billing/accounts/default-account/summary/...`처럼 org 경로 밖에 있고,
서비스 페이지는 `/services/<서비스>?project_id=...` 형태다.
사이드바 링크를 따라가는 게 낫다.

## 이미 있던 리소스

"Active resources" 페이지에 두 개가 있었다.

| 리소스 | 종류 | 위치 |
| --- | --- | --- |
| `hvn` | HashiCorp Virtual Network | AWS ca-central-1 |
| `vault-cluster` | Vault Dedicated (Development, Extra Small) | AWS ca-central-1 |

## CLI 설치

Homebrew가 Xcode Command Line Tools 문제로 막혀서, `releases.hashicorp.com`에서 바이너리를 직접 받았다.
`*_SHA256SUMS`로 체크섬을 검증한 뒤 `~/.local/bin`에 풀었다.

```bash
for p in vault packer boundary hcp; do
  v=$(curl -s https://api.releases.hashicorp.com/v1/releases/$p/latest | jq -r .version)
  f=${p}_${v}_darwin_arm64.zip
  curl -sSLO https://releases.hashicorp.com/$p/$v/$f
  curl -sSL https://releases.hashicorp.com/$p/$v/${p}_${v}_SHA256SUMS | grep " $f$" | shasum -a 256 -c -
  unzip -oq $f $p -d ~/.local/bin
done
```

받은 버전: vault 2.2.2, packer 1.16.2, boundary 0.21.3, hcp 0.11.0. Terraform은 1.11.0이 이미 있었다.

## `hcp` CLI 로그인과 서비스 프린시펄

```bash
hcp auth login                         # 브라우저 OAuth, 이미 포털에 로그인돼 있으면 바로 끝난다
hcp profile set organization_id <ORG_ID>
hcp profile set project_id <PROJECT_ID>
```

`hcp` CLI 0.11의 명령 그룹은 `auth`, `iam`, `organizations`, `profile`, `projects`, `vault-secrets`, `waypoint`뿐이다.
Vault 클러스터나 Packer, Boundary는 CLI가 아니라 API나 Terraform provider로 다뤄야 한다.

자동화용으로 프로젝트 범위 서비스 프린시펄(SP)을 만들었다.

```bash
hcp iam service-principals create hcp-learn-sp
hcp projects iam add-binding --member=<SP_ID> --role=roles/contributor
hcp iam service-principals keys create hcp-learn-sp --output-cred-file=secrets/sp-cred.json
```

**삽질 하나**: 처음에 `keys create ... --format=json`으로 결과를 받았는데, JSON 출력에는 `client_secret`이 빠져 있다.
시크릿은 생성 시점에만 볼 수 있으니 그 키는 버리고(`keys delete`) `--output-cred-file`로 다시 만들었다.
도움말에도 cred file 방식을 권장한다.
셸 히스토리나 터미널에 시크릿이 남지 않아서다.

cred file로 CLI를 SP 신원으로 바꿀 수도 있다.

```bash
hcp auth login --cred-file=secrets/sp-cred.json
hcp auth print-access-token   # HCP API 호출용 Bearer 토큰
```
