37signals + TurboFlows Rails rules:
- Thin controllers: only orchestration + before_actions. Delegate to models/concerns.
- Rich models: add methods/concerns before creating POROs or services. Use Current.* for tenant/context when needed.
- Concerns for sharing (e.g., HasState, Catalogable style).
- No update_column, no after_commit side effects (use jobs), no N+1 (preload + Bullet).
- CRUD routes/actions preferred.
- Optimistic locking and real-time Action Cable patterns from WorkflowChannel.
- Match exact style of existing files (workflows_controller.rb, workflow.rb, workflows/base_controller.rb for namespace pattern, etc.).
