# Multi-Pass Code Review Strategy

## Overview

Each component undergoes 10 independent Claude Code review passes. Each pass focuses on a specific aspect to ensure comprehensive coverage without overlap bias.

## Components to Review

1. `foo_jl_simplaylist_mac` - Playlist view with album grouping
2. `foo_jl_plorg_mac` - Tree-based playlist organizer
3. `foo_jl_wave_seekbar_mac` - Audio visualization seekbar
4. `foo_jl_scrobble_mac` - Last.fm scrobbler

---

## Review Passes (Per Component)

### Pass 1: Memory Management
Focus: Retain cycles, leaks, ownership semantics
```
Review all Objective-C code for:
- Strong reference cycles (controller <-> view <-> delegate)
- Missing weak/unowned references in blocks
- ARC edge cases with Core Foundation bridging
- Proper cleanup in dealloc/deinit
- Observer removal (NSNotificationCenter, KVO)
```

### Pass 2: Thread Safety
Focus: Concurrency issues, race conditions
```
Review for:
- Main thread UI access (dispatch_async requirements)
- Shared state accessed from callbacks
- foobar2000 callback thread assumptions
- Lock ordering and potential deadlocks
- Atomic operations where needed
```

### Pass 3: Error Handling
Focus: Edge cases, failure modes, robustness
```
Review for:
- Nil/null checks before method calls
- Optional unwrapping safety
- API failure handling (network, file I/O)
- Graceful degradation on errors
- User-visible error messages vs silent failures
```

### Pass 4: SDK Contract Compliance
Focus: Correct use of foobar2000 SDK patterns
```
Review for:
- Correct callback registration/unregistration lifecycle
- Proper use of service_ptr vs raw pointers
- GUID uniqueness and correctness
- Component version macros
- Menu/command registration patterns
```

### Pass 5: Performance
Focus: Efficiency, unnecessary work, optimization
```
Review for:
- Unnecessary redraws/reloads
- Expensive operations in tight loops
- Lazy initialization opportunities
- Caching of computed values
- String formatting in hot paths
```

### Pass 6: UI/UX Consistency
Focus: Visual design, interaction patterns
```
Review for:
- Consistent styling with foobar2000 native UI
- Proper dark mode support
- Keyboard accessibility
- Responsive layout (resize handling)
- Context menu consistency
```

### Pass 7: Configuration Persistence
Focus: Settings storage, migration, defaults
```
Review for:
- Correct configStore key naming
- Default value handling
- Settings migration between versions
- Config validation
- Preference UI sync with stored values
```

### Pass 8: Code Structure
Focus: Architecture, maintainability, clarity
```
Review for:
- Class responsibilities (single purpose)
- Method length and complexity
- Naming clarity
- Code duplication opportunities
- Dead code removal
```

### Pass 9: Security
Focus: Input validation, injection, sensitive data
```
Review for:
- User input sanitization
- URL/path validation
- Credential handling (Last.fm API key)
- SQL injection (if using SQLite)
- Command injection risks
```

### Pass 10: Documentation & Logging
Focus: Comments, console output, debugging
```
Review for:
- Critical algorithm documentation
- Public API documentation
- Console log verbosity levels
- Debug information exposure
- Copyright/license headers
```

---

## Execution Instructions

### Running Independent Passes

Each pass should be run in a **fresh Claude Code session** to avoid bias from previous findings:

```bash
# Example: Run Pass 1 on SimPlaylist
claude "Perform a focused code review of extensions/foo_jl_simplaylist_mac focusing ONLY on Memory Management. Look for retain cycles, leaks, ownership semantics, ARC issues, observer cleanup. List all findings with file:line references and severity (critical/high/medium/low). Do not review other aspects."
```

### Batch Execution Script

Create individual review sessions:

```bash
#!/bin/bash
# review_component.sh <component> <pass_number>

COMPONENT=$1
PASS=$2
OUTPUT_DIR="code_reviews/${COMPONENT}"
mkdir -p "$OUTPUT_DIR"

PROMPTS=(
    "Memory Management: retain cycles, leaks, ownership, ARC, observer cleanup"
    "Thread Safety: main thread UI, race conditions, callback threads, deadlocks"
    "Error Handling: nil checks, optional safety, API failures, graceful degradation"
    "SDK Contract: callback lifecycle, service_ptr, GUIDs, registration patterns"
    "Performance: unnecessary work, caching, hot paths, lazy initialization"
    "UI/UX Consistency: styling, dark mode, keyboard access, resize handling"
    "Configuration: configStore keys, defaults, migration, validation"
    "Code Structure: responsibilities, complexity, naming, duplication, dead code"
    "Security: input validation, credentials, injection risks"
    "Documentation: comments, logging, debug info, headers"
)

PROMPT="${PROMPTS[$((PASS-1))]}"

echo "Reviewing $COMPONENT - Pass $PASS: $PROMPT"
# Run in fresh session, save output
```

---

## Aggregation Process

After all 10 passes complete for a component:

1. **Collect Findings**
   - Gather all findings from each pass
   - Note file:line references

2. **Deduplicate**
   - Merge findings that reference the same code
   - Combine related issues

3. **Categorize by Severity**
   - Critical: Crashes, data loss, security vulnerabilities
   - High: Functional bugs, memory leaks
   - Medium: Performance issues, code quality
   - Low: Style, documentation

4. **Prioritize Fixes**
   - Critical issues first
   - Group related fixes
   - Consider dependency order

5. **Create Fix Plan**
   - One task per issue group
   - Include test verification

---

## Output Template

Each pass should produce output in this format:

```markdown
# Code Review: [Component] - Pass [N]: [Focus Area]

## Summary
- Files reviewed: X
- Issues found: Y (X critical, Y high, Z medium)

## Findings

### [Finding Title]
- **Severity**: Critical/High/Medium/Low
- **Location**: `path/to/file.mm:123`
- **Issue**: Description of the problem
- **Recommendation**: Suggested fix
- **Code Example**:
```objc
// Before
problematic_code();

// After
fixed_code();
```

---

## Final Aggregated Review

After all passes, create:

```markdown
# [Component] Code Review Summary

## Statistics
- Total passes: 10
- Total findings: XX
- Critical: X, High: Y, Medium: Z, Low: W

## Priority Fix List
1. [Critical] Memory leak in X - Pass 1, Finding 3
2. [Critical] Race condition in Y - Pass 2, Finding 1
3. [High] Missing error handling in Z - Pass 3, Finding 2
...

## Implementation Order
1. Fix memory issues (Pass 1 findings)
2. Fix thread safety (Pass 2 findings)
3. ...
```

---

## Notes

- Each pass runs in isolation - no shared context between passes
- Findings may overlap - deduplication happens during aggregation
- Some passes may find no issues - that's good, document it
- Focus on actionable findings, not style nitpicks
- Reference SDK patterns from `knowledge_base/` when relevant
