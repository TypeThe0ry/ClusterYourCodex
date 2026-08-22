# Platform model

Platform differences are represented as data and adapters rather than branches
spread throughout the controller.

## Supported vocabulary

```text
OS:            windows | linux | macos
Architecture:  x86_64 | aarch64
Shell:         powershell | cmd | bash | zsh
Transport:     local | managed-worker | ssh
GPU vendor:    nvidia | amd | intel | apple
```

Capabilities use versioned names such as:

```text
tool.git
tool.cmake
tool.msvc
tool.xcode
runtime.docker
runtime.podman
runtime.cuda
runtime.rocm
runtime.metal
language.rust
language.node
language.python
language.java
```

## Native execution

The controller transfers a native script file and a structured manifest. It
does not construct nested PowerShell-to-CMD-to-Bash command strings. Each
executor owns quoting, environment construction, exit-code capture, and
cancellation for one platform.

## Paths

Paths remain opaque strings in the protocol. The platform executor validates
and resolves them. Product defaults are selected at install time and are never
compiled into the scheduler.

## Capability evidence

Every detected capability records its source and observation time. Dynamic
facts such as free memory, disk, GPU memory, and load expire. A failed optional
probe does not make the entire node unavailable.

