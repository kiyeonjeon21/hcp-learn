# 05. HCP IAM과 Workload Identity Federation

[← 목차](./)

HCP IAM은 조직(org) → 프로젝트(project) 단위로 역할을 붙인다.
사람 사용자, 그룹, 서비스 프린시펄(SP)이 principal이 될 수 있다.

## 역할 목록

`hcp iam roles list`로 본 역할 중 눈에 띄는 것들:

| 역할 | 용도 |
| --- | --- |
| `roles/admin`, `roles/contributor`, `roles/viewer` | 기본 3단계 |
| `roles/resource-manager.browser` | 리소스 목록만 보기 |
| `roles/resource-manager.project-iam-policies-admin` | 프로젝트 IAM 정책만 관리 |
| `roles/billing.billing-admin` | 결제 |
| `roles/vault-radar.*` (agent, cli-user, developer, resource-contributor 등 7개) | Vault Radar 전용 |
| `roles/infragraph.*` | Infragraph 전용 |

서비스별 세분화 역할은 Vault Radar와 Infragraph에만 있었다.

## Contributor로는 SP를 못 만든다

자동화용 `hcp-learn-sp`는 프로젝트 Contributor다.
이 SP로 로그인한 CLI에서 새 SP를 만들려 하니 막혔다.

```
ServicePrincipalsService_CreateServicePrincipal default {"code":7,"message":"permission denied"}
```

IAM 변경은 Admin 몫이다.
Contributor가 자기보다 강한 신원을 찍어낼 수 없게 하는 당연한 설계다.

**삽질 하나 더**: `hcp auth login --cred-file=...`로 SP 로그인을 한 번 하면, 그 뒤 `hcp auth login`을 그냥 실행해도 캐시된 SP 자격 증명으로 조용히 로그인된다.
사용자로 돌아가려면 `hcp auth logout`을 먼저 해야 한다.
지금 누구인지는 토큰을 까 보면 바로 보인다.

```bash
hcp auth print-access-token | cut -d. -f2 | base64 -d | jq '{sub, gty}'
# SP면 gty=client-credentials, sub=<sp>@<project>
```

## Workload Identity Federation: 시크릿 없는 CI

GitHub Actions가 HCP에 접근할 때 SP 키를 GitHub Secrets에 넣는 대신, GitHub이 발급하는 OIDC 토큰을 HCP 토큰으로 교환한다.

### 1. 최소 권한 SP + OIDC provider

```bash
hcp iam service-principals create gha-viewer
hcp projects iam add-binding --member=<gha-viewer id> --role=roles/viewer

hcp iam workload-identity-providers create-oidc github-hcp-learn \
  --service-principal=iam/project/<PROJECT>/service-principal/gha-viewer \
  --issuer=https://token.actions.githubusercontent.com \
  --conditional-access='jwt_claims.repository == "kiyeonjeon21/hcp-learn" and jwt_claims.ref == "refs/heads/main"'
```

`--conditional-access`는 go-bexpr 식이고 GitHub OIDC 토큰의 클레임을 `jwt_claims.<name>`으로 쓸 수 있다.
여기서는 "이 저장소의 main 브랜치"만 허용했다.
audience를 따로 안 주면 provider의 resource name이 기본 audience가 된다.

### 2. 자격 증명 파일 (시크릿 아님)

```bash
hcp iam workload-identity-providers create-cred-file \
  iam/project/<PROJECT>/service-principal/gha-viewer/workload-identity-provider/github-hcp-learn \
  --source-env=GH_OIDC_TOKEN --output-file=hcp/gha-wif-cred.json
```

```json
{
  "scheme": "workload",
  "workload": {
    "provider_resource_name": "iam/project/.../workload-identity-provider/github-hcp-learn",
    "env": { "var": "GH_OIDC_TOKEN" }
  }
}
```

"어디서 외부 토큰을 읽어서 어느 provider에 교환할지"만 적혀 있다.
그래서 저장소에 그대로 커밋했다.

### 3. 워크플로

[`.github/workflows/hcp-wif.yml`](https://github.com/kiyeonjeon21/hcp-learn/blob/main/.github/workflows/hcp-wif.yml) 핵심:

```yaml
permissions:
  id-token: write

steps:
  - name: Get GitHub OIDC token (audience = WIF provider resource name)
    run: |
      tok=$(curl -sSf -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
        "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=$WIP" | jq -r .value)
      echo "::add-mask::$tok"
      echo "GH_OIDC_TOKEN=$tok" >> "$GITHUB_ENV"
  - run: hcp auth login --cred-file=hcp/gha-wif-cred.json
```

### 결과

main 브랜치 실행:

```
Successfully logged in!
{ "sub": "gha-viewer-...@<project>" }
{ "channel": "production", "version": "v2", "image": "sha256:a1ae15f3..." }   # Packer 채널 읽기 성공
{"code":7,"message":"Not Authorized"}                                          # 채널 생성은 Viewer라 거부
```

다른 브랜치(`wif-negative-test`)에서 같은 워크플로를 돌리면 교환 단계에서 바로 막힌다.

```
exchange token status code 400: {"error":"token did not pass conditional_access evaluation"}
```

GitHub 쪽에 HCP 시크릿이 하나도 없고, 권한은 저장소/브랜치 단위로 HCP가 판단한다.

### 워크플로 작성 중 실수 두 개

- 처음에 `jq -r .project_id`로 cred file에서 프로젝트 ID를 읽었는데, workload cred file에는 `project_id`가 없다.
  provider resource name에서 잘라 썼다.
- `unzip hcp_*.zip hcp`가 저장소의 `hcp/` 디렉터리와 이름이 겹쳐서 "replace hcp?" 프롬프트에 걸려 실패했다.
  `$RUNNER_TEMP`에 받아서 `/usr/local/bin`에 바로 풀었다.

## 서비스 전용 역할: Vault Radar CLI

Contributor SP로 `vault-radar scan`을 돌리면 403이 난다.

```
http POST .../2023-05-01/vault-radar/projects/<PROJECT>/api/resources returned code: 403
```

Contributor라도 Radar API는 별도 역할이 필요하다.
`roles/vault-radar.cli-user`만 가진 `radar-cli` SP를 따로 만들어 해결했다.
(자세한 건 Vault Radar 편)
