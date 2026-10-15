# Anx Reader + Sign in with ChatGPT

在 [Anx Reader](https://github.com/Anxcye/anx-reader) 的基础上，使用 OpenAI 官方 Sign in with ChatGPT 接口登录，并在阅读助手中使用账号的 ChatGPT 套餐和可用模型。本项目是独立开发版，非 OpenAI 或 Anx Reader 官方发布。

## 功能与使用

1. 打开「设置 → AI → ChatGPT 账号」，点击 **Continue with ChatGPT**，在系统浏览器登录并授权。
2. 进入左侧 **AI**，在输入框下方的服务菜单选择 **ChatGPT**。
3. 旁边的模型按钮读取当前账号可用模型。选择模型即可对话，不需要填写 API Key。

支持账号切换、刷新、退出、模型列表和流式回答，复用现有阅读工具管线。仅收到 `response.completed` 才视为成功；配额、账号或网络错误不会自动转到其他 API Key、账号或付费通道。

## 隐私与边界

- OAuth 凭据保存于系统安全存储，不写入普通设置、同步、导出或仓库；系统存储不可用时不会回退到明文文件。
- macOS 使用登录 Keychain；Windows/Linux 预留平台工程及安全存储适配，尚未进行原生验收。
- 选择 ChatGPT 后，提问及你要求助手读取的内容会发送给 OpenAI，使用你的套餐或额度。不要向不信任的服务提供书籍或笔记。
- 本仓库不包含真实账号、令牌、书库、个人截图、构建产物或本机开发日志。测试身份、HTTP 响应及章节文本均为合成数据。
- 公共开发版使用通用应用标识 `org.openreader.chatgpt`，与上游正式版及本地个人开发实例的数据隔离；不会自动迁移它们的书库或登录。
- 真实书籍、翻译、全部阅读工具、长期刷新以及 Windows/Linux 原生版本仍需实际验证。macOS 调试版已验证登录、重启恢复、模型目录、普通对话及计算器工具往返；不将这些测试视为全部阅读功能已验收。

## 构建

使用 Flutter **3.35.3** / Dart **3.9.2**，并安装对应平台的原生构建依赖。macOS 需要完整 Xcode 和 CocoaPods，最低系统版本为 12.6。本次没有批量升级上游依赖。

```sh
flutter pub get
flutter gen-l10n
dart run build_runner build --delete-conflicting-outputs
flutter run -d macos --target lib/main.dart
# 仅账号页：flutter run -d macos --target lib/main_auth.dart
```

SQLite 的原生准备脚本不支持带空格的缓存路径。如果本机路径包含空格，请将 CocoaPods 缓存和临时目录配置为没有空格的路径。项目本身无需移动。

Windows/Linux 需要在各自系统上使用 `flutter run -d windows` / `flutter run -d linux`。Linux 还需要 Secret Service 密钥库及 `libsecret-1-dev`、`libjsoncpp-dev` 等平台构建依赖；平台代码的存在不代表已打包或测试通过。发布签名和公证由维护者自行配置。

## 测试

```sh
cd packages/chatgpt_auth
dart pub get --enforce-lockfile
dart format --output=none --set-exit-if-changed lib test
dart analyze
dart test
```

在仓库根目录完成代码生成后，可运行 Flutter 集成测试：

```sh
flutter test test/chatgpt_account_page_test.dart test/chatgpt_reader_model_test.dart
```

本地验证：认证核心 47 项、模型适配 3 项、账号界面 5 项测试通过。修改范围的集成分析存在一条上游未改动行的 BuildContext 异步使用 INFO，没有把它记为全仓严格检查通过。`.github/workflows/chatgpt-auth.yml` 提供三系统核心测试，远端实际结果以 Actions 为准。

## 实现与官方依据

- `packages/chatgpt_auth/`：PKCE、本机回调、动态注册、OIDC/JWKS 验签、账号隔离、刷新、撤销及严格流式终止检查。
- `lib/service/chatgpt/`：系统凭据、账号页面控制和阅读助手 Responses 模型适配。
- SDK 请求经认证核心传输，固定公网 Responses 地址，强制 `store:false` / `stream:true`；令牌不交给普通供应商配置。
- 套餐接口的系统提示使用 `instructions`；阅读工具使用非严格参数 schema；结束事件保留元数据且不重复追加已流式输出的回答和工具调用。

官方文档：[登录](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)、[会话管理](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions)、[模型和推理](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)、[工具调用](https://developers.openai.com/api/docs/guides/function-calling)。

保留上游 MIT [LICENSE](LICENSE)、作者署名和 Git 历史。Fork 的新增代码沿用相同许可证。
