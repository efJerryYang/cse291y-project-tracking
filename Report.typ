#import "@preview/charged-ieee:0.1.4": ieee

#show: ieee.with(
  title: [Preemptive Threading in Wasmtime],
  abstract: [
    WebAssembly (WASM) runtimes are expected to support concurrency models but current implementations mainly rely on cooperative mechanisms that require explicit yields inside code. This project explores a protoype design for preemptive threading inside Wasmtime, a widely used WASM runtime. Wasmtime today executes each WASM entry point on a lightweight fiber that includes its own stack and register context, enabling fiber suspension/resumes, but without automatic preemption. Our project extends Wasmtime by integrating two preemption mechanisms. The first uses Wasmtime's epoch interruption facility to trigger safe suspension points and force fiber level context switches. The second uses a fuel based approach that slices execution deterministically by instruction count and removes the need for a background timing thread. On top of these mechanisms, we....

    We evaluate the behavior of both preemptive threading approaches and show that the runtime can be tested on alternating infinite loops compiled to WASM without cooperation from our guest code. Our results demonstrate that preemption at the fiber level is possible 
  ],
  authors: (
    (
      name: "Jerry Yang",
      department: [CSE M.S.],
      organization: [University of California, San Diego],
      location: [San Diego, California],
      email: "jiy112@ucsd.edu"
    ),
    (
      name: "Blake Muxlow",
      department: [CSE M.S.],
      organization: [University of California, San Diego],
      location: [San Diego, California],
      email: "bmuxlow@ucsd.edu"
    ),
  ),
  index-terms: ("Scientific writing", "Typesetting", "Document creation", "Syntax"),
  // bibliography: bibliography("refs.bib"),
)

= Introduction
Modern runtimes depend on preemptive scheduling to handle bounded latency and predictable fairness to code. In this, a scheduler can forcibly interrupt any running task and allocate processor time to other tasks, ensuring that no single ill-defined or compute-intensive task can monopolize system resources. This is necessary in building systems where fairness guarantees are essential. As WebAssembly (WASM) expands beyond its initial browser sandbox into server computing and cloud environments, the need for preemptive control becomes increasingly critical. While cooperative threading (where tasks voluntarily yield control) offers lower overhead and simpler implementation, it suffers from the possibility of letting a single task starve all other tasks of execution time. 

Current WebAssembly runtimes primarily rely on cooperative threading that require explicit yield points within guest code. WebAssembly's stack-based execution model makes implementing non-preemptive threading difficult without explicit runtime support. Traditional operating system signal-based preemption techniques are problematic for JIT (Just in Time)compiled WebAssembly code and add complication with asynchronous execution models. The WebAssembly threads specification doesn't explicitly talk about mechanisms for spawning threads, leaving the host environment responsible for thread creation while providing only tools for safe multi-threaded execution. 

This project addresses these limitations by implementing preemptive threading capabilities within Wasmtime, a WASM runtime maintained by the Bytecode Alliance. We explore two complementary approaches to achieve preemption.

1. Epoch-based interruptions - leverages clock time for lightweight timeslicing, 

2. Fuel-based interruptions - provide deterministic instruction-counting

Our work demonstrates that preemptive scheduling can be integrated at the fiber level within Wasmtime's architecture without requiring modifications to guest code.
= Background
WebAssembly is a portable binary instruction format designed as a compilation target for high-level languages, providing near-native performance in a sandboxed execution environment. Initially developed for web browsers, WebAssembly has evolved into a general-purpose runtime capable of executing code across diverse environments from IoT devices to cloud infrastructure. A key design principle of WebAssembly is portability with security: code compiled to WASM can run on any compliant runtime while maintaining strong isolation guarantees.

Wasmtime is a standalone runtime for WebAssembly, WASI (WebAssembly System Interface), and the Component Model developed by the Bytecode Alliance. Built on Rust's memory safety guarantees, Wasmtime compiles WebAssembly modules to native machine code using the Cranelift code generator, enabling efficient execution with cold start times under one millisecond. Wasmtime's internal architecture centers around several key abstractions. The `wasmtime::Module` represents a compiled WebAssembly module, with all modules compiled AOT (ahead of time) or JIT to native code via Cranelift. At runtime, `InstanceHandle` values serve as the primary representation, with the `wasmtime::Store` managing all active instances and their lifetimes. An additional detail for our work is that Wasmtime executes each WebAssembly entry point on a lightweight *fiber*: a userspace thread with its own stack and register context—enabling suspension and resumption of execution without full operating system thread overhead.


= Methods
= Experiments/Analysis
= Related Work
= Future Work
= Conclusion
