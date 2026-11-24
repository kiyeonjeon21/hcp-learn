# 08. HCP Vault Radar

[← 목차](./)

Vault Radar는 코드, 문서, 채팅, 로컬 폴더 등에서 **관리되지 않는 시크릿**(하드코딩된 키, 비밀번호, 토큰)을 찾아 주는 스캐너다.
찾은 시크릿이 Vault 같은 시크릿 매니저에 이미 있는지까지 연결해서 보여 주는 게 일반 시크릿 스캐너와 다른 점이다.

## 사실 이미 맞고 있었다

이 저장소에 Boundary Terraform 코드를 커밋하려는데 로컬 pre-commit 훅이 막았다.

```
Block Secrets: COMMIT BLOCKED
Powered by IBM Vault Radar
error: terraform/boundary-config/main.tf:114:21: detected Password assignment: severity medium
```

로컬 docker 컨테이너용 테스트 비밀번호(`password = "pgpass"`)였다.
값을 `variable`로 빼고 gitignore된 `terraform.tfvars`로 옮기니 통과했다.
`terraform plan` 결과는 "No changes"였다.
코드 위생만 좋아졌다.

## Trial 시작

- 포털 Vault Radar 메뉴 → "Get started with 30 day trial".
- 경고: **조직당 한 프로젝트에서만** Vault Radar를 켤 수 있다.
- 활성화하면 `vault-radar-portal.cloud.hashicorp.com`이라는 **별도 도메인**의 콘솔로 넘어간다.
- 사이드바: Overview, Resources, Events, Pull Request Scans, Settings.
- Settings 하위: Data sources, Secret managers, CLI tool installation, Agent, Filters, Event rules, Global ignore rules, Custom expressions, PR checks, Remediation, GitHub apps, Radar usage.
- 통합: Jira, Slack, Webhook, Microsoft Teams, PagerDuty, ServiceNow, Splunk, VS Code 확장. 상당수가 Essentials 배지(상위 플랜)다.

## 스캔 방식 3가지

| 방식 | 특징 |
| --- | --- |
| HCP Vault Radar Scan (권장) | HCP가 직접 스캔. 설정·운영 없음. GitHub, GitLab, Bitbucket, Azure DevOps, Confluence, Jira, SharePoint, OneDrive, Slack, Teams 지원 |
| Vault Radar Agent Scan | 내 환경에 에이전트를 띄워서 스캔. 사설망 소스용 |
| Vault Radar CLI Scan | 로컬에서 `vault-radar` 실행, 결과만 HCP로 |

## CLI 스캔

`releases.hashicorp.com`에서 `vault-radar` 0.56.0을 받았다.

가짜 시크릿 폴더를 만들었다.
이 파일들은 저장소에 넣지 않았다.

```python
# app/config.py (공개 문서의 예제 값 + 형식만 맞춘 가짜 값)
AWS_ACCESS_KEY_ID = "AKIAIOSFODNN7EXAMPLE"
AWS_SECRET_ACCESS_KEY = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
DATABASE_URL = "postgres://admin:<password>@db.internal:5432/prod"
GITHUB_TOKEN = "ghp_<36 chars>"
```

### 403부터

Contributor SP로 돌리면:

```
http POST .../2023-05-01/vault-radar/projects/<PROJECT>/api/resources returned code: 403
```

Radar는 전용 역할이 필요하다.
`roles/vault-radar.cli-user`만 가진 SP를 새로 만들었다.

```bash
hcp iam service-principals create radar-cli
hcp projects iam add-binding --member=<radar-cli id> --role=roles/vault-radar.cli-user
hcp iam service-principals keys create radar-cli --output-cred-file=secrets/radar-cred.json
```

TTY가 없는 환경에서는 `could not start program: open /dev/tty`로 죽는다.
`--disable-ui`를 줘야 한다.

```bash
export HCP_PROJECT_ID=... HCP_CLIENT_ID=... HCP_CLIENT_SECRET=...
vault-radar scan folder -p app -o out.json -f json --skip-activeness --disable-ui --path-prefix radar-demo
```

### 결과

| 탐지 | 심각도 | 비고 |
| --- | --- | --- |
| AWS access key ID | info | `example_secret`, `common_word_in_secret` 태그. AWS 문서 예제 키라는 걸 안다 |
| Password in URL | medium | Postgres 접속 문자열 |
| GitHub personal access token | medium | `ghp_` 형식 |

- AWS secret key 예제(`...EXAMPLEKEY`)는 아예 안 잡혔다.
- `.env`에 넣은 Slack webhook(`T00000000/B00000000/XXXX...`)과 Stripe 키(알파벳 순서 문자열)도 안 잡혔다.
  파일명을 `settings.env`, `dotenv.txt`로 바꿔도 마찬가지였다.
  점 파일이라서가 아니라 값 자체가 엔트로피 낮은 더미라서 걸러진 것이다.
- 예제/더미 판별 덕분에 노이즈가 적다.

CLI 결과는 HCP로 올라가서 포털에도 바로 보인다.

- Resources: `radar-demo` (2 Medium), `radar-demo2` (None). 데이터 소스는 호스트 이름, 타입은 Folder.
- Events: 기본 필터가 "최신 버전의 활성 위험"이라 info는 숨겨지고 Medium 2건만 보인다.
  값은 `***`로 가려져 있다.

![Vault Radar events](images/radar-events.jpg)

Events 화면 상단에 "Link secret manager" 버튼이 있다.
Vault 같은 시크릿 매니저를 연결하면 "이 유출된 값이 이미 Vault에 관리되는 값인가"를 표시해 준다.
