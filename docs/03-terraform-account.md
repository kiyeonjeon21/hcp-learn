# 03. HCP Terraform: 계정 연동부터 막히다

[← 목차](./)

HCP 포털의 Terraform 메뉴는 설명과 "Go to HCP Terraform" 버튼뿐이다.
버튼을 누르면 `app.terraform.io`로 넘어가는데, HCP 세션을 이어받지 않고 별도 로그인 화면이 뜬다.

## HCP와 HCP Terraform은 계정이 따로다

HCP Terraform(구 Terraform Cloud)은 원래 독립 서비스라 계정 체계가 HCP와 분리돼 있다.
둘을 잇는 게 "HCP 계정 연동(account linking)"이다.

로그인한 상태에서 `GET /api/v2/account/details`를 브라우저로 열어 보면 상태를 바로 알 수 있다.

| 필드 | 연동 전 | 연동 후 |
| --- | --- | --- |
| `auth-method` | `tfc` | `hcp_github` |
| `has-linked-hcp` | `false` | `true` |
| `can-manage-hcp-account` | `false` | `true` |
| `can-change-email` | `true` | `false` (이메일은 이제 HCP가 관리) |

## 로그인 화면에 HCP 버튼이 없다

문서에는 "Continue with HCP account"를 누르라고 돼 있지만, 2026-11 기준 로그인 화면은 이렇게 생겼다.

- "Email or Username" 입력 → Continue
- "Sign in with SSO"
- "Create an account"

HCP 버튼이 없다.
게다가 내 이메일을 넣으면 기존 Terraform 계정(비밀번호 계정)이 있어서 비밀번호 단계로 가 버린다.
즉 이미 standalone 계정이 있는 사람은 화면에서 HCP 로그인으로 갈 길이 안 보인다.

## 로그인 화면이 실제로 하는 일

로그인 페이지 JS 번들을 받아서 `hcp`가 들어간 경로를 찾아봤다.

```bash
curl -sL https://app.terraform.io/login -o login.html
for js in $(grep -oE 'src="[^"]+\.js"' login.html | sed 's/src="//;s/"//'); do curl -sL "$js"; done > all.js
grep -oE '"/[a-zA-Z_/-]*hcp[a-zA-Z_/-]*"' all.js | sort -u
# "/session/hcp"  "/session/hcp/link"  "/session/hcp/sign_out"
```

ID 단계 컴포넌트는 이렇게 동작한다.

```js
toHcpLogin()     { this.redirectToHcp = true }   // 식별자 확인 실패 시
toPasswordStep() { this.currentStep = PASSWORD } // 식별자 확인 성공 시
```

- 입력한 이메일/사용자명이 **비밀번호 계정과 일치하면** 비밀번호 단계로 간다.
- **일치하지 않으면** HCP 로그인(`POST /users/auth/hcp_api`, OmniAuth)으로 넘어간다.
- 연동 확인 화면은 `/public/hcp-account-link/link`이고, 확인 버튼이 `/session/hcp/link`로 POST한다.

`/session/hcp`를 GET으로 열면 404다.
POST 전용이다.

## 우회: 존재하지 않는 식별자를 넣는다

로그인 화면에 **아무 계정과도 일치하지 않는 문자열**(예: `hcp-login-probe-nonexistent`)을 넣고 Continue를 누르면 된다.

1. 식별자 확인이 실패하니 HCP 로그인으로 넘어간다.
2. 브라우저에 HCP 세션이 있으면 HCP 인증이 조용히 통과된다.
3. HCP 계정 이메일과 같은 이메일의 기존 Terraform 계정이 있으니 연동 화면이 뜬다.

연동 화면 내용:

> Link your HCP Terraform and HCP accounts.
> Continue below to link your HCP Terraform account (email) to your HCP GitHub account (email).

"Link account"를 누르면 끝이다.
비밀번호를 다시 묻지 않았다.
이제부터 Terraform 로그인은 HCP 자격 증명으로만 된다.
되돌리고 싶으면 Account settings → HCP account linking에서 해제할 수 있다 (원래 있던 계정이라 해제 가능).

## 그래도 조직은 못 만든다

연동 후 다시 Personal 조직을 만들어 봤지만 같은 에러가 났다.

```
Error creating organization
Free tier organizations created by user limit reached.
```

- 계정에는 조직이 하나도 없다 (`GET /api/v2/organizations` → `{"data":[]}`).
- 권한도 있다 (`can-create-organizations: true`).
- 그런데 "이 사용자가 만든 무료 조직 수"가 한도에 걸렸다는 응답이다.
- 공식 문서의 한도 표에는 사용자당 조직 생성 수 제한이 안 나온다.
  anti-abuse 정책에 "과도한 생성/삭제"라는 표현만 있다.
- 예전에 만들었다 지운 조직이 카운트에 남아 있는 것으로 추정한다.
  연동해도 같은 사용자라 카운트가 그대로다.

이 부분은 지원팀 문의가 필요해 보인다.
