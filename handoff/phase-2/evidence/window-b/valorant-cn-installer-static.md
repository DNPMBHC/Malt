# 国服 VALORANT 安装包（`VALORANT_CN_installer_v2.17.4.510.exe`）只读静态取证摘要

采集日期：2026-11-22（Asia/Shanghai）
样本路径：`<workspace>/VALORANT_CN_installer_v2.17.4.510.exe`
结构化数据：`handoff/phase-2/evidence/window-b/valorant-cn-installer-static.json`
采样原则：**纯只读静态解析（零修改、零执行、零解包篡改、零逆向绕过）**

---

## 1. 文件指纹与完整性验证

| 属性 | 实测值 |
| --- | --- |
| 文件路径 | `<workspace>/VALORANT_CN_installer_v2.17.4.510.exe` |
| 精确大小 | `491,792,264` 字节（约 `469.01 MiB`） |
| 全文件 SHA-256（读取前） | `686ee838411863d2eccdbe8a0596129e509819ae46626408760588ae8b0c800e` |
| 全文件 SHA-256（读取后） | `686ee838411863d2eccdbe8a0596129e509819ae46626408760588ae8b0c800e`（确认零修改） |
| Authenticode PE 映像 SHA-256 | `9ad0a0c98edc3dbcd786bad74b1f3decfc4228bcca06dfffff1b295f0388b248` |
| PKCS#7 `SpcIndirectDataContent` 摘要一致性 | `true`（密码学静态摘要完全匹配） |

---

## 2. PE 头部、节表与封装结构

- **PE 格式与架构**：
  - `Magic`: `0x010b`（`PE32` 32 位可执行文件）
  - `Machine`: `0x014c`（`IMAGE_FILE_MACHINE_I386` / x86）
  - `Subsystem`: `2`（`IMAGE_SUBSYSTEM_WINDOWS_GUI`）
  - `Characteristics`: `0x0102`（`EXECUTABLE_IMAGE | 32BIT_MACHINE`）
  - `DllCharacteristics`: `0x8540`（`DYNAMIC_BASE | NX_COMPAT | NO_SEH | TERMINAL_SERVER_AWARE`）
  - `COFF TimeDateStamp`: `1330111204`（`2012-02-24T19:20:04+00:00`，对应 NSIS v2.46.5-Unicode 预编译 `exehead` 存根时间戳）
- **导入系统 DLL（Import Directory）**：
  - `KERNEL32.dll`、`USER32.dll`、`GDI32.dll`、`SHELL32.dll`、`ADVAPI32.dll`、`COMCTL32.dll`、`ole32.dll`、`VERSION.dll`
- **节表与 Overlay 附加负载**：
  - 包含 6 个标准 NSIS PE 节：`.text`、`.rdata`、`.data`、`.ndata`（NSIS 未初始化数据节）、`.rsrc`、`.reloc`。
  - PE 节表原始数据结束偏移：`58,880` 字节。
  - Overlay 封装数据区：自偏移 `58,880` 至 Authenticode 证书表起始偏移 `491,781,744`，共 `491,722,864` 字节（约 `468.94 MiB`）为 Nullsoft Install System (NSIS v2.46.5-Unicode) 封装负载。
  - **合规边界**：仅对 PE 外层头部与封装器类型做只读识别，未在非授权环境下解包提取内嵌安装负载或反作弊二进制。

---

## 3. 版本资源（`VS_VERSION_INFO`）与清单（`RT_MANIFEST`）

| 字段 | 提取值 |
| --- | --- |
| `CompanyName` | `腾讯科技（深圳）有限公司` |
| `ProductName` / `FileDescription` | `无畏契约` |
| `FileVersion` / `ProductVersion` | `2.17.4.510` |
| `InternalName` | `aclos-launcher.exe` |
| `LegalCopyright` | `COPYRIGHT © 1998 – 2023 TENCENT. ALL RIGHTS RESERVED.` |
| `Manifest assemblyIdentity` | `Nullsoft.NSIS.exehead` (`version="1.0.0.0"`, `processorArchitecture="X86"`) |
| `Manifest description` | `Nullsoft Install System v2.46.5-Unicode` |
| `requestedExecutionLevel` | `asInvoker` (`uiAccess="false"`) |
| `supportedOS GUIDs` | `{35138b9a-5d96-4fbd-8e2d-a2440225f93a}` (Win7), `{e2011457-1546-43c5-a5fe-008deee3d3f0}` (Vista) |

---

## 4. Authenticode 数字签名与证书链

- **Security Data Directory**：文件偏移 `491,781,744`，大小 `10,520` 字节（`wRevision = 0x0200`, `wCertificateType = 0x0002` PKCS#7 SignedData）。
- **时间戳签名时间（UTC）**：`2026-10-27T04:03:50Z`（ASN.1 `261027040350Z`，北京时间 `2026-10-27 12:03:50`）。
- **证书链（共 5 张证书）**：
  1. **代码签名叶子证书（Signer）**：
     - Subject: `CN=Tencent Technology (Shenzhen) Company Limited, O=Tencent Technology (Shenzhen) Company Limited, L=Shenzhen, ST=Guangdong Province, C=CN`（`serialNumber=9144030071526726XG`）
     - Serial Number: `0b:ca:73:6e:dd:e7:f8:99:25:91:c3:07:6a:dc:fb:6e`
     - Issuer: `CN=DigiCert Trusted G4 Code Signing RSA4096 SHA384 2021 CA1`
     - Validity: `2026-04-08 00:00:00 GMT` ~ `2027-04-07 23:59:59 GMT`
     - Signature Algorithm: `sha256WithRSAEncryption`
  2. **代码签名中级 CA**：
     - Subject: `CN=DigiCert Trusted G4 Code Signing RSA4096 SHA384 2021 CA1, O=DigiCert, Inc., C=US`
     - Serial Number: `08:ad:40:b2:60:d2:9c:4c:9f:5e:cd:a9:bd:93:ae:d9`
  3. **时间戳签名叶子证书**：
     - Subject: `CN=DigiCert SHA256 RSA4096 Timestamp Responder 2026 1, O=DigiCert, Inc., C=US`
     - Serial Number: `08:4f:dc:33:4f:7e:45:4e:db:c3:0f:8f:f9:92:18:35`
  4. **时间戳中级 CA**：
     - Subject: `CN=DigiCert Trusted G4 TimeStamping RSA4096 SHA256 2025 CA1, O=DigiCert, Inc., C=US`
     - Serial Number: `0d:c7:ac:57:05:ff:21:99:2e:40:43:22:0c:3a:49:86`
  5. **根/交叉证书**：
     - Subject: `CN=DigiCert Trusted Root G4, OU=www.digicert.com, O=DigiCert Inc, C=US`
     - Serial Number: `0e:9b:18:8e:f9:d0:2d:e7:ef:db:50:e2:08:40:18:5a`

---

## 5. 五维状态与架构边界说明

1. **安装器架构 ≠ 内核反作弊驱动架构**：
   - 本样本外层为 32 位 x86 NSIS 安装引导器（`aclos-launcher.exe`，`IMAGE_FILE_MACHINE_I386`），在 Windows 10/11（无论 x64 或 ARM64 的 WOW64 用户态转译层）中属于用户态引导程序。
   - 国服实际部署的内核级反作弊驱动（如 ACE / Anti-Cheat Expert 驱动组件）仅在正规安装或启动流程中释放与注册，其具体驱动文件名、PE Machine（`AMD64` 或 `ARM64`）、版本与加载行为**不能由外层 x86 安装引导器推断**。
2. **五维状态分离**：
   - **代码实现**：`passed`（只读静态解析与密码学摘要校验完成）
   - **本机合成验证**：`passed`（PE 结构与 PKCS#7 签名摘要匹配）
   - **真实 Guest/Wine 验证**：`not_tested`（待窗口 A Windows Guest 就绪并获用户二次授权后执行动态安装采样）
   - **厂商支持**：`unknown`（国服官方公开文档未明确 VM/ARM 支持策略）
   - **真实游戏验证**：`not_tested`（`driver_load`、`game_start`、`protected_session` 均保持 `unknown`）
