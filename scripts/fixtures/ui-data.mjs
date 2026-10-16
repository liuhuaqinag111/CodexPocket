export const projects = [{ id: 'example-project', name: '示例项目', roots: ['/workspace/example'] }];
export const threads = [{ id: 't1', name: '本地界面示例', cwd: '/workspace/example',
  projectId: 'example-project', model: 'gpt-5.5', updatedAt: 1700000000,
  status: { type: 'idle' } }];
export const models = [{ id: 'gpt-5.5', model: 'gpt-5.5', displayName: '示例模型',
  supportedReasoningEfforts: [{ reasoningEffort: 'high' }], defaultReasoningEffort: 'high' }];
export const turns = [1, 2].map(index => ({
  id: 'example-turn-' + index, status: 'completed', createdAt: 1700000000 + index,
  items: [
    { id: 'example-user-' + index, type: 'userMessage', content: [
      { type: 'text', text: '检查本地界面示例 ' + index }] },
    { id: 'example-agent-' + index, type: 'agentMessage',
      text: '这是隔离的界面样例，不会创建真实会话。可以检查图片、消息和连接状态。' }
  ]
}));
