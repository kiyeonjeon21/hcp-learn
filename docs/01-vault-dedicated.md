# 01. Vault Dedicated

[← 목차](./)

HCP가 운영해 주는 Vault Enterprise 클러스터다.
이미 `vault-cluster`(Development 티어, Extra Small, AWS ca-central-1)가 떠 있어서 그걸로 시작했다.

## 포털에서 보이는 것

클러스터 Overview 화면:

- Vault 버전 v2.1.2 (로컬 CLI는 2.2.2), 단일 노드 (HA 없음).
- Public / Private 두 개의 클러스터 URL. Public이 켜져 있고 IP allowlist는 비어 있어서 포털이 경고 배너를 띄운다.
- Snapshot 용량 0.89 MB / 45 MB.
- Quick actions: CLI/API 접속 안내, **admin 토큰 생성**, Connectivity tester.
- 비상용: **API Lock** (침입 감지 시 데이터 잠금), **Revoke all admin tokens**.
- 사이드 메뉴: Overview, Replication, Networking.
- `Manage` 메뉴: "Import to Terraform" (`terraform import hcp_vault_cluster.<name> ...` 명령을 그대로 복사해 준다), Edit configuration, Delete cluster.

Edit configuration에서 본 가격:

- Development / Extra Small: **$0.61644/hr, 월 약 $450**, 2 vCPU, 1 GiB RAM, 클라이언트 25개까지.
- Trial 크레딧 $500이면 이 클러스터 하나로 한 달이 안 간다. 실험이 끝나면 지워야 한다.
- 옵션: Reporting (Beta, 시크릿/인증서 메타데이터 인벤토리), Port 443 사용.

## admin 토큰과 CLI 접속

admin 토큰은 포털 버튼으로도, HCP API로도 받을 수 있다.
유효기간은 6시간.

```bash
T=$(hcp auth print-access-token)
curl -s -H "Authorization: Bearer $T" \
  "https://api.cloud.hashicorp.com/vault/2020-11-25/organizations/$ORG/projects/$PROJ/clusters/vault-cluster/admintoken" \
  | jq -r .token

export VAULT_ADDR=https://<cluster-public-endpoint>:8200
export VAULT_NAMESPACE=admin      # HCP Vault는 root 네임스페이스를 주지 않는다
export VAULT_TOKEN=<admin token>
```

`vault status`에서 보이는 HCP 쪽 구성:

- Seal Type `awskms` (auto-unseal), Recovery Seal shamir 1/1.
- Storage `raft`, Version `2.1.2+ent`.
- 토큰 정책은 `hcp-root` + `default`, 네임스페이스는 `admin/`.

`admin` 네임스페이스에는 다른 프로젝트에서 쓰던 설정(transit, kv, approle, GitHub Actions OIDC용 jwt)이 이미 있었다.
건드리지 않으려고 하위 네임스페이스 `admin/hcp-learn`을 만들어서 그 안에서만 실험했다.
Vault 2.x에는 `agent-registry/` (`ns_agent_registry`)라는 시스템 마운트가 기본으로 보인다.
처음 보는 거라 메모만 해 둔다.

```bash
vault namespace create hcp-learn
export VAULT_NAMESPACE=admin/hcp-learn
```

## KV v2: 버전 관리

```bash
vault secrets enable -path=kv kv-v2
vault kv put kv/app/config db_user=app db_pass='s3cr3t-v1'
vault kv put kv/app/config db_user=app db_pass='s3cr3t-v2'
vault kv get -version=1 -field=db_pass kv/app/config   # → s3cr3t-v1
```

덮어써도 이전 버전이 남는다.
`current_version 2`.

## 정책 + AppRole: 앱용 최소 권한

```hcl
# app-ro.hcl
path "kv/data/app/*"        { capabilities = ["read"] }
path "transit/encrypt/app"  { capabilities = ["update"] }
path "transit/decrypt/app"  { capabilities = ["update"] }
```

```bash
vault policy write app-ro app-ro.hcl
vault auth enable approle
vault write auth/approle/role/app token_policies=app-ro token_ttl=15m secret_id_ttl=1h
RID=$(vault read -field=role_id auth/approle/role/app/role-id)
SID=$(vault write -f -field=secret_id auth/approle/role/app/secret-id)
APPTOK=$(vault write -field=token auth/approle/login role_id=$RID secret_id=$SID)

VAULT_TOKEN=$APPTOK vault kv get -field=db_user kv/app/config   # → app
VAULT_TOKEN=$APPTOK vault kv put kv/app/config x=1              # → Code: 403 permission denied
```

KV v2 정책 경로는 `kv/data/...`이다.
CLI에서는 `kv/app/config`로 쓰지만 정책은 API 경로 기준이라는 점이 늘 헷갈린다.

## Response wrapping

secret_id를 직접 넘기지 않고 한 번만 풀 수 있는 래핑 토큰으로 넘긴다.

```bash
W=$(vault write -wrap-ttl=60s -f -field=wrapping_token auth/approle/role/app/secret-id)
vault unwrap -field=secret_id $W   # 성공
vault unwrap $W                    # → wrapping token is not valid or does not exist
```

두 번째 unwrap이 실패하니, 중간에 누가 가로채서 먼저 풀었다면 정상 수신자가 바로 알아챌 수 있다.

## Transit: 암호화 서비스

```bash
vault secrets enable transit
vault write -f transit/keys/app
VAULT_TOKEN=$APPTOK vault write -field=ciphertext transit/encrypt/app plaintext=$(echo -n "hello hcp" | base64)
# → vault:v1:vmKO...
VAULT_TOKEN=$APPTOK vault write -field=plaintext transit/decrypt/app ciphertext=vault:v1:... | base64 -d
# → hello hcp
vault write -f transit/keys/app/rotate
vault write -field=ciphertext transit/rewrap/app ciphertext=vault:v1:...
# → vault:v2:...
```

앱은 키를 한 번도 보지 않는다.
키 회전 후 `rewrap`으로 평문 노출 없이 새 버전으로 바꿀 수 있다.

## PKI: 내부 CA

```bash
vault secrets enable pki
vault secrets tune -max-lease-ttl=87600h pki
vault write -field=issuing_ca pki/root/generate/internal common_name=hcp-learn.internal ttl=87600h
vault write pki/roles/svc allowed_domains=hcp-learn.internal allow_subdomains=true max_ttl=72h
vault write pki/issue/svc common_name=api.hcp-learn.internal ttl=1h
```

1시간짜리 인증서가 바로 나온다.
짧은 수명 인증서를 자동 발급하는 게 Vault PKI의 핵심이다.

## userpass + Identity

```bash
vault auth enable userpass
vault write auth/userpass/users/alice password=... policies=app-ro
vault login -no-store -method=userpass username=alice password=...
```

로그인하면 Identity entity가 자동으로 생긴다.
AppRole 로그인 때도 entity가 생겨서, `identity/entity/id` 목록에 두 개가 보였다.
HCP Vault의 과금 단위인 "client"가 바로 이 entity 수라서, Dev 티어 25 clients 제한과 직결된다.

## 느낀 점

- 운영(언실, 스토리지, 백업, 업그레이드)은 신경 쓸 게 없다. CLI로 붙으면 그냥 Vault Enterprise다.
- 차이는 `admin` 네임스페이스부터 시작한다는 것과 root 토큰 대신 6시간짜리 admin 토큰을 쓴다는 것.
- 가장 싼 Dev 티어도 월 $450 수준이라 개인 학습용으로는 꽤 비싸다.
