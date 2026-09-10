# AutoOps Resolver — PowerShell Edition

**Operator-focused infrastructure automation for repeatable server diagnostics, recovery workflows, and technical handoffs.**

AutoOps Resolver started from a practical operations problem: investigating an unhealthy server often means repeating the same sequence of checks across host connectivity, DNS, management interfaces, metadata, and recovery tooling.

This project brings those steps into a PowerShell workflow that validates the target, gathers evidence, runs the selected operation, and produces a consistent result that can be used by an engineer or added to a support record.

## What this project demonstrates

- PowerShell automation for infrastructure operations
- modular orchestration of external tools and scripts
- Redfish / BMC management workflows
- DNS, SSH, host, and management-path troubleshooting
- PXE / Cobbler-oriented recovery logic
- validation before state-changing actions
- structured operator output and repeatable troubleshooting
- integration of Windows-side automation with Linux/infrastructure tooling

The project is useful as a portfolio example for **CloudOps, DevOps, infrastructure support, systems engineering, and automation roles**.

## Problem the tool addresses

A server that appears “down” can fail at several different layers:

```text
Operator request
      |
      v
Target validation
      |
      +--> DNS / hostname checks
      +--> host reachability
      +--> SSH path
      +--> BMC / management interface
      +--> metadata consistency
      |
      v
Selected diagnostic or recovery action
      |
      v
Post-action validation
      |
      v
Operator summary / handoff notes
```

The goal is not to treat every failure as the same problem. The workflow helps separate network, operating-system, management-plane, metadata, and recovery-path issues before an engineer decides what to do next.

## Core capabilities

### Host and network diagnostics

- hostname / site validation
- host reachability checks
- SSH availability checks
- DNS validation
- BMC / management-interface reachability
- host and management metadata checks

### Management-plane operations

The script contains workflows around server-management tooling such as:

- Redfish-based power operations
- BMC restart / health workflows
- boot and recovery operations
- management-interface validation

State-changing actions are treated differently from read-only diagnostics. The workflow validates context first and expects follow-up checks after execution.

### PXE / Cobbler recovery paths

The project includes logic for infrastructure recovery workflows that use PXE/Cobbler-style tooling, including checks around the selected target and post-action state.

### Operator workflow

A typical execution follows this pattern:

1. Validate the requested target and context.
2. Gather host and management metadata.
3. Check network and access paths.
4. Execute the requested diagnostic or recovery operation.
5. Capture output and failures.
6. Validate the resulting state where possible.
7. Produce a concise technical summary for the next action or handoff.

## Technology

- **PowerShell 7**
- **Redfish APIs / management utilities**
- **SSH and remote command execution**
- **DNS / network diagnostics**
- **BMC tooling**
- **PXE / Cobbler workflows**
- **Python and Bash helpers** where appropriate
- browser-side support tooling through **Tampermonkey** for related operator workflows

## Engineering decisions

### Validate before changing state

A state-changing action should not be the first diagnostic step. The workflow checks the target and available evidence before invoking recovery operations.

### Separate execution from outcome

A command returning successfully does not necessarily mean the server or service is healthy. AutoOps keeps execution evidence separate from the postcondition that the operator actually cares about.

### Keep functions modular

The PowerShell implementation uses focused functions for different checks and operations so that failures can be interpreted individually and the same logic can be reused in other interfaces.

### Preserve human control

This is an operator tool, not an autonomous remediation system. The script supports investigation and controlled actions, while the engineer remains responsible for choosing the appropriate operation and validating the result.

## Repository structure

The main implementation is contained in:

```text
Autoops-Automation.ps1
```

The script includes the orchestration and helper functions used for diagnostics, management operations, browser-support setup, and sequential recovery logic.

## Example workflow

A simplified operator scenario might look like:

```text
Target: server123.example.com

[Validation]
Hostname accepted
Site/context accepted

[Connectivity]
Host reachable: no
DNS resolution: yes
BMC reachable: yes

[Management]
Power state retrieved successfully

[Action]
Operator selects approved recovery step

[Validation]
Host path checked again
Result summarized for follow-up
```

The exact commands and environment-specific values depend on the infrastructure where the tool is adapted.

## Security and portability

The public repository uses sanitized/example infrastructure values. Real credentials, internal production endpoints, and environment-specific secrets should be supplied outside source control.

For reuse in another environment, the key adaptation points are:

- target naming rules;
- management endpoints;
- authentication / credentials;
- metadata sources;
- approved recovery operations;
- post-action health checks.

## Related project

The same automation problem was later explored through a C#/.NET web interface in the **Web AutoOps Resolver** project, where request handling, background execution, status tracking, and operator-facing presentation become part of the design.

## Skills demonstrated

- infrastructure automation
- PowerShell engineering
- troubleshooting across host / network / management layers
- API and command-line integration
- safe automation design
- recovery validation
- operational documentation
- cross-platform systems work

## Author

**Josue David Cruz Lopez**  
Costa Rica  
GitHub: [@josuecross](https://github.com/josuecross)  
LinkedIn: [josue-david-c](https://www.linkedin.com/in/josue-david-c/)
