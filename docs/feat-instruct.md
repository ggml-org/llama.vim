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
1. **Select a block** – Use linewise visual mode (`V`/Shift+V) or a range motion (`:10,20`).
2. **Trigger the command** – `:LlamaInstruct` (or the mapped key `<leader>li`).
3. **Enter instruction** – A prompt opens (via `input()`), the user types the instruction.
4. **Processing** – The plugin sends a request to the LLM, showing a spinner/status line.
5. **Replace** – The response replaces the original selection.

## Design Details
### Vimscript API
- **Command**: `command! -range=% LlamaInstruct call llama#instruct(<line1>, <line2>)`
- **Function**: `llama#instruct(start, end)`
  - Retrieves the selected lines with `getline(start, end)`.
  - Calls the core async API `llama#send_instruct(lines, instruction, callback)`.
  - The callback replaces the range using `setline(start, result)` and deletes any extra lines with `deletebufline` if the result has fewer lines.

### Async Communication
- Uses the existing async job infrastructure (`llama#job_start`) to avoid blocking the UI.
- The request payload follows the OpenAI `/v1/chat/completions` schema. It contains a `system` message that sets the assistant’s role and a `user` message that packs the instruction, range information, surrounding context, and the selected text.

  Example `messages` array (in JSON):
  ```json
  {
    "role": "system",
    "content": "You are a code‑editing assistant. Return ONLY the new content for the requested block."
  },
  {
    "role": "user",
    "content": "--- instruction ------------------------------------------------\nAdd explanatory comments.\n--- range -------------------------------------------------------\nstart_line: 12\nend_line: 15\n--- surrounding context (optional) -------------\nbefore:\n10: def compute(a, b):\n11: \"\"\"Compute something\"\"\"\nafter:\n16: return result\n--- extra context (ring buffer) -------------\n<extra_context_from_ring_buffer>\n--- selected block ---------------------------------------------\n12: x = a + b\n13: y = a * b\n14: z = x / y\n15: return z\n--- end --------------------------------------------------------"
  }
  ```
  The LLM should return only the transformed block as plain text.
- The response is plain text containing the transformed block.

### State Management

The plugin will maintain an internal state for each edit request:

- **Range** – the start and end line numbers of the selected block.
- **Status** – one of `processing` (request sent), `generating` (receiving response), or `ready` (result available).

This state enables the UI to show progress indicators and to handle cancellations or retries.

### Highlighting active requests

For each active request, the plugin will highlight the corresponding lines using Neovim's **extmark** API. Extmarks anchor the highlight to the text, so if new lines are inserted or the buffer changes, the highlight stays attached to the original block. This ensures the user always sees which region is being processed.
- Create an extmark for the selected range when the request starts.
- Update the extmark's highlighting group based on the request **Status** (`processing`, `generating`, `ready`).
- Clear the extmark once the result is processed or the request is cancelled.

Multiple active requests can exist simultaneously in the same buffer. Each request gets its own independent extmark and status tracking, allowing overlapping or separate highlighted regions without interference.

### Cancellation
A request can be cancelled at any time by moving the cursor into the highlighted range and pressing <Esc> while in Normal mode. The plugin will detect this input, abort the pending async job, clear the extmark, and remove the request state.

This provides an intuitive way for users to stop an edit they no longer want.

### Acceptance
When a request reaches the **ready** state, the user can accept the generated edit by pressing `<Tab>` in Normal mode while the cursor is inside the highlighted range. The plugin will then replace the original block with the generated text, clear the extmark, and remove the request from the state tracking.

### Virtual lines visualization
While a request is in the **processing** or **generating** state, the plugin will display a block of virtual lines between the end of the edited range (`N1`) and the next line (`N1+1`). This block acts as a visual placeholder indicating that work is in progress.

- The virtual lines are rendered using Neovim's `nvim_buf_set_extmark` with the `virt_text` property (fallback to `matchadd`‑style virtual text in classic Vim).\n- When the request transitions to **ready**, the virtual block is replaced with the actual result text, showing the generated content inline before the user accepts it with `<Tab>`.\n- The virtual block updates dynamically if the result arrives in chunks or if the user scrolls, ensuring the placeholder stays correctly positioned relative to the original range.

This approach provides immediate feedback about ongoing processing without altering the buffer's real content until the user decides to apply the changes.

This approach works in both classic Vim (via `matchaddpos` fallback) and Neovim (via `nvim_buf_set_extmark`).

### Configuration Options (`g:llama_instruct`) 

### Development notes

- **Endpoint changes**
  - Rename `config.endpoint` to `config.endpoint_fim`.
  - Add `config.endpoint_inst`, an OpenAI‑compatible `/v1/chat/completions` endpoint for instruction mode.
- **Model changes**
  - Rename `config.model` to `config.model_fim`.
  - Add `config.model_inst` for instruction mode (defaults to same model file).

These items are design‑only notes; actual code updates will be added later.


### Error handling
- If the backend returns an error, display it via `echoerr` and leave the original block untouched.
- Timeout (default 30 s) can be configured via `g:llama_instruct.timeout`.


*Specification authored by the development team, 2026-01-18.*