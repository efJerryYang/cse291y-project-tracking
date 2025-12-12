# CSE291Y Project - Preemptive Threading in Wasmtime

**Topics**: Multi-tasking support in user-level threads (fibers) of Wasmtime, primarily focusing on context switch (sync/async handling) and scheduling behavior.
**Team**: [@efJerryYang](https://github.com/efJerryYang), [@Blek1](https://github.com/Blek1)

**Upstream**: [Wasmtime](https://github.com/bytecodealliance/wasmtime)

- Code Update: https://github.com/efJerryYang/wasmtime/tree/dev-preempt-rewrite
- Note: at the moment, the fork is way behind the upstream due to conflicts, will only try to resolve it when we actually at the stage of submitting the PR.

<!-- **Milestones**: Check out the **[Projects](https://github.com/efJerryYang/cse291y-project-tracking/projects?query=is%3Aopen)** tab for more details: -->

<!-- 1. ramp-ups: both of us will first work on some simple existing/wip issues in this repository to get an understanding of this project, some related to cranelift codegen, some related to wasmtime runtime. we will have a better understanding of the problems to solve after this stage.
2. the shared memory issues (what the problems are, what we can solve in this quarter, any open questions we may don't have time to deal with at the moment)
3. the verification of threading implementation (why it is an open question for testing threading, what we can do to help with verification and testing) -->

**NOTE**: Please don't directly reference the upstream issue/PR URLs, it will cause numerious cross-reference in the upstream repository and cannot be removed unless we delete those issues/PRs from this repository. Some issues with those URLs have been recreated to avoid cross-references in upstream.
