# 交易所长期凭证录入与控制面对接

当前支持已实现适配器的 OKX、Binance、Bybit 和 Hyperliquid。SimulatedVenue 不需要秘密；
未实现的交易所不作为凭证支持承诺。公共行情不需要交易凭证。

流程：原生隐藏输入 → CredentialStore 加密包 → 控制面导入 → 节点原生解锁验证并注册 Staged →
现有凭证生命周期激活 → Gateway 打开受保护会话。激活和签名能力均不替代交易授权。

## 原生录入

### 1. 构建程序

在项目目录 `D:\github\Ringwin` 打开 PowerShell。已有最新构建产物时可以跳过构建：

```powershell
zig build -Doptimize=ReleaseSafe
```

正式二进制入口为 `ringwin --credential <操作> <输入文件> <绝对存储根目录>`。
`zig build` 同时安装专用的 `ringwin-credential` 原生程序，其后直接接操作参数。
也可只构建原生录入入口，避免构建整个交易系统：

```powershell
python tools/zig-entry.py build-exe src/runtime/credential_enrollment.zig -O ReleaseSafe '-femit-bin=.scratch/build/ringwin-credential.exe'
```

### 2. 准备非秘密 JSON 配置

在项目目录新建 `okx-account-7.json`，填写交易所、账户、环境、用途和节点绑定。
这个文件不放 API Key、Secret Key、OKX Passphrase、钱包私钥或加密口令。
标准 JSON 不支持 `//` 或 `#` 注释；下面的 JSON 可直接保存，各字段的注释列在紧随其后的表中。

```json
{
  "venue": "okx",
  "kind": "execution",
  "account": 7,
  "environment": "demo",
  "expires_at_unix": 4000000000,
  "credential_id": "okx-account-7-v1",
  "node_id": "gateway-node-1",
  "egress_ip": "203.0.113.7",
  "version": 1
}
```

| JSON 字段 | 必填 / 默认值 | 字段注释与当前校验 |
|---|---|---|
| `venue` | 必填 | 交易所标识：`okx`、`binance`、`bybit`、`hyperliquid`。决定后续提示哪些凭证字段；不填或填写不支持的标识会失败。 |
| `kind` | 必填 | 凭证用途：`observation` 用于只读，`execution` 用于交易。Hyperliquid 私钥录入仅支持 `execution`；只读查询无需私钥。 |
| `account` | 必填 | RingWin 已注册的 ExchangeAccount 数字标识，必须为非零 u64 整数。不是 API Key，也不要把示例 `7` 当成自己的账户标识。 |
| `environment` | 必填 | 凭证绑定的实际环境，取值及当前接线范围见下文；不会因为修改这个字段就把实盘凭证变成模拟凭证。 |
| `expires_at_unix` | 必填 | RingWin 为此凭证设置的到期时间，UTC Unix **秒**，必须晚于当前时间；不是毫秒，也不会修改交易所端的到期设置。示例值仅作格式演示。 |
| `credential_id` | 必填 | 本地凭证身份标识，例如 `okx-account-7-v1`，1～32 字节；用于绑定和区分凭证，不填写真实 API Key。 |
| `node_id` | 必填 | 获准使用此凭证的执行网关节点标识，1～64 字节，必须与实际节点配置一致。 |
| `egress_ip` | 必填 | 目标节点的固定出口 IP，应与交易所白名单一致。当前录入只校验非空和最多 64 字节，不验证地址格式或实际网络出口。示例 `203.0.113.7` 必须替换。 |
| `version` | 可省略，默认 `1` | 凭证版本，非零 u64 整数。相同身份与版本不能覆盖；凭证更新应按生命周期处理并使用正确的新版本。 |
| `generation` | 可省略，默认 `1` | 生命周期代次。首次 `enroll` 必须为 `1`；后续状态切换使用当前准确代次，不自行重置。 |
| `state` | 可省略，默认 `staged` | 当前生命周期状态。首次 `enroll` 必须为 `staged`；后续节点操作才使用真实的 `active`、`retiring` 或 `revoked`。 |

需要生成“从现在起 30 天后”的秒级时间戳时，可单独执行并把结果填入 `expires_at_unix`：

```powershell
[DateTimeOffset]::UtcNow.AddDays(30).ToUnixTimeSeconds()
```

这是离线示例；实际使用需填写已注册的账户、真实节点、固定出口及合适的有效期。
**当前项目的接线范围**是 OKX 使用 `demo` 或 `production`，Binance、Bybit、Hyperliquid 使用
`testnet` 或 `production`；后三家的录入路径当前拒绝 `demo`。这不是交易所官方环境的完整清单：
Binance 和 Bybit 也提供独立 Demo 服务，但本项目尚未接入。不要将 Demo 凭证改标为 `testnet`
来绕过限制；不同环境的账户、密钥和接口不能混用。
`kind` 为 `observation` 或 `execution`，程序按用途生成 Read 或 Read+Trade 能力位，永不
设置 Withdraw。记录这些能力不等于已向交易所证明权限；Gateway 仍需实际权限与账户预检。

### 3. 执行录入命令

使用完整程序入口：

```powershell
.\zig-out\bin\ringwin.exe --credential enroll .\okx-account-7.json D:\RingwinCredentials\packages
```

也可使用随正式构建安装的专用程序，二者执行相同录入流程：

```powershell
.\zig-out\bin\ringwin-credential.exe enroll .\okx-account-7.json D:\RingwinCredentials\packages
```

若前面只构建了独立入口，则把程序路径换成 `.\.scratch\build\ringwin-credential.exe`。

| 命令部分 | 注释 |
|---|---|
| `--credential` | 进入 RingWin 的凭证操作入口；专用 `ringwin-credential.exe` 不需要此参数。 |
| `enroll` | 新录入并加密一份凭证，初始状态为 Staged。 |
| `.\okx-account-7.json` | 上一步保存的非秘密配置文件路径；文件名可自行命名。 |
| `D:\RingwinCredentials\packages` | 生成加密包的存储根目录，必须为绝对路径；可换成自己管理的目录。 |

命令中不填写秘密。程序先读取 JSON 并校验绑定，再在当前终端提示输入秘密，最后才生成加密包。

### 4. 按提示输入凭证和加密口令

每出现一个提示，键入或粘贴对应值，然后按 Enter。所有实际提示的字段都必填；不适用的字段
不会提示，例如 Binance 和 Bybit 不会要求 OKX Passphrase。输入时既不显示原文，也不显示星号，
终端看起来没有变化是正常的。

以 OKX 为例，实际提示依次为：

```text
API key:
Secret key:
Passphrase:
Encryption password (at least 12 bytes):
Confirm encryption password:
```

下表是提示字段的注释，不是让你在 JSON 中增加这些字段：

| 提示字段 | 何时出现 | 注释与当前校验 |
|---|---|---|
| `API key` | OKX / Binance / Bybit | 从目标交易所的对应环境取得的 API Key，必填，1～128 字节。 |
| `Secret key` | OKX / Binance / Bybit | 与上述 API Key 配对的签名秘密，必填，1～128 字节；不是登录密码。 |
| `Passphrase` | 仅 OKX | 创建该 OKX API Key 时设置的 API Passphrase，必填，1～128 字节；不是稍后设置的本地加密口令。 |
| `Agent private key (64 hex)` | 仅 Hyperliquid | 代理钱包私钥，必填，恰好 64 位十六进制，不带 `0x`；校验私钥有效性。 |
| `Agent address (40 hex)` | 仅 Hyperliquid | 上述私钥对应的代理钱包地址，必填，恰好 40 位十六进制，不带 `0x`；校验与私钥派生地址一致。 |
| `Funding address (40 hex)` | 仅 Hyperliquid | 实际资金账户地址，必填，恰好 40 位十六进制，不带 `0x`，且不能为全零地址；不在此处输入资金账户私钥。 |
| `Encryption password (at least 12 bytes)` | 所有交易所 | 你为本地加密包独立设置的解锁口令，必填，12～256 字节；节点导入和后续解锁还需要它。目前不要求特定字符组合。 |
| `Confirm encryption password` | 所有交易所 | 再输入一次刚设置的加密口令，必须与第一次一致。 |

长度限制按字节计算，中文等非 ASCII 字符可能占多个字节。不要把占位说明文字作为真实凭证输入。
输入为空、超长、钱包格式错误或两次加密口令不同，程序会报错退出；当前不会让你在原字段重试，
需重新运行命令。上述输入校验失败时不会生成新凭证包，也不会覆盖已有凭证。
录入不连接交易所，因此不会验证 API Key 是否真实有效、资金地址是否已授权该代理或交易所
实际权限；这些仍需连接预检确认。

各秘密字段直接读入受保护内存；成功或失败退出
都会清零释放。不要通过 PowerShell 文本管道、argv、环境变量或普通明文文件提供秘密。
Linux 与 Windows 均支持隐藏 TTY；Linux 必须有足够的 memlock 配额。

### 5. 找到生成的加密包

成功后终端输出的状态为 `staged`、`authenticated=true`、`trading_enabled=false`，表示本地录入
成功，不代表交易所连接通过或已经允许交易。

生成目录为
`<根>/<venue>-<account>-<environment>-<credential_id零填充32字节的十六进制>-v<version>/`。
目录内的 `execution.credential` 或 `observation.credential` 就是上传的加密包；Hyperliquid
另有本地 nonce ledger，该文件不上传。每个身份/版本只能首次注册，不能覆盖旧凭证或复活吊销。
生成包后应保管好离线生成目录；控制面和节点均不托管解锁口令。

### 6. 在控制面导入

登录现有控制面 → 打开“交易所凭证”页面 → 选择上一步生成的 `.credential` 文件 →
点击“导入加密包”。上传加密文件即可，不上传 JSON、私钥或解锁口令。

页面显示“待节点解锁验证”后，按下文“节点解锁与生命周期”将密文交给目标节点并解锁。
控制面收到密文、节点验证导入、凭证激活、允许交易是不同步骤，上传成功不会立即开始交易。

`--restricted-input` 仅用于继承管道或 socket 的原生提供程序和合成 fixture；普通文件和伪装成
TTY 的管道均被拒绝。录入输入按上述字段顺序，再接两行口令。输入 EOF 不代替字段末尾换行。

## 现有控制面接口

实现位于 `python/control_plane_web.py`；现有 `python/operator_ui.html` 增加“交易所凭证”页。
RingwinUi 的合成原型未连接此接口。服务仍复用既有同源 HTTPS、OwnerSession Cookie 与
`X-Owner-CSRF`，GET 和 POST 都需要鉴权。

| 方法 | 路径 | 行为 |
|---|---|---|
| POST | `/api/credentials` | 导入一个 CRD4 v2 Staged 密文包，首次返回 201，完全相同的重试返回 200 |
| GET | `/api/credentials` | 返回收件箱的非秘密绑定提示和包 SHA-256；不返回密文或秘密 |

POST 的 JSON 必须只有 `encrypted_package`，值是整个 `.credential` 文件的标准 Base64。
请求上限 2048 字节、解码包上限 780 字节；不接收服务器文件路径、API Key 或解锁口令。

```javascript
const bytes = new Uint8Array(await file.arrayBuffer()); // 用户选择的加密文件
await fetch('/api/credentials', {
  method: 'POST', credentials: 'same-origin',
  headers: {'Content-Type': 'application/json', 'X-Owner-CSRF': csrf},
  body: JSON.stringify({encrypted_package: btoa(String.fromCharCode(...bytes))})
});
```

HTTP 回执与列表中 `status=pending_unlock`、`authenticated=false`、`trading_enabled=false`。
它们是收件箱状态，不是实际 CredentialState 投影。头部 Venue、账户、用途、版本、有效期等
在节点验证前仅是提示；Web 无法知道 AEAD 是否正确，也不能知道包对应的节点后来是否已激活。
u64 身份、版本与时间以十进制字符串返回。导入记录只保存摘要和结果，不保存 Base64 或秘密。
包存于控制面状态目录的 `credential-packages/<sha256>.credential`，以独占发布避免覆盖。

## 节点解锁与生命周期

将已接收的密文包通过现有部署通道交给对应节点，使用：

```powershell
.scratch/build/ringwin-credential.exe import received.credential D:\RingwinCredentials\node
```

程序隐藏读取口令，AEAD 验证并检查绑定、Staged、generation=1 和有效期后才注册新凭证。
错误口令、被篡改的账户/Venue、重复身份及已有吊销均不会覆盖原文件。钱包导入另建新的独占
nonce ledger；已有 Active 节点不可通过“重新导入”重置 nonce。

人工生命周期操作继续使用 `/lifecycle`：`credential_activate`、`credential_retire`、
`credential_revoke` 等；激活和吊销复用 RiskWarning。控制面现有 outbox 只提供已签名请求，
并没有自动远程解锁服务。节点部署 adapter 必须先验签、核对目标节点/包摘要和本地绑定，
再调用原生持久化原语；其应用回执与 outbox 入队回执分别处理。

原生程序也提供 `activate`、`retire`、`revoke` 节点原语，输入为上述非秘密 JSON，需额外包含
当前准确的 `state`、`generation`。它们逐次读取解锁口令并执行原有单向生命周期；输出新的状态
和代次，不授予交易权限。例如初次 `activate` 的输入为 `state=staged,generation=1`，成功后为
`active,2`；下一次吊销必须提交 `active,2`，结果为 `revoked,3`。这些原语不会自行验证 Web
RiskWarning；部署必须由已有验签路径调用，并限制对凭证目录的进程访问。

Gateway 组装复用 `CredentialStore.openScoped`：

- OKX / Binance / Bybit：以目标节点的可信 Metadata、RuntimeContext 和受限口令输入调用
  `openApiSession`，执行凭证绑定当前 owner token。观察会话不能用于新增风险。
- OKX 的 `okx_rest_auth.storedHeaders` 从会话生成受保护 headers。
- Binance / Bybit 的 `StoredAuthenticator.interface()` 接入现有 Authenticator；Bybit 的
  `receive_window_ms` 必须与 transport header 相同，timestamp 必须与原请求实际发送值相同。
- Hyperliquid 继续使用现有 `Signer.sign`、受限口令输入、持久 nonce 与 GatewayLeaseGuard。

API Key 的 HMAC 签名格式依据 [Binance 官方说明](https://developers.binance.com/en/docs/products/spot/rest-api)
和 [Bybit 官方说明](https://bybit-exchange.github.io/docs/v5/guide)；本路径不接收 RSA 或 Ed25519 私钥作为 HMAC secret。

会话逐次核对加密文件摘要；任何退休、吊销、替换或缺失均拒绝后续使用。执行签名仍检查当前
fencing 和有效期，Gateway 的 DispatchProof / 最终发送检查继续保留。旧的 `admitExecution`
仍返回 out-of-scope；调用方必须显式选择新会话入口。现有 Demo 的一次性管道入口仍保留，
不会在默认启动中自动发现凭证目录、解锁或选择账户。

## 离线验证

```powershell
python python/verify_credential_enrollment.py
python tools/zig-entry.py test src/security/credential_store.zig -O Debug --test-filter 'venue enrollment' --stack 536870912
```

第一项只用合成凭证验证四家原生录入、真实 HTTP 鉴权/CSRF/限长、密文持久化、重复导入、
原生 AEAD 验证、生命周期与防复活。第二项覆盖 API 会话、实际适配器认证入口、吊销关闭及
钱包导入后的签名。都不连接交易所，不证明目标机转储/swap、远程部署或生产交易资格。
