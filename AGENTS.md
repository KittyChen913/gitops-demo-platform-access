# AGENTS.md

本文件適用於 `gitops-demo-platform-access`。

## Ownership

- 本 Repository 擁有 Shared OpenVPN BASE、Reserved IPv4、VPN Server Firewall、Internal DNS、routing/NAT、一般 User groups、credential bootstrap 與 network SSM outputs。
- 不管理 LKE、Worker Firewall、Argo CD、application manifests 或一般 VPN User lifecycle。
- 目前不實作 Dev／Prod endpoint SYNC；沒有 runtime evidence 的功能不得預先加入。

## 實作規則

- 自動化腳本只使用 Shell，不得新增 Python 腳本或 Python invocation。
- 優先沿用現有 Shell 與 workflow `run` block；不得建立不必要的 helper、adapter、framework 或跨 Repo library。
- 不維護 Unit Test、mock、fixture、fake adapter 或 test-only helper。
- `config/shared.json` 是 Shared BASE 的 canonical configuration。
- Credential、Secret、Terraform state、plan JSON 與 private key 不得輸出到 log、summary 或 artifact。
- Runtime 操作必須維持 runner `/32`、strict host-key pin、baseline cleanup 與 fail-closed 行為。

## 驗證

最小驗證為 Terraform fmt/validate、actionlint、ShellCheck、YAML 與 Ansible syntax check。不得在本機驗證時存取 AWS、Linode、OpenVPN 或其他外部 runtime。
