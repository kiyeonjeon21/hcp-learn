# 06. HCP Vagrant Registry: 이미 지는 서비스

[← 목차](./)

Vagrant Box를 올리고 공유하는 레지스트리다.
예전 Vagrant Cloud(`app.vagrantup.com`)가 HCP로 옮겨 온 것이다.

## 만들기 시도

API로 먼저 만들어 봤다.

```bash
curl -X POST -H "Authorization: Bearer $T" \
  https://api.cloud.hashicorp.com/vagrant/2022-09-30/registries \
  -d '{"location":{"organization_id":"...","project_id":"..."},"name":"kiyeonjeon21-hcp-learn"}'
# {"code":14,"message":"resource creation is currently disabled"}
```

포털에서도 "Create a Box Registry" 폼은 그대로 열리지만, 제출하면 같은 에러가 폼 위에 뜬다.
버튼과 폼을 남겨 둔 채 서버에서만 막아 둔 상태라 처음엔 장애인 줄 알았다.

## 이유: deprecation

레지스트리 목록 화면 상단 배너:

> HCP Vagrant is in the process of being deprecated and limited features will be available from the community edition effective November 2, 2026.

- 2026-11-02부터 HCP Vagrant는 deprecation 단계다.
  새 레지스트리를 만들 수 없다.
- "Link your Vagrant Cloud account to reclaim your Vagrant registries" 배너와 "Unclaimed Registries" 메뉴가 있다.
  예전 Vagrant Cloud 계정의 레지스트리를 HCP로 가져오는 기능이다.
- "Discover Public Boxes"는 여전히 동작한다.
  다운로드 순 1위는 `ubuntu/trusty64` (3천만 회 이상, 마지막 릴리스 7년 전).

## 느낀 점

- HCP 포트폴리오가 정리되는 중이라는 게 눈에 보인다.
  Consul Dedicated는 메뉴에서 사라졌고, Vault Secrets는 CLI에만 흔적이 남았고, Vagrant는 생성이 막혔다.
- 새로 쓸 서비스를 고를 때는 changelog와 deprecation 공지를 먼저 확인해야겠다.
