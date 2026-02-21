# Mogan STEM AI Assistant Plugin

## Overview

An AI assistant plugin for **Mogan STEM** (a GNU TeXmacs fork) that integrates large language models directly into the scientific document editor. The plugin enables users to leverage AI for tasks like equation generation, text completion, document translation, LaTeX conversion, and interactive Q&A — all without leaving the editor.

The plugin is implemented in **GNU Guile Scheme**, following Mogan's existing plugin conventions, and communicates with AI backends via the Goldfish HTTP library.

---

## Goals

1. **In-editor AI chat** — a session-based interface where users can converse with an LLM
2. **Context-aware assistance** — the AI can read the current selection, buffer, or document tree
3. **Document manipulation** — AI responses can insert, replace, or transform content directly
4. **Multi-provider support** — work with OpenAI-compatible APIs (OpenAI, Anthropic, local models via Ollama/LM Studio)
5. **Streaming responses** — display tokens incrementally using `http-stream-post`

---

## Architecture

```
┌─────────────────────────────────────────────┐
│                Mogan STEM Editor             │
│                                              │
│  ┌──────────┐  ┌──────────┐  ┌───────────┐  │
│  │ AI Menu  │  │ Keyboard │  │ AI Session│  │
│  │ Items    │  │ Bindings │  │ Widget    │  │
│  └────┬─────┘  └────┬─────┘  └─────┬─────┘  │
│       │              │              │         │
│       └──────────────┼──────────────┘         │
│                      ▼                        │
│            ┌─────────────────┐                │
│            │  ai-core.scm    │                │
│            │  (orchestrator)  │                │
│            └────────┬────────┘                │
│                     │                         │
│       ┌─────────────┼─────────────┐           │
│       ▼             ▼             ▼           │
│  ┌─────────┐  ┌──────────┐  ┌──────────┐     │
│  │ ai-     │  │ ai-      │  │ ai-      │     │
│  │ config  │  │ provider │  │ context  │     │
│  │ .scm    │  │ .scm     │  │ .scm     │     │
│  └─────────┘  └────┬─────┘  └──────────┘     │
│                     │                         │
└─────────────────────┼─────────────────────────┘
                      │ HTTP (liii http)
                      ▼
              ┌───────────────┐
              │  LLM Backend  │
              │  (OpenAI /    │
              │   Anthropic / │
              │   Ollama)     │
              └───────────────┘
```

---

## Plugin Directory Structure

```
TeXmacs/plugins/ai/
├── progs/
│   ├── init-ai.scm          # Plugin registration (plugin-configure)
│   ├── ai-core.scm          # Main orchestration: prompt building, response handling
│   ├── ai-config.scm        # Provider configuration, API key management
│   ├── ai-provider.scm      # HTTP transport: request formatting, streaming
│   ├── ai-context.scm       # Editor context extraction (selection, buffer, tree)
│   ├── ai-menus.scm         # Menu bar entries under a top-level "AI" menu
│   └── ai-kbd.scm           # Keyboard shortcuts
├── packages/
│   └── session/
│       └── ai.ts             # Session type definition for AI chat sessions
├── doc/
│   └── ai-help.en.tm         # User-facing help document
└── data/
    └── prompts/
        ├── system.md          # Default system prompt
        ├── translate.md       # Translation prompt template
        └── latex.md           # LaTeX generation prompt template
```

---

## Implementation Plan

### Phase 1: Skeleton Plugin

**Goal:** A minimal plugin that registers with Mogan and appears in menus.

**Files:**

- `init-ai.scm` — Register the plugin:
  ```scheme
  (plugin-configure ai
    (:require #t)
    (:session "AI Assistant"))
  ```
- `ai-menus.scm` — Add a top-level "AI" menu with placeholder items
- `ai-kbd.scm` — Bind `C-M-a` (or similar) to invoke the AI assistant

**Milestone:** Plugin loads without errors; "AI" menu is visible in Mogan.

---

### Phase 2: Configuration and Provider Layer

**Goal:** Users can configure their API provider and key. The plugin can make HTTP requests to an LLM.

**Files:**

- `ai-config.scm`:
  - Store settings in `~/.TeXmacs/system/ai/` (following account plugin pattern)
  - Support fields: `provider` (openai / anthropic / ollama), `api-key`, `model`, `base-url`, `temperature`
  - Provide `ai-config-get` / `ai-config-set!` accessors
  - Add a settings dialog via `tm-widget`

- `ai-provider.scm`:
  - Format requests for OpenAI Chat Completions API (`/v1/chat/completions`)
  - Use `(liii http)` for transport:
    ```scheme
    (http-post base-url
      '()                                         ; params
      (ai-build-request-body messages model)      ; JSON body
      `(("Authorization" . ,(string-append "Bearer " api-key))
        ("Content-Type" . "application/json"))    ; headers
      '())                                        ; proxy
    ```
  - Parse JSON response to extract assistant message
  - Streaming variant using `http-stream-post` with a callback that appends tokens

**Milestone:** Calling `(ai-complete "Hello")` from the Scheme REPL inside Mogan returns an LLM response.

---

### Phase 3: Editor Context Extraction

**Goal:** The AI can see what the user is working on.

**Files:**

- `ai-context.scm`:
  - `(ai-get-selection)` — return the current selection as a string
  - `(ai-get-buffer-text)` — return the full buffer content
  - `(ai-get-surrounding n)` — return n paragraphs around the cursor
  - `(ai-get-mode)` — return current editing mode (math, text, code, etc.)
  - `(ai-get-document-tree)` — return the document tree (s-expression form)
  - Context is injected into the system prompt or user message depending on the action

**Key Mogan APIs used:**
- `(selection-tree)` — get selected tree
- `(tree->stree ...)` — convert tree to s-expression
- `(buffer-get-body (current-buffer))` — get document body
- `(get-env "mode")` — get current mode (math/text)
- `(cursor-path)` — get cursor position

**Milestone:** `(ai-get-selection)` returns highlighted text; `(ai-get-mode)` returns "math" or "text".

---

### Phase 4: Core AI Actions

**Goal:** Implement the main user-facing AI operations.

**Files:**

- `ai-core.scm` — orchestration functions:

| Function | Description |
|----------|-------------|
| `(ai-ask prompt)` | Free-form question, show response in a new buffer or below cursor |
| `(ai-ask-about-selection)` | Ask the AI about the highlighted text |
| `(ai-rewrite-selection style)` | Rewrite selection (formal, concise, expanded, etc.) |
| `(ai-translate-selection lang)` | Translate selected text to target language |
| `(ai-generate-latex description)` | Generate LaTeX/math from natural language description |
| `(ai-explain-math)` | Explain the selected math expression in natural language |
| `(ai-complete-text)` | Continue writing from cursor position |
| `(ai-fix-grammar)` | Fix grammar/spelling in selection |

- Each action:
  1. Extracts relevant context via `ai-context.scm`
  2. Builds a messages list (system + context + user prompt)
  3. Calls `ai-provider.scm` to get the response
  4. Inserts or replaces content in the document

**Milestone:** User selects text, presses a shortcut, and the AI rewrites it in place.

---

### Phase 5: AI Chat Session

**Goal:** An interactive session widget (like Python/Maxima sessions) for multi-turn conversation.

**Approach:**

- Define an AI session type using `plugin-configure` with `:session "AI Assistant"`
- The session maintains a conversation history (list of `(role . content)` pairs)
- User input is serialized, sent to the LLM along with history, and the response is displayed
- Support streaming: tokens appear incrementally in the session output area

**Key integration points:**
- `plugin-serialize` — convert user input to the API format
- `connection-notify` — display responses back in the session
- Session type package in `packages/session/ai.ts`

**Milestone:** User opens "AI Assistant" session, types questions, and gets streaming responses.

---

### Phase 6: Polish and UX

**Goal:** Production-ready experience.

**Items:**
- Error handling: network failures, API rate limits, invalid keys — show user-friendly messages
- Loading indicators while waiting for responses
- Token/cost estimation display (optional)
- Conversation history persistence (save/load chat sessions)
- Prompt templates: let users define custom prompt templates in `~/.TeXmacs/system/ai/prompts/`
- Keyboard shortcuts overview in help menu
- Preferences dialog for all settings

---

## Key Technical References

| Component | File Path |
|-----------|-----------|
| Plugin configuration macro | `mogan/TeXmacs/progs/kernel/texmacs/tm-plugins.scm` |
| Plugin command/serialization | `mogan/TeXmacs/progs/utils/plugins/plugin-cmd.scm` |
| Plugin evaluation engine | `mogan/TeXmacs/progs/utils/plugins/plugin-eval.scm` |
| HTTP library (Scheme) | `mogan/TeXmacs/plugins/goldfish/goldfish/liii/http.scm` |
| OAuth2/account reference | `mogan/TeXmacs/plugins/account/progs/liii/account.scm` |
| OCR/AI reference | `mogan/TeXmacs/plugins/account/progs/liii/ocr.scm` |
| Python plugin (session example) | `mogan/TeXmacs/plugins/python/progs/init-python.scm` |
| Maxima plugin (menu example) | `mogan/TeXmacs/plugins/maxima/progs/maxima-menus.scm` |

---

## Provider API Compatibility

The plugin targets the **OpenAI Chat Completions** format as the common interface:

```
POST /v1/chat/completions
{
  "model": "gpt-4",
  "messages": [
    {"role": "system", "content": "..."},
    {"role": "user", "content": "..."}
  ],
  "stream": true
}
```

Provider-specific adapters:

| Provider | Base URL | Notes |
|----------|----------|-------|
| OpenAI | `https://api.openai.com` | Native format |
| Anthropic | `https://api.anthropic.com` | Requires `anthropic-version` header, different message format |
| Ollama | `http://localhost:11434` | OpenAI-compatible endpoint at `/v1/chat/completions` |
| LM Studio | `http://localhost:1234` | OpenAI-compatible |

---

## Development Workflow

Following Mogan conventions from `CLAUDE.md`:

1. Create branch: `username/214_xx/ai-plugin-phase-N`
2. Develop and test locally within Mogan
3. Push directly with `git push` (no `gh` CLI)
4. Keep commits clear and focused

**Testing approach:**
- Load the plugin in Mogan's Scheme REPL for interactive testing
- Verify menu items, keyboard shortcuts, and session creation
- Test each AI action with mock responses before connecting to real APIs
- Test streaming with a local Ollama instance to avoid API costs

---

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| API keys stored insecurely | Follow account plugin pattern; store in `~/.TeXmacs/system/ai/`; never log keys |
| Network errors freeze the editor | Use async/streaming HTTP; add timeouts; show clear error messages |
| Large documents exceed token limits | Truncate context intelligently; send only relevant sections |
| Goldfish HTTP lacks needed features | Fall back to pipe-based approach with a thin Python/curl helper |
| Scheme JSON parsing limitations | Use Goldfish's built-in JSON support or implement minimal parser |

---

## Success Criteria

- [ ] Plugin loads cleanly in Mogan STEM without errors
- [ ] Users can configure API provider and key through a GUI dialog
- [ ] At least 3 AI actions work end-to-end (ask, rewrite, translate)
- [ ] Streaming responses display incrementally
- [ ] AI chat session works as a first-class Mogan session type
- [ ] Works with at least 2 providers (OpenAI + Ollama)
