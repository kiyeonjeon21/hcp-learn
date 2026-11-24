# 04. HCP Boundary

[← 목차](./)

Boundary는 "사람이 인프라에 접속하는 경로"를 관리한다.
VPN이나 배스천 대신, 사용자는 Boundary에 로그인하고 허락된 **target**에만 세션을 연다.
DB 비밀번호나 SSH 키는 사용자에게 주지 않고 Boundary가 대신 넘겨준다.

이번 실습 구성:

```
[내 노트북: boundary CLI]
        │  (1) 로그인/세션 인가
        ▼
[HCP Boundary 컨트롤 플레인]  ← HCP가 운영
        ▲  (2) 아웃바운드로 붙어 있음
        │
[내 노트북: self-managed worker] ──(3)──▶ docker: postgres(15432), openssh(12222)
```

## 클러스터 만들기 (Terraform, 3분)

포털 세션이 끊겨 있어서 `hashicorp/hcp` provider로 만들었다.

```hcl
resource "hcp_boundary_cluster" "this" {
  cluster_id = "hcp-learn-boundary"
  username   = "admin"
  password   = random_password.admin.result
  tier       = "Standard"
}
```

`terraform apply` 2분 52초 만에 `https://<uuid>.boundary.hashicorp.cloud` 주소가 나왔다.

처음 상태:

- 스코프는 `global` 하나뿐이다.
  org/project는 직접 만들어야 한다.
- password auth method와 `admin` 계정이 있다.
- **HCP managed worker 2개**가 이미 떠 있다 (`hcp-managed-worker-0/1`, 버전 v1.1.1+ent).

## CLI 로그인

```bash
boundary authenticate password -auth-method-id=ampw_... -login-name=admin \
  -password=env://BP -keyring-type=none -format=json
```

`BOUNDARY_TOKEN` 환경변수를 그대로 쓰면 deprecated 경고가 뜬다.
이제는 `-token env://BOUNDARY_TOKEN` 형식을 쓰라고 한다.

## Self-managed worker: 내 네트워크로 들어가는 문

HCP managed worker는 HCP 쪽 네트워크에 있어서 내 노트북의 docker 컨테이너에 닿을 수 없다.
그래서 노트북에 worker를 하나 띄운다.
HCP에 붙는 worker는 **Enterprise 바이너리**(`boundary_<ver>+ent`)여야 한다.
`releases.hashicorp.com`에서 `1.0.4+ent`를 받았다.

```hcl
# worker.hcl
disable_mlock           = true
hcp_boundary_cluster_id = "<cluster uuid>"

listener "tcp" {
  address = "127.0.0.1:9202"
  purpose = "proxy"
}

worker {
  auth_storage_path = "./auth"
  tags { type = ["laptop", "docker"] }
}
```

`boundary server -config=worker.hcl`로 띄우면 로그에 `Worker Auth Registration Request: <긴 토큰>`이 찍히고, 등록 전까지 `node is not yet authorized` 에러가 반복된다.
이 토큰으로 컨트롤 플레인에 등록하는 게 **worker-led registration**이다.
worker는 HCP로 아웃바운드 연결만 하므로 인바운드 포트를 열 필요가 없다.

## 접근 모델 전체를 Terraform으로

`hashicorp/boundary` provider로 한 번에 만들었다.
전체 코드는 [`terraform/boundary-config/main.tf`](https://github.com/kiyeonjeon21/hcp-learn/blob/main/terraform/boundary-config/main.tf).

| 리소스 | 내용 |
| --- | --- |
| `boundary_worker` | worker-led 토큰으로 노트북 worker 등록 |
| `boundary_scope` | `global` → org `hcp-learn` → project `local-docker` |
| `boundary_host_catalog_static` / `host_static` / `host_set_static` | `127.0.0.1` 호스트 하나 |
| `boundary_credential_store_static` | postgres, ssh용 username/password |
| `boundary_target` (tcp) | postgres, 자격 증명 **brokering** |
| `boundary_target` (ssh) | openssh, 자격 증명 **injection** |
| `boundary_user` + `boundary_role` | postgres만 접속 가능한 `dev` 사용자 |

apply 한 번에 리소스 14개가 생겼다.

## 첫 번째 실패: multi-hop

target에 `egress_worker_filter`만 걸었더니 세션 인가가 500으로 실패했다.

```
server.filterWorkersEnt: No ingress workers with valid next-hop paths could be found
for this multi-hop session.: state violation: error #133
```

egress만 지정하면 클라이언트는 HCP managed worker(ingress)로 들어가고, 거기서 노트북 worker(egress)로 넘어가는 multi-hop 경로를 찾는다.
그런데 내 worker는 HCP 쪽으로 아웃바운드만 붙어 있어서, 그 경로를 만들 수 없었다.
클라이언트도 같은 노트북에 있으니 **ingress도 노트북 worker로** 지정해서 해결했다.

```hcl
ingress_worker_filter = "\"laptop\" in \"/tags/type\""
egress_worker_filter  = "\"laptop\" in \"/tags/type\""
```

## Postgres: credential brokering

```bash
boundary connect postgres -target-id ttcp_... -dbname appdb -- -c "select current_user, version();"
```

```
 current_user | version
--------------+---------------------------------------------
 postgres     | PostgreSQL 17.12 on aarch64-unknown-linux-musl ...
```

DB 비밀번호를 한 번도 입력하지 않았다.
Boundary가 세션 인가 때 자격 증명을 클라이언트로 내려주고(brokering), `boundary connect postgres`가 그걸 `psql`에 넘긴다.
사용자 눈에 비밀번호가 보일 수는 있다는 점이 injection과 다르다.

## SSH: credential injection

ssh target은 worker가 SSH 핸드셰이크에 자격 증명을 직접 끼워 넣는다.
클라이언트는 비밀번호를 아예 모른다.

`boundary connect ssh -target-id ... -- 'whoami'`로 원격 명령을 넘기니 `hostname contains invalid characters`가 났다.
`--` 뒤 인자가 호스트 자리로 들어간 것 같다.
그냥 로컬 리스너를 열고 일반 ssh로 붙었다.

```bash
boundary connect -target-id tssh_... -listen-port 55222 &
ssh -p 55222 -o BatchMode=yes whatever@127.0.0.1 'echo "logged in as $(whoami) on $(hostname)"'
# → logged in as demo on 3b59b82d8db6
```

- `BatchMode=yes`라서 비밀번호 프롬프트가 뜰 수 없는데도 로그인됐다.
- 사용자 이름을 `whatever`로 줬는데 실제로는 `demo`로 들어갔다.
  worker가 주입한 자격 증명이 이긴다.

## RBAC: dev 사용자

```hcl
grant_strings = [
  "ids=${boundary_target.postgres.id};actions=read,authorize-session",
  "ids=*;type=target;actions=list,no-op",
  "ids=*;type=session;actions=list,read:self,cancel:self",
]
```

- dev로 로그인하면 target 목록에는 postgres와 ssh가 둘 다 보인다 (`list,no-op` 때문).
- postgres 접속은 된다.
- ssh 세션 인가는 `403 PermissionDenied`.
- 목록에서도 숨기고 싶으면 `list` grant를 빼거나 id를 좁혀야 한다.

`sessions list`에는 누가 어떤 target에 언제 붙었는지가 남는다.

## 느낀 점

- 컨트롤 플레인을 HCP가 운영하고, 내 네트워크에는 아웃바운드만 하는 worker 하나만 두면 된다.
  VPN 없이 사설망 접속이 된다.
- ingress/egress worker 필터는 "클라이언트가 어디 있고, 대상이 어디 있는가"를 그대로 반영해야 한다.
  여기서 한 번 막혔다.
- brokering(자격 증명을 사용자에게 건넴)과 injection(사용자가 끝까지 모름)의 차이를 직접 보니 명확하다.
