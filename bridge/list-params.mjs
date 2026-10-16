// `thread/list` 的参数修正。
//
// 上游 app-server 的 `thread/list` **默认只回当前 config 里
// `model_provider` 那一家的会话**（config.toml 里是 `custom`）。
// 别的 provider 建的会话一条都不给 —— 手机端拿到的列表因此只剩
// 两三条，而电脑上那些会话一条都看不到。
//
// 实测（同一个上游，只差这一个字段）：
//   {limit:100,sortDirection:'desc'}                    -> 2 条
//   {limit:100,sortDirection:'desc',modelProviders:[]}  -> 16 条
// 空数组 = 不过滤。所以这里补一个空数组，App 侧不用改、也不用重装。
//
// 只在**没写**这个字段时补；App 将来自己指定了就照它说的走。
export function withAllProviders(message) {
  if (!message || message.method !== 'thread/list') return message;
  const params = message.params || {};
  if ('modelProviders' in params) return message;
  return { ...message, params: { ...params, modelProviders: [] } };
}
