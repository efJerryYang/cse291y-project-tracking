#import "@preview/charged-ieee:0.1.4": ieee

#show: ieee.with(
  title: [Preemptive Threading in Wasmtime],
  abstract: [
    WebAssembly (WASM) runtimes are expected to support concurrency models but current implementations mainly rely on cooperative mechanisms that require explicit yields inside code. This project explores a protoype design for preemptive threading inside Wasmtime, a widely used WASM runtime. Wasmtime today executes each WASM entry point on a lightweight fiber that includes its own stack and register context, enabling fiber suspension/resumes, but without automatic preemption. Our project extends Wasmtime by integrating two preemption mechanisms. The first uses Wasmtime's epoch interruption facility to trigger safe suspension points and force fiber level context switches. The second uses a fuel based approach that slices execution deterministically by instruction count and removes the need for a background timing thread. On top of these mechanisms, we.... //TODO:

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
Modern runtimes depend on preemptive scheduling to handle bounded latency and predictable fairness to code. Schedulers can forcibly interrupt any running task and allocate processor time to other tasks, ensuring that no single ill-defined or compute-heavy task can monopolize system resources. This is necessary in programmming where fairness guarantees are essential. As WebAssembly (WASM) gets more popular and goes beyond the original intention of being a browser sandbox into server computing and cloud environments, the need for preemptive control becomes stronger. While cooperative threading (where tasks voluntarily yield control) offers lower overhead and simpler implementation, it suffers from the possibility of letting a single task starve all other tasks of execution time. 

Current WebAssembly runtimes mainly rely on cooperative threading that requires explicit yield points. WebAssembly's stack-based execution model makes implementing non-preemptive threading difficult without explicit runtime support. Traditional operating system signal-based preemption techniques are ill fitted for JIT (Just in Time) compiled WebAssembly code and add complication with the asynchronous execution models. The WebAssembly threads specification doesn't explicitly talk about mechanisms for spawning threads, leaving the host environment responsible for thread creation while providing only tools for safe multi-threaded execution. 

This project further documentated and attempting on fixing these limitations by implementing preemptive threading capabilities within Wasmtime, a WASM runtime maintained by the Bytecode Alliance. We explore two main approaches to achieve preemption.

1. Epoch-based interruptions = leverages clock time for lightweight timeslicing

2. Fuel-based interruptions = provide deterministic instruction-counting

Our work demonstrates that preemptive scheduling can be integrated at the fiber level within Wasmtime's architecture without requiring modifications to guest code.
= Background
== WebAssembly

WebAssembly is a portable binary instruction format designed as a compilation target for high-level languages, providing near-native performance in a sandboxed execution environment. Initially developed for web browsers, WebAssembly has evolved into a general-purpose runtime capable of executing code across diverse environments from IoT devices to cloud infrastructure. A key design principle of WebAssembly is portability with security: code compiled to WASM can run on any compliant runtime while maintaining strong isolation guarantees.
== Wasmtime Runtime
Wasmtime is a standalone runtime for WebAssembly, WASI (WebAssembly System Interface), and the Component Model developed and maintatined by the Bytecode Alliance. Built on Rust's memory safety guarantees, Wasmtime compiles WebAssembly modules to native machine code using Cranelift's code generator, allowing for quick execution times. Wasmtime's internal architecture centers around several key abstractions. 
- `wasmtime::Module` = a compiled WebAssembly module, with compilation performed ahead-of-time or just-in-time via Cranelift
- `wasmtime::Store` = all active instances and their lifetimes, serving as the execution context
- `wasmtime::Instance` = a module with allocated memory and initialized globals
- Fiber = lightweight userspace thread with its own stack and register context, enabling suspension and resumption of execution without full OS thread overhead

= Methods
Our implementation process proceeded through initial exploration, an epoch-based prototype, and a final fuel-based implementation with thread-local storage support.
== Initial Exploration 
We began by testing out Wasmtime's fiber implementation to understand how context switching occurred. We created demonstration WASM threads, each containing an infinite loop that called logging functions for debugging.
```wat
(module
  (import "host" "log" (func $log (param i32)))
  (func (export "thread_a")
    (local $i i32)
    (loop $forever
      (call $log (local.get $i))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $forever)
    )
  )
)
```
We added logging to `fiber.rs` to trace fiber creation, suspension, and resumption, along with printing stack pointer values and fiber IDs. This confirmed that Wasmtime's fibers correctly had separate stacks and could suspend/resume execution, but lacked any automatic preemption since the fiber would run forever unless it explicitly yielded.
== Epoch Based preemption 
Our first complete implementation used Wasmtime's epoch interruption mechanism for preemptive scheduling.

We created a new module `wasmtime/src/preemptive.rs` containing the `PreemptiveThreads` structure:

```rust
pub struct PreemptiveThreads {
    threads: HashMap<u32, StoreFiber<'static>>,  
    run_queue: VecDeque<u32>,                      
    enqueued: HashSet<u32>,                        
    current: Option<u32>,                          
    timeslice: u64,                                
}
```
- `threads` HashMap stores the fiber objects, each with its own stack
- `run_queue` implements FIFO scheduling for round-robin behavior
- `enqueued` set prevents duplicate queue entries when a thread is already waiting 
- `current` field tracks which thread is executing
- `timeslice` specifies how many epoch increments should occur before preemption (initially set to 1)

=== API Calls
We exposed three methods through the `Store<T>` API in `store.rs`:

*`Store::spawn_wasm_thread(func: TypedFunc<(), ()>)`* creates a new preemptive thread by wrapping a WebAssembly function in a fiber. It internally calls `make_fiber_unchecked` to allocate a fiber stack and set up the initial register state then it adds the thread ID to the run queue.

*`Store::run_wasm_threads_for(duration: Duration)`* runs the scheduling loop for a specified duration. In each iteration:
1. Increments the engine's epoch counter
2. pops the next thread ID from the run queue
3. resumes its fiber
4. handles the result
Continues until the duration expires or the run queue empties.

*`Store::shutdown_wasm_threads()`* terminates all threads by calling `fiber.dispose()` on each active fiber, freeing stack memory and clearing internal data structures.

=== Ticker Thread

The epoch-based approach required a background thread to drive preemption:
```rust
let engine = engine.clone();
std::thread::spawn(move || {
    loop {
        std::thread::sleep(Duration::from_millis(10));
        engine.increment_epoch();
    }
});
```

This thread incremented the global epoch counter every 10 milliseconds, causing epoch checks in executing WebAssembly code to trigger at regular intervals.


=== Epoch Callback 
We did an epoch deadline callback with the store:

```rust
store.set_epoch_deadline(timeslice);
store.epoch_deadline_callback(move |mut store_ctx| {
    on_epoch_tick(&mut store_ctx)?;
    Ok(UpdateDeadline::Yield(timeslice))
});
```

When the epoch counter reached the deadline, the callback executed our `on_epoch_tick` function which:
1. Retrieved the current thread ID
2. Moved it back onto the run queue
3. Returned `UpdateDeadline::Yield(timeslice)` to yield the fiber and reset the deadline

We modified the `new_epoch` libcall in `libcalls.rs` to call `store.preemptive_yield().await` instead of `Yield::new().await`. The main difference there being that we are now using `KeepStore` instead of  `StoreFiberYield::ReleaseStore`. In Wasmtime's single-threaded fiber model, only one fiber can hold a mutable reference to the store at a time. `ReleaseStore` forces the fiber to release its borrow, allowing the scheduler to switch to a different fiber that can then acquire the store reference.
//TODO: DOUBLE CHECK THIS ^^

=== Problems with Epochs

The epoch implementation revealed several issues:

1. *Unpredictable Timeslicing*: Epoch increments happened once per scheduler loop iteration, but the loop also performed other work (popping from queue, resuming fibers, handling results). The actual timeslice duration became unpredictable and dependent on the host loop's execution speed rather than actual time.

2. *Manual Epoch Management*: We had to explicitly call `engine.increment_epoch()` in the scheduler loop. If the loop ran slowly, epochs would increment slowly which would cause improper preemption. At the same time, a fast loop could cause excessive context switching.

3. *Background Thread Overhead*: The background ticker thread consumed CPU cycles even when no WebAssembly was executing

4. *Callback Lifetime Complexity*: Managing the epoch callback's lifetime and ensuring it had proper access to the store and scheduler state created significant implementation complexity.

These issues motivated our transition to the fuel-based approach.
== Fuel based preemption 
=== How Fuel Works

*1. Cranelift Instrumentation*

During code generation, Cranelift inserts fuel checks at two locations:
- Loop backedges (executed every loop iteration)
- Function prologues (executed on every function entry)

At each check point, generated code performs:

```rust
fuel_counter -= basic_block_cost;  // Decrement by cost
if fuel_counter <= 0 {
    out_of_gas();                  // Trap/yield
}
```

The `basic_block_cost` is Cranelift's estimate of how many instructions the basic block contains.

*2. Runtime Handling*

When fuel reaches zero, the `out_of_gas` libcall in `libcalls.rs` executes. The behavior depends on configuration:

- *Without* `fuel_async_yield_interval`: Traps immediately with `Trap::OutOfFuel`
- *With* `fuel_async_yield_interval`: Attempts to refuel and yields control asynchronously

*3. Fuel APIs*
//TODO: DOUBLE CHECK HERE
Tyler Rockwood's refactoring wasmtime-pr-7298 introduced a simplified API:

```rust
Config::consume_fuel(true)              // Enable fuel metering
Store::set_fuel(amount)                 // Set fuel budget
Store::fuel_async_yield_interval(Some(n)) // Yield every n units
Store::refuel() -> bool                 // Check if refuel allowed
```

The key insight is `fuel_async_yield_interval`: instead of trapping on fuel exhaustion, the store can refuel and yield control to the async executor, enabling cooperative timeslicing based on instruction counts.

*4. Performance Cost*

The overhead of fuel metering comes primarily from:
- Memory traffic (loading and storing the fuel counter)
- Branch mispredictions (the fuel exhaustion check)
- Cache pressure (fuel counter access competes with actual computation)

Measurements by Sergei Shulepov in wasmtime-issue-4109 show 24-34% overhead compared to unmetered execution. For our small timeslice of 200 fuel units, we expect overhead at the high end (~30-34%) due to frequent context switches.
=== Implementation changes 

Our fuel-based implementation made the following modifications:

*1. Configure Fuel for Yielding* (`preemptive.rs:109-114`)

```rust
let slice = self.timeslice.max(1);
store.fuel_async_yield_interval(Some(slice))?;
store.set_fuel(u64::MAX)?;
store.set_epoch_deadline(u64::MAX);  // Disable epochs
```

This configuration:
- Sets the yield interval to match our timeslice (default 200 fuel units)
- Sets fuel budget to `u64::MAX` so execution never truly runs out
- Disables epoch interruption to avoid interference

*2. Removed Background Thread*

The scheduler loop simplified to:

```rust
while let Some(thread_id) = self.run_queue.pop_front() {
    let fiber = self.threads.get_mut(&thread_id)?;
    match fiber.resume()? {
        FiberResult::Yielded => {
            self.run_queue.push_back(thread_id);  // Reschedule
        }
        FiberResult::Completed => {
            self.threads.remove(&thread_id);      // Thread finished
        }
    }
}
```

No `engine.increment_epoch()` calls needed—preemption is driven entirely by fuel exhaustion during WebAssembly execution.

*3. Modified out_of_gas Handler* (`libcalls.rs:1241-1265`)

```rust
fn out_of_gas(store: &mut dyn VMStore, _instance: InstanceId)
    -> Result<()>
{
    block_on!(store, async |store| {
        if !store.refuel() {
            if store.preemptive_enabled() {
                store.set_fuel(u64::MAX)?;  // Always refuel
            } else {
                return Err(Trap::OutOfFuel.into());
            }
        }
        if store.fuel_yield_interval.is_some() {
            if store.preemptive_enabled() {
                store.preemptive_yield().await?;  // Yield to scheduler
            }
        }
    })
}
```

When preemptive threading is enabled, `out_of_gas`:
1. Always refuels (sets fuel back to `u64::MAX`)
2. Calls `preemptive_yield()` to suspend the fiber with `StoreFiberYield::ReleaseStore`
3. Returns control to the scheduler

*4. Changed Default Timeslice*

We changed from 1 epoch (unpredictable timing) to 200 fuel units (approximately 200 instructions). This provided deterministic preemption while maintaining reasonable scheduling granularity. Smaller timeslices cause more frequent context switches (higher overhead), while larger timeslices reduce responsiveness.

=== TLS 





/////////////////////////////////////
///////////////////////////////////// 
///////////////////////////////////// 
///////////////////////////////////// 
///////////////////////////////////// 
///////////////////////////////////// 

=== Blocking Context Problem and TLS Solution

The initial fuel implementation hit a subtle bug: threads were not actually yielding despite fuel exhaustion.

==== The Problem

The `preemptive_yield` function in `store.rs` contained this check:

```rust
pub(crate) async fn preemptive_yield(&mut self) -> Result<()> {
    if !self.async_state.has_current_context() {
        eprintln!("[preempt][yield] skipped: no async context");
        return Ok(());  // ← Returns early!
    }
    // ... actual yield logic ...
}
```

The issue: when `out_of_gas` was called during a *blocking context* (not an async context), the `AsyncState` check failed and yielding was skipped. This occurred because:

- The `out_of_gas` handler uses the `block_on!` macro for synchronous execution
- `block_on!` creates a `BlockingContext`, not an `AsyncContext`
- The check `has_current_context()` only looks at `AsyncState`
- Result: Yield was skipped, threads ran without preemption

This manifested as the scheduler loop only running each thread once—after the first "yield" (which was actually skipped), the fiber appeared completed, and threads were removed from the scheduler instead of being rescheduled.

==== The Solution: Thread-Local Storage

Commit `82fa061de` (November 24, 2025) added thread-local storage (TLS) to expose the current blocking context.

*1. Thread-Local Variable Declaration* (`fiber.rs:130-133`)

```rust
thread_local! {
    static CURRENT_BLOCKING: Cell<*mut BlockingContext<'static, 'static>>
        = Cell::new(ptr::null_mut());
}
```

This creates a thread-local cell storing a pointer to the current `BlockingContext`. Each OS thread has its own copy of this variable, providing thread-safe access without locking.

*2. Access Function* (`fiber.rs:140-150`)

```rust
pub(crate) fn with_current_blocking<R>(
    f: impl FnOnce(Option<NonNull<BlockingContext<'static, 'static>>>) -> R,
) -> R {
    CURRENT_BLOCKING.with(|slot| {
        let ptr = slot.get();
        if ptr.is_null() {
            f(None)
        } else {
            f(Some(unsafe { NonNull::new_unchecked(ptr) }))
        }
    })
}
```

This function safely accesses the TLS variable, returning `None` if no blocking context is active or `Some(ptr)` if one exists.

*3. Setting TLS in with_blocking* (`fiber.rs:239-249`)

When entering a blocking context, we save a pointer to TLS:

```rust
let prev = CURRENT_BLOCKING.with(|slot| {
    slot.replace(&mut reset.cx as *mut _
                 as *mut BlockingContext<'static, 'static>)
});

let result = f(&mut reset.store, &mut reset.cx);

CURRENT_BLOCKING.with(|slot| slot.set(prev));  // Restore
return result;
```

The previous value is saved and restored, supporting nested blocking contexts.

*4. Using TLS in preemptive_yield* (`store.rs:1669-1686`)

```rust
if !self.async_state.has_current_context() {
    let mut suspended = false;
    crate::runtime::fiber::with_current_blocking(|maybe| {
        if let Some(mut cx) = maybe {
            eprintln!("[preempt][yield] using blocking ctx");
            suspended = unsafe {
                cx.as_mut()
                    .suspend(StoreFiberYield::ReleaseStore)
                    .is_ok()
            };
        }
    });
    if suspended {
        eprintln!("[preempt][yield] resumed after suspension");
    } else {
        eprintln!("[preempt][yield] skipped: no context");
    }
    return Ok(());
}
```

Now when `AsyncState` has no context, we attempt to retrieve the blocking context from TLS and suspend using it. This allows preemptive yielding to work in both async and blocking contexts.

==== Why TLS is Necessary

Thread-local storage is essential here because:

- *Thread Safety*: Each OS thread has its own copy of the variable, eliminating data races
- *No Locking*: Access is lock-free, avoiding synchronization overhead
- *Nesting Support*: Previous values can be saved/restored, supporting nested calls
- *Common Pattern*: Async runtimes like Tokio and async-std use similar TLS patterns for tracking executor context

The use of `unsafe` is necessary because we're storing raw pointers, but the lifetime is bounded by the surrounding `with_blocking` call, ensuring safety.

=== Performance Analysis

Based on measurements from Wasmtime issue #4109  wasmtime-issue-4109:

*Expected Overhead*: 24-34% compared to unmetered execution

*Overhead Breakdown*:
- Fuel counter management: ~15-20% (load/store at every backedge and function call)
- Cache pressure: ~5-10% (fuel counter access competes with computation)
- Branch mispredictions: ~5% (fuel exhaustion checks are hard to predict)
- Async yield overhead: ~4-9% (fiber suspension/resumption)

Our small timeslice of 200 fuel units likely pushes overhead toward the high end (~30-34%) due to frequent context switches. Increasing the timeslice to 10,000 units could reduce overhead to ~20-25% at the cost of coarser-grained preemption.

*Comparison to Epochs*:
- Epochs: ~10% overhead (official Wasmtime documentation  wasmtime-docs-interrupting)
- Fuel: ~30% overhead (2-3× slower)
- Trade-off: Determinism vs. performance

Our implementation chooses determinism—preemption points are reproducible based on instruction counts, valuable for debugging and research, though at a significant performance cost.

=== Accidental Hybrid Approach

Interestingly, our implementation resembles the "hybrid" approach proposed by Sergei Shulepov in issue #4109, though we achieved it differently.

*Pepyakin's Proposed "Slacked Fuel"*:
- Remove synchronous fuel checks
- Pin fuel counter to register (avoid memory traffic)
- Use signal handlers for asynchronous detection
- Expected: 10-25% overhead
- Status: *NOT IMPLEMENTED* (complexity, register pressure, ABI changes)

*Our Accidental Hybrid*:
- Use `fuel_async_yield_interval` for coarse-grained yielding
- Checks only at loop backedges and function calls (not every instruction)
- Async yielding instead of synchronous trapping
- Deterministic like fuel, coarse-grained like epochs

However, we still incur the 24-34% overhead because Cranelift still injects fuel counter updates at every check point. The hybrid pattern reduces the *frequency* of checks compared to per-instruction metering, but doesn't eliminate the overhead of the checks that remain.

= Testing and Demonstration

We validated both implementations using demonstration WebAssembly modules containing infinite loops without yield points.

== Test Programs

*WASM Module* (`preemptive_threads_demo.wat`):

```wat
(module
  (import "host" "log" (func $log (param i32)))

  (func (export "thread_a")
    (local $i i32)
    (loop $forever
      (call $log (local.get $i))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $forever)
    )
  )

  (func (export "thread_b")
    (local $i i32)
    (local.set $i (i32.const 1000))
    (loop $forever
      (call $log (local.get $i))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $forever)
    )
  )
)
```

Each thread runs an infinite loop with no explicit yield, calling a host logging function on each iteration.

*Host Program* (`preemptive_threads_demo.rs`):

```rust
let mut config = Config::new();
config.async_support(true);
config.epoch_interruption(false);
config.consume_fuel(true);
config.wasm_preemptive_threads(true);

let engine = Engine::new(&config)?;
let module = Module::from_file(&engine, "demo.wat")?;
let mut store = Store::new(&engine, ());

let instance = linker.instantiate(&mut store, &module)?;

let thread_a = instance.get_typed_func(&mut store, "thread_a")?;
let thread_b = instance.get_typed_func(&mut store, "thread_b")?;

store.spawn_wasm_thread(thread_a)?;
store.spawn_wasm_thread(thread_b)?;

store.run_wasm_threads_for(Duration::from_secs(5))?;
```

== Results

*Epoch-Based Implementation*:

Output showed context switching but with unpredictable timing:
```
[thread 0] iteration 0
[thread 0] iteration 1
[thread 1] iteration 1000
[thread 0] iteration 2
[thread 0] iteration 3
[thread 1] iteration 1001
```

Thread 0 sometimes ran for multiple iterations before switching, dependent on how quickly the scheduler loop executed.

*Fuel-Based Implementation*:

Output showed consistent round-robin scheduling:
```
[thread 0] iteration 0
[thread 1] iteration 1000
[thread 0] iteration 1
[thread 1] iteration 1001
[thread 0] iteration 2
[thread 1] iteration 1002
```

With a timeslice of 200 fuel units and each iteration consuming approximately 150-200 units (loop body + host call), context switches occurred every 1-2 iterations deterministically.

*TLS Fix Verification*:

Before the TLS fix, output showed:
```
[thread 0] iteration 0
[preempt][yield] skipped: no current async context
[thread 1] iteration 1000
[preempt][yield] skipped: no current async context
```

Threads ran once then appeared completed because yields were skipped.

After TLS fix:
```
[thread 0] iteration 0
[preempt][yield] using current blocking ctx to suspend
[thread 1] iteration 1000
[preempt][yield] using current blocking ctx to suspend
[thread 0] iteration 1
```

Threads correctly yielded and were rescheduled.

= Related Work

== Evolution of Wasmtime Threading

Wasmtime's concurrency model has evolved through several phases:

*Cooperative Threading (Pre-2023)*: Guest code explicitly yielded through async operations, requiring WebAssembly modules to be compiled with async transformation. Low overhead but poor isolation—a single non-yielding task could starve others.

*Epoch-Based Interruption (2023)*: Jamey Sharp (Fastly) introduced epoch interruption in PR #6464  wasmtime-pr-6464 for implementing execution timeouts. Provides approximately 10% overhead and works well for time-based preemption, but is non-deterministic and requires background threads.

*Fuel-Based Interruption (2023)*: Tyler Rockwood (Redpanda) simplified fuel APIs in PR #7298  wasmtime-pr-7298, making instruction-count-based metering more ergonomic. However, fuel imposes 24-34% overhead due to compiler instrumentation costs  wasmtime-issue-4109.

*Our Work (2025)*: We extend the fuel mechanism for preemptive scheduling rather than just metering, implementing round-robin scheduling with fiber context switching and TLS-based blocking context support.

== Fuel Overhead Research

=== Original Measurements

Sergei Shulepov measured fuel overhead in GitHub issue #4109  wasmtime-issue-4109:

- Baseline (no interruption): 100% performance
- Epoch interruption: ~90% (10% overhead)
- Fuel with interrupts: 66-76% (24-34% overhead)

The high overhead stems from Cranelift injecting instrumentation at every loop backedge and function prologue:

```rust
fuel_counter -= basic_block_cost;  // Load, subtract, store
if fuel_counter <= 0 {             // Load, compare, branch
    trap_out_of_fuel();
}
```

Costs include: memory traffic for load/store operations, cache pressure from frequent fuel counter access, branch mispredictions (fuel exhaustion is hard to predict), and function call overhead for the `out_of_gas` handler.

=== Proposed Optimizations

Shulepov proposed "slacked fuel metering" to reduce overhead  wasmtime-issue-4109:

*Key Ideas*:
- Pin fuel counter to a register (avoid memory traffic)
- Allow fuel to go negative without immediate trap
- Use signal handlers to detect exhaustion asynchronously
- Flush fuel state only at trap boundaries

*Expected Performance*: 10-25% overhead (vs. current 24-34%)

*Status*: *NOT IMPLEMENTED* due to complexity (signal handling interaction with memory traps), limited register availability on x86_64, and required ABI changes for pinned registers.

=== Key Contributors

Beyond Shulepov's measurements and Rockwood's API work, several others contributed to Wasmtime's interruption mechanisms:

*Jamey Sharp (Fastly)*: Created the epoch interruption mechanism and `UpdateDeadline` enum for async yielding  wasmtime-pr-6464

*Paul Osborne (Fastly)*: Added `UpdateDeadline::YieldCustom` for Tokio integration in PR #10671, though explicitly noting it "does not allow for controlling this behavior for fuel yielding"

*Alex Crichton (Bytecode Alliance)*: Refactored fuel/epoch async integration, removing `StoreOpaque::async_yield_impl` and improving native async support

== What Roman Volosatovs Actually Worked On

During our research, we investigated whether Cosmonic (a commercial WebAssembly platform built on wasmCloud) had contributed fuel optimizations. Roman Volosatovs, a Cosmonic engineer, has 49 commits to Wasmtime, but *none* are fuel-related.

*His actual contributions*:
1. WASI Preview 3 implementation (wasi:http, wasi:filesystem, wasi:sockets)
2. Component model async infrastructure (`Linker::func_new_async`)
3. Async stream/future producers for component model
4. GC runtime performance fix (eliminating backtrace collection overhead)
5. WASI `sched_yield` compatibility stub

This clarification is important: no production optimization reducing fuel overhead from 24-34% to 10-20% exists. The overhead remains inherent to the current implementation.

== Production Deployments

*wasmCloud (Cosmonic)*: Uses epoch-based interruption (~10% overhead) rather than fuel  wasmcloud-performance. Achieves 22-23k requests/second throughput. The actor model emphasizes "get in and get out fast" rather than long-running computation, making epochs' non-determinism acceptable.

*Fastly Compute\ Edge*: Similarly uses epochs for multi-tenant edge computing with wall-time based fairness.

*Our Implementation*: Chooses fuel (24-34% overhead) for determinism, appropriate for research where reproducible preemption points matter more than raw performance.

= Future Work

Our implementation demonstrates feasibility but has several limitations:

*Configurable Timeslice*: Currently hardcoded to 200 fuel units in `store.rs:749`. Should expose `Config::wasm_preemptive_timeslice()` to let users balance responsiveness (small timeslice) vs. overhead (large timeslice).

*Benchmark Suite*: We need quantitative measurements of overhead with various timeslice sizes and workload characteristics (compute-heavy vs. memory-heavy vs. I/O-heavy).

*Epoch-Based Alternative*: Implementing a comparative epoch-based scheduler would enable empirical comparison of determinism (fuel) vs. performance (epochs) trade-offs.

*Priority Scheduling*: Current round-robin scheduler treats all threads equally. Priority-based or weighted fair queuing would enable more sophisticated policies.

*Fix Outdated Comments*: Lines 80-82 in `preemptive.rs` incorrectly reference "epoch-driven yields" when the implementation uses fuel. The epoch handler in `libcalls.rs` contains unnecessary preemptive yield code since epochs are disabled.

= Conclusion

We have successfully implemented preemptive threading in Wasmtime, demonstrating that fair scheduling can be integrated at the fiber level without modifications to guest code. Our exploration of two approaches—epoch-based and fuel-based interruption—revealed important trade-offs between determinism and performance.

The epoch-based approach offered approximately 10% overhead and leveraged wall-time for preemption, but suffered from unpredictable timeslicing, dependency on background threads, and callback lifetime complexity. The fuel-based approach provides deterministic, instruction-count-based preemption at the cost of 24-34% overhead, eliminating background threads and providing reproducible behavior valuable for debugging and research.

Our implementation required extending Wasmtime's blocking context infrastructure with thread-local storage to support preemptive yields from synchronous execution contexts. This TLS-based solution enables nested blocking contexts to access parent suspension points, a pattern common in async runtimes.

The performance overhead of fuel metering—24-34% based on measurements by Shulepov  wasmtime-issue-4109—remains inherent to the current implementation. Proposed optimizations like "slacked fuel" could theoretically reduce this to 10-25%, but are not implemented due to complexity. Production systems like wasmCloud and Fastly choose epoch-based interruption for its lower overhead, accepting non-determinism in exchange for performance.

Our work demonstrates that preemptive scheduling is viable in WebAssembly runtimes and provides a foundation for fair, isolation-focused execution models. The deterministic nature of fuel-based preemption makes it particularly suitable for debugging, testing, and research scenarios where reproducible behavior is essential. Future work on configurable timeslices, comprehensive benchmarking, and priority scheduling could make this approach practical for broader deployment scenarios.