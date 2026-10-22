#!/usr/bin/env bash
# =============================================================================
# Tool definitions for the LLM (OpenAI function-calling schema)
# =============================================================================

TOOLS_JSON='[
  {
    "type": "function",
    "function": {
      "name": "edit_file",
      "description": "Edit an existing file by replacing a specific text section. The search text must match the current file contents exactly (whitespace, indentation, punctuation). Keep the search text as small as possible while still being unique in the file.",
      "parameters": {
        "type": "object",
        "properties": {
          "path": {
            "type": "string",
            "description": "Relative path to the file from the repo root (e.g., src/main.py)"
          },
          "search": {
            "type": "string",
            "description": "The exact text to find in the file. Must match verbatim including whitespace and indentation. Should be the minimal unique substring that identifies the location."
          },
          "replace": {
            "type": "string",
            "description": "The replacement text. This will replace the search text exactly."
          }
        },
        "required": ["path", "search", "replace"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "create_file",
      "description": "Create a brand-new file. Use this only for files that do not exist yet. For editing existing files, use edit_file instead.",
      "parameters": {
        "type": "object",
        "properties": {
          "path": {
            "type": "string",
            "description": "Relative path for the new file from the repo root (e.g., tests/test_new.py)"
          },
          "content": {
            "type": "string",
            "description": "The complete contents of the new file."
          }
        },
        "required": ["path", "content"]
      }
    }
  }
]'
