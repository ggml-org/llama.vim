# Feature Specification: Instruct Block Editing

## Overview

*Compatibility:* This feature works in both classic Vim (7.4+) and Neovim (0.5+), using only Vimscript APIs that are supported across both editors.

## Overview
The **Instruct Block Editing** feature allows users to select a range of lines in a buffer and apply a natural‑language instruction to transform that block.  Typical instructions include:
- "Translate to French"
- "Add comments explaining how this code works"
- "Refactor this function to be more Pythonic"
- "Fix the indentation"

The plugin will send the selected lines together with the instruction to the Llama inference backend, receive the transformed text, and replace the original block.

## User Workflow
1. **Select a block** – Use visual mode (`v`/`V`/`Ctrl‑V`) or a range motion (`:10,20`).
2. **Trigger the command** – `:LlamaInstruct` (or the mapped key `<leader>li`).
3. **Enter instruction** – A prompt opens (via `input()`), the user types the instruction.
4. **Processing** – The plugin sends a request to the LLM, showing a spinner/status line.
5. **Replace** – The response replaces the original selection, preserving the cursor position.

## Design Details
### Vimscript API
- **Command**: `command! -range=% LlamaInstruct call llama#instruct(<line1>, <line2>)`
- **Function**: `llama#instruct(start, end)`
  - Retrieves the selected lines with `getline(start, end)`.
  - Calls the core async API `llama#send_instruct(lines, instruction, callback)`.
  - The callback replaces the range using `setline(start, result)` and deletes any extra lines with `deletebufline` if the result has fewer lines.

### Async Communication
- Uses the existing async job infrastructure (`llama#job_start`) to avoid blocking the UI.
- The request payload is a JSON object:
  ```json
  {"instruction":"<user instruction>","input":"<selected text>"}
  ```
- The response is plain text containing the transformed block.

### Configuration Options (`g:llama_instruct`) 

### Configuration Changes for Instruct Endpoint
- The existing `config.endpoint` used for the FIM (Fill‑in‑the‑Middle) API will be renamed to `config.endpoint_fim`.
- A new property `config.endpoint_inst` will be introduced for the instruction endpoint, which follows the same HTTP request format as the FIM endpoint (JSON payload with `instruction` and `input`).
- These changes are **design‑only notes**; actual code modifications will be implemented later.

### Model Configuration Changes for Instruct Endpoint
- The existing `config.model` will be renamed to `config.model_fim`.
- A new property `config.model_inst` will be introduced for the instruction mode, defaulting to the same model file unless overridden.
- These changes are **design‑only notes**; code updates will be applied later.

### Development notes

- **Endpoint changes**
  - Rename `config.endpoint` to `config.endpoint_fim`.
  - Add new `config.endpoint_inst` for instruction endpoint (same JSON format as FIM).

- **Model changes**
  - Rename `config.model` to `config.model_fim`.
  - Add new `config.model_inst` for instruction mode (defaults to same model file).

These items are design‑only notes; actual code updates will be added later.

### Error handling
- If the backend returns an error, display it via `echoerr` and leave the original block untouched.
- Timeout (default 30 s) can be configured via `g:llama_instruct.timeout`.

## Example Usage
```vim
" Select lines 5‑10 and translate to French
:5,10LlamaInstruct
" Prompt appears: Translate to French
```
Result:
```text
# French translation of the original block appears here
```

## Documentation & Tests
- Add entry to `:help llama-instruct`.
- Unit tests (`test/llama_instruct_spec.vim`) covering:
  - Successful transformation replaces the range correctly.
  - Handles longer/shorter output than input.
  - Proper error propagation.
  - Async behavior does not block UI.

## Future Extensions
- Support multiple selections (via visual block mode).
- Add `g:llama_instruct.prompts` table for predefined shortcuts (e.g., `"comment": "Add explanatory comments"`).
- Integration with the existing `llama#apply` workflow for batch processing.

---
*Specification authored by the development team, 2026-01-18.*