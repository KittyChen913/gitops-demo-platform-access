# AGENTS.md

本文件適用於 `gitops-demo-platform-access`。

## Ownership

- 本 Repository 擁有 Shared OpenVPN BASE、Reserved IPv4、VPN Server Firewall、Internal DNS、routing/NAT、一般 User groups、credential bootstrap、CI 自動化 VPN 身份與 network SSM outputs。
- 不管理 LKE、Worker Firewall、ArgoCD、application manifests 或一般 VPN User lifecycle。
- CI 自動化 VPN 身份綁定 consuming Repository，屬 credential bootstrap 的延伸；一般員工 User 的 onboard／offboard 與 email token lifecycle 仍由 `gitops-demo-user-provisioning` 管理。
- 目前不實作 Dev／Prod endpoint SYNC；沒有 runtime evidence 的功能不得預先加入。

## 實作規則

- 自動化腳本只使用 Shell，不得新增 Python 腳本或 Python invocation。
- 優先沿用現有 Shell 與 workflow `run` block；不得建立不必要的 helper、adapter、framework 或跨 Repo library。
- 不維護 Unit Test、mock、fixture、fake adapter 或 test-only helper。
- `config/shared.json` 是 Shared BASE 的 canonical configuration。
- Credential、Secret、Terraform state、plan JSON 與 private key 不得輸出到 log、summary 或 artifact。
- Runtime 操作必須維持 runner `/32`、strict host-key pin、baseline cleanup 與 fail-closed 行為。

## 安全與破壞性操作

- 不要主動執行 `terraform apply`，或手動觸發 `platform-base-configure.yml`、`terraform-deploy.yml`、`terraform-destroy.yml` 等會改變或刪除雲端資源的命令，除非使用者明確要求。
- destroy 只能由 `terraform-destroy.yml` 手動觸發，需輸入 `DESTROY-SHARED-ALL` 確認字串；apply 順序固定先 `base`（確認 state 清空後）再 `credential-bootstrap`，不要繞過此順序或改用 `-auto-approve`。
- 不要讀取、印出或提交 secret；若需確認 secret 是否存在，只回報存在與否。
- 不要修改 Terraform state、遠端 S3 state 或 GitHub Environment protection 設定，除非使用者明確要求。
- 不要回復使用者既有未提交變更；工作區已有變更時，先理解並在其上工作。

## 註解與顯示文字規範

- 人工維護的 Terraform、GitHub Actions、Ansible、設定檔與 Shell 註解必須使用繁體中文。
- 專有名詞、產品名稱、API、資源種類、欄位名稱、命令、路徑與識別字可保留英文，但英文專有名詞必須放在中文敘述中，不得以完整英文句子撰寫註解。
- Workflow／job／step、composite action 的 `name` 與 `description` 必須使用英文。
- 程式碼內的文字必須使用英文，包括 Terraform `description`／`error_message`、CLI 文字、log、error、warning、summary 與其他執行訊息；但等待／重試迴圈中即時印給人類觀察進度的狀態訊息（例如第幾次嘗試、剩餘秒數、失敗原因、逾時後的診斷輸出）例外，使用繁體中文。
- 產品名稱的唯一允許拼法為 `ArgoCD`。
- README 與 docs 使用繁體中文敘述；自動生成註解、shebang、lint directive 與被註解掉的程式碼不需翻譯或改寫。

## 驗證

- 依全域「最小必要 Validation」規範，先判定本次變更影響的 Terraform root／module、workflow、Shell execution path、YAML／Ansible configuration 或 shared security contract，再從 Terraform fmt／validate、actionlint、ShellCheck、YAML 與 Ansible syntax check 中選擇能直接驗證風險的最小子集。
- 只影響單一 root、workflow、script 或 configuration 時，優先使用對應的 targeted validation；不得預設檢查所有 Terraform roots、workflows、scripts、YAML 與 Ansible files。
- 共用 module、reusable workflow、Shell helper、canonical configuration 或 credential／network security boundary 確實影響多個直接 consumers 時，才擴大驗證範圍，並在執行前說明局部驗證不足的原因。
- 完整 CI／quality workflow、Terraform plan、apply、Ansible runtime 與外部 integration verification 屬 PR、merge、release、deployment 或獨立驗收 gate，不是每次本機局部修改後的預設 validation。
- Code Review validation 依全域規則使用固定版本、network-disabled、read-only Docker Container；不得在本機 validation 存取 AWS、Linode、OpenVPN 或其他外部 runtime。
- dependencies、Container Image 或安全執行條件不可用時，將對應 validation 標示為 `BLOCKED` 或 `NOT RUN`，並說明替代靜態驗證與未取得的信心。
