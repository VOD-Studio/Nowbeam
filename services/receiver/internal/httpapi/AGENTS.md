<!-- Parent: ../AGENTS.md -->
# HTTP / WSS 约定

上层约定：[internal/AGENTS.md](../AGENTS.md)。

- 身份仅来自单个 Bearer 头，不能读取 Cookie 或 URL 凭证；管理与上报权限分离。
- 管理 JSON 请求上限 16 KiB，错误仅稳定 code，响应 no-store。不得回显内部异常和未知请求字段。
- Upgrade 之前鉴权并登记可撤销候选；必须精确协商 nowbeam.v1，拒绝 Origin，关闭压缩，限制完整文本消息 64 KiB。
- handler 不直接改设备 map；所有失效与断开归属交给 presence。终止后有限时间发送安全 error 与关闭码。
- CORS 只在公开读取路由精确匹配；CORS 不是权限。预检不授予公开读取，更不授予浏览器上报。
- 测试使用 httptest HTTPS 和真实 coder/websocket，测试证书只加入专用信任池，不关闭 TLS 验证。
