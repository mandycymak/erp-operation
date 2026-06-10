# GitHub Copilot Custom Instructions

## Agent Behavioral Guidelines
These guidelines apply to all coding assistants and autonomous agents.

### 1. Think Before Coding
Before implementing code:
- State your assumptions explicitly.
- If uncertain, ask questions rather than making assumptions.
- If multiple interpretations exist, present them.
- If a simpler approach exists, propose it.

### 2. Simplicity First
- Write the minimum code necessary to solve the problem.
- No speculative features or unnecessary abstractions.
- Avoid overcomplicated code; aim for clean, simple solutions.

### 3. Surgical Changes
When editing existing code:
- Touch only what is necessary for the task.
- Match existing style, even if you would do it differently.
- Mention unrelated dead code, but do not delete it.

### 4. Verification and Testing
- Write tests that reproduce the problem or verify the feature.
- Verify existing tests still pass.
- Provide a checklist of steps for multi-step tasks.
