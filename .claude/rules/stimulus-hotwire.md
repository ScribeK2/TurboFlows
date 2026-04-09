Hotwire/Turbo + Stimulus rules (TurboFlows style):
- All new JS = reusable Stimulus controllers in app/javascript/controllers/.
- Use Turbo Streams/Frames for updates (replace, append, etc.).
- Vendored libs (SortableJS, Fuse.js) stay in vendor/javascript/.
- No Node build — everything must work with importmap-rails + Propshaft.
- Real-time presence and graph mode updates via Action Cable.
- Match the 60 existing Stimulus controllers exactly.
