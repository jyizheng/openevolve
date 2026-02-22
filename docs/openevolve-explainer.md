# OpenEvolve Explained

This document explains what OpenEvolve is, how it works internally, and what each of the bundled examples is trying to accomplish.

---

## What is OpenEvolve?

OpenEvolve is an open-source implementation of Google DeepMind's AlphaEvolve system. The core idea is simple: instead of writing code by hand to solve a hard optimization problem, you write a rough initial attempt and a function that scores it, then let an LLM iteratively rewrite and improve the code over hundreds or thousands of rounds. The LLM is guided by feedback from previous attempts, and the population of programs is managed by evolutionary algorithms borrowed from the field of quality-diversity optimization.

The kinds of problems it is well-suited for:
- **Algorithm optimization**: You have a working algorithm but want it faster, more accurate, or more memory-efficient.
- **Mathematical discovery**: You want to find a formula, packing, or combinatorial structure that maximizes some objective.
- **Prompt engineering**: You want to find the best prompt wording for an LLM benchmark task.
- **Cross-language optimization**: You want to evolve Rust, R, or C++ code, not just Python.

The kinds of problems it is NOT suited for:
- Problems where the search space has no gradient signal (every attempt scores 0 until one scores 1).
- Problems requiring domain knowledge the LLM does not have.
- Real-time or interactive systems that cannot be evaluated in a batch loop.

---

## The Evolution Loop

Every iteration of OpenEvolve follows the same four steps:

```
1. SAMPLE    — pick a parent program and some inspirations from the population
2. GENERATE  — ask an LLM to mutate the parent code, guided by the inspirations and history
3. EVALUATE  — run the new program and measure its quality with a custom scoring function
4. STORE     — if it scores well enough, add it to the population
```

Repeat this loop thousands of times. Over time the population drifts toward higher-scoring programs, occasionally discovering qualitatively different solutions that previous generations never tried.

---

## Core Components

### Controller (`openevolve/controller.py`)

The controller is the top-level orchestrator. It initializes all subsystems, runs the evolution loop, and saves checkpoints. It uses a `ProcessPoolExecutor` to run multiple iterations in parallel — each worker process receives a snapshot of the database so they can all sample and evaluate independently, then their results are merged back.

The controller also handles graceful shutdown: when it receives `SIGTERM` (e.g., on AWS Spot interruption), it waits for in-flight iterations to finish, saves a checkpoint, and exits cleanly. Resume from checkpoint simply reloads that snapshot and continues counting from where it left off.

### Database (`openevolve/database.py`)

The database is the heart of the evolutionary algorithm. It does two things that most simple genetic algorithms do not:

**MAP-Elites (Quality-Diversity)**

Rather than keeping only the single best program, the database maintains a multi-dimensional grid. Each dimension corresponds to a metric returned by the evaluator (e.g., execution time, memory usage, code complexity). Each cell in the grid holds the best program found so far for that particular combination of feature values.

This matters because two programs can both be "good" in completely different ways — one is fast and memory-hungry, another is slow but memory-efficient. MAP-Elites keeps both. This diversity prevents the evolution from converging prematurely to a local optimum and keeps the search space well-explored.

**Island-Based Evolution**

The database maintains several independent subpopulations called islands (default: 5). Each island has its own MAP-Elites grid and evolves in isolation. Every N generations (default: 50), a small fraction of programs migrate between islands. This replicates what happens in biological evolution when geographically isolated populations occasionally interbreed — it prevents the entire species from converging to one solution while still allowing cross-pollination of good ideas.

Each iteration samples from one island in round-robin order.

**Sampling Strategy**

When selecting a parent program, the database uses three modes:
- **Exploration** (20% of samples): purely random — picks any program in the island
- **Exploitation** (70% of samples): picks from the archive — the elite set of highest-scoring programs
- **Weighted** (10% of samples): fitness-proportional selection across the whole population

Inspiration programs (shown to the LLM as examples) are sampled separately, biased toward diversity rather than fitness.

### Evaluator (`openevolve/evaluator.py`)

The evaluator runs the evolved program in a subprocess, captures its output, and returns a dictionary of metrics. The only required key is `combined_score` — a single float the system maximizes. Additional keys become the feature dimensions for the MAP-Elites grid.

The evaluator supports **cascade evaluation**: a multi-stage pipeline where cheap tests run first and expensive tests only run if the program passes the early gates. A program that is obviously wrong gets rejected in 30 seconds instead of waiting 5 minutes for the full test suite. This is critical for throughput when running thousands of iterations.

### Iteration (`openevolve/iteration.py`)

A single iteration worker. It samples from the database, builds a prompt, calls the LLM, parses the response (either a unified diff or a full rewrite), applies it to the parent code, runs the evaluator, and returns the result to the controller.

The prompt includes:
- The current program code
- The parent's scores and which metrics need improvement
- The top-performing programs seen so far
- A few diverse "inspiration" programs from the population
- Artifacts: structured debugging data the program can return to help the LLM understand what went wrong

### LLM Ensemble (`openevolve/llm/`)

Multiple models can be configured with weights. On each iteration the ensemble randomly picks one model (weighted by its configured weight). This is useful when different models have different strengths — one model might be better at algorithmic creativity, another at clean refactoring. The ensemble averages their contributions over many iterations.

All model calls use the OpenAI-compatible API format. This means the same configuration works for OpenAI, Anthropic, Google Gemini, local models via Ollama or vLLM, and any other provider that implements the OpenAI REST interface.

### Prompt System (`openevolve/prompt/`)

The prompt builder assembles the full LLM input from templates. It includes a system message that explains the task and asks for code improvements, followed by a user message that contains the evolution history, current scores, and improvement suggestions. Templates support stochastic variations — slightly different phrasing each iteration — to prevent the LLM from getting stuck in a repetitive pattern.

---

## How to Use OpenEvolve

You need two files:

**1. `initial_program.py`** — your starting point. Mark the section the LLM is allowed to modify:

```python
def some_fixed_helper():
    pass  # this will not be touched

# EVOLVE-BLOCK-START
def solve(problem):
    # this is the starting implementation
    # the LLM will rewrite this block
    return naive_solution(problem)
# EVOLVE-BLOCK-END
```

There is exactly one `EVOLVE-BLOCK`. Code outside it is fixed and provides stable scaffolding. Code inside it is what evolves.

**2. `evaluator.py`** — your scoring function. It receives a path to the evolved program, runs it, and returns a dict:

```python
def evaluate(program_path: str) -> dict:
    result = run_program(program_path)
    return {
        "combined_score": result.quality,   # required: the primary objective
        "execution_time": result.seconds,   # optional: used as MAP-Elites feature
        "memory_mb": result.peak_memory,    # optional: used as MAP-Elites feature
    }
```

The `combined_score` is what gets maximized. The other keys become feature dimensions for the diversity grid — they are raw values, not bin indices.

Run it:
```bash
python openevolve-run.py initial_program.py evaluator.py \
    --config config.yaml \
    --iterations 1000 \
    --output ./results
```

---

## Examples

OpenEvolve ships with over 20 examples covering a wide range of domains. Each one demonstrates a different class of problem and a different way to structure the initial program and evaluator.

---

### Function Minimization (`examples/function_minimization/`)

**What it's trying to achieve**: Find the global minimum of a complex, non-convex mathematical function — the kind with many local minima that a simple gradient descent would get trapped in.

**The initial program**: A naive random search that samples random points in the search space and tracks the best one found.

**The evaluator**: Calls the program's `minimize()` function on the test function and measures how close the result is to the known global minimum. The score is `1 / (1 + distance_from_minimum)`.

**What OpenEvolve discovers**: The LLM progressively replaces the random search with increasingly sophisticated strategies. By generation ~100 it typically discovers simulated annealing — a temperature-based exploration scheme with adaptive step sizing and stagnation handling. The final solution often looks nothing like the original random search.

**Why it's a good starter example**: The problem is simple enough to understand immediately, the evaluator runs in milliseconds (enabling many iterations quickly), and the improvement trajectory is dramatic and easy to visualize.

---

### Circle Packing (`examples/circle_packing/`)

**What it's trying to achieve**: Pack 26 non-overlapping circles inside a unit square such that the sum of all radii is maximized. This is a classic combinatorial geometry problem where optimal solutions are known only for small numbers of circles.

**The initial program**: Constructs a layout using concentric rings — a reasonable geometric heuristic that achieves roughly 0.96 sum of radii.

**The evaluator**: Checks that all circles are within bounds and non-overlapping, then returns the sum of radii as the score.

**What OpenEvolve discovers**: The evolution passes through several qualitatively different approaches:
- Concentric rings (generation 0): sum ≈ 0.96
- Hexagonal close-packing (generation ~10): sum ≈ 1.80
- Grid-based layout with corner adjustments (generation ~100): sum ≈ 2.20
- `scipy.optimize` with analytical constraint formulation (generation ~470): sum ≈ 2.63

The final solution matches 99.97% of the AlphaEvolve result published by DeepMind. The LLM independently discovered that this is a constrained optimization problem and reformulated it accordingly.

**Why it's notable**: It demonstrates that OpenEvolve can discover not just parameter improvements but entire paradigm shifts in approach — from a geometric heuristic to a mathematical optimizer.

---

### TSP Tour Minimization (`examples/tsp_tour_minimization/`)

**What it's trying to achieve**: Find short tours of 1000 cities for the Traveling Salesman Problem — a canonical NP-hard combinatorial optimization problem. The goal is to minimize average tour length across multiple random instances.

**The initial program**: A C++/Python hybrid using 2-opt local search with random restarts.

**The evaluator**: Compiles the C++ code, generates random 1000-city instances, runs the solver on each, measures tour length, and scores by improvement over the greedy baseline.

**What OpenEvolve discovers**: Multiple complementary improvements over ~470 iterations:
- **Time-bounded restarts** instead of fixed-count restarts (adapts to available compute)
- **Greedy construction seeding** (starts from a better initial tour rather than random)
- **Selective k-opt** (applies stronger moves only where they are likely to help)
- **Eliminated O(n²) redundant computation** in the weight function

The combined result is a 33% improvement in mean tour length over the baseline.

**Why it's notable**: This is the most engineering-realistic example — a multi-language project with compilation, a noisy objective (random instances), and algorithmic improvements that require understanding the existing code deeply. It shows that OpenEvolve can work on production-scale algorithm code, not just toy problems.

---

### Symbolic Regression (`examples/symbolic_regression/`)

**What it's trying to achieve**: Discover a mathematical expression (formula) that fits a dataset — i.e., reverse-engineer the underlying equation from observed data points. This is what a physicist does when trying to find a governing equation from experimental measurements.

**The initial program**: A simple linear regression model. It fits the data poorly but provides a valid starting structure.

**The evaluator**: Fits the program's model to training data and measures normalized mean squared error (NMSE) on a held-out test set. Lower NMSE is better; the score is `-NMSE`.

**What OpenEvolve discovers**: The evolution produces progressively more expressive mathematical forms. For physics datasets it often discovers the correct underlying equation — for example, the Duffing oscillator equation with sinusoidal forcing terms. Reported results on the LLM-SRBench benchmark:
- Chemistry datasets: NMSE ≈ 2.34 × 10⁻⁶
- Physics datasets: NMSE ≈ 1.85 × 10⁻⁵

**Why it's notable**: The task has no fixed algorithm — the solution space is the space of all possible mathematical expressions. OpenEvolve must invent the expression itself, not just tune parameters of a fixed algorithm.

---

### Signal Processing (`examples/signal_processing/`)

**What it's trying to achieve**: Design a real-time adaptive filter for non-stationary signals — signals whose statistical properties change over time (e.g., EEG, financial time series, radar returns).

**The initial program**: A Savitzky-Golay filter with fixed window and polynomial order — a classic smooth-then-differentiate approach.

**The evaluator**: Generates synthetic non-stationary test signals, runs the filter, and measures signal-to-noise ratio of the filtered output.

**What OpenEvolve discovers**: The evolution produces an interesting two-phase trajectory. Early iterations improve the Savitzky-Golay parameters. Around iteration 100–130, the LLM makes a qualitative leap and introduces a Kalman filter — an entirely different mathematical framework based on state-space estimation. The Kalman filter naturally adapts to non-stationary signals because it maintains an estimate of the signal's current state and uncertainty.

Final improvement: 23% increase in signal quality score (0.30 → 0.37).

**Why it's notable**: The transition from a heuristic smoothing filter to a principled Kalman filter is the kind of insight that usually requires domain expertise. OpenEvolve discovered it from first principles by testing whether different code structures score better.

---

### Rust Adaptive Sort (`examples/rust_adaptive_sort/`)

**What it's trying to achieve**: Evolve a sorting algorithm implemented in Rust that adapts to the statistical properties of the input (e.g., partially sorted data, nearly-reversed data, data with many duplicates).

**The initial program**: A straightforward Rust quicksort implementation.

**The evaluator**: Compiles the Rust code with `rustc`, runs it against a suite of input distributions, measures throughput (elements sorted per second), and aggregates across distributions.

**What OpenEvolve discovers**: Adaptations for specific input patterns — detecting partial sortedness with a cheap pre-pass and switching to insertion sort for nearly-sorted inputs, using counting sort branches for data with few distinct values.

**Why it's notable**: This example validates that OpenEvolve is not Python-specific. The EVOLVE-BLOCK mechanism works identically in Rust: the markers are Rust comments, and the evaluator handles compilation before scoring. Any language that can be compiled and run in a subprocess is supported.

---

### LLM Prompt Optimization (`examples/llm_prompt_optimization/`)

**What it's trying to achieve**: Find the optimal prompt wording for LLM benchmark tasks. The prompt is the "program" being evolved — the goal is to maximize task accuracy by rewording, restructuring, or adding instructions to the prompt template.

**The initial program**: A baseline prompt (e.g., "Answer the following question:") wrapped in the EVOLVE-BLOCK.

**The evaluator**: Calls an LLM API with the evolved prompt on a held-out set of benchmark examples and returns accuracy as the score. Benchmarks tested: IFEval (instruction following), HoVer (evidence-based QA), HotpotQA (multi-hop reasoning), GSM8K (math word problems).

**What OpenEvolve discovers**:
- IFEval: 95.01% → 97.41% accuracy (+2.40%)
- HotpotQA: 77.93% → 88.62% accuracy (+10.69%)

The evolved prompts add specific instructions, chain-of-thought structures, and formatting cues that the LLM responds to well.

**Why it's notable**: This is a meta-application — using an LLM to optimize prompts for an LLM. It also has an unusual property: the "code" being evolved is natural language, not a programming language, which demonstrates that the EVOLVE-BLOCK mechanism is format-agnostic.

---

### AlphaEvolve Math Problems (`examples/alphaevolve_math_problems/`)

**What it's trying to achieve**: Replicate and extend the mathematical discovery results from the original AlphaEvolve paper. This is a suite of 14 classic open mathematical problems in combinatorics and geometry.

**Problems included**:
- **Matrix multiplication**: Find algorithms for multiplying matrices with fewer scalar multiplications than the standard algorithm (the Strassen direction).
- **Autocorrelation inequalities** (3 variants): Find binary sequences whose autocorrelation coefficients satisfy specified bounding conditions.
- **Uncertainty inequality**: Construct functions that simultaneously minimize spread in frequency and time domains (Heisenberg uncertainty analog).
- **Erdős minimum overlap**: Find set families minimizing pairwise overlap.
- **Hexagon packing**: Pack hexagons in the plane to maximize area coverage.
- **Min/max distance ratio**: Find point configurations maximizing the ratio of minimum to maximum pairwise distance.
- **Heilbronn triangles**: Place n points in the unit square such that the minimum triangle area formed by any 3 points is maximized.
- **Kissing number (11D)**: Find the maximum number of non-overlapping unit spheres that can simultaneously touch a central unit sphere in 11 dimensions.
- **Circle packing variants**: Variations on the circle-in-square problem with different constraints.

**Why it's notable**: These are genuine open problems in mathematics. Some have known optimal solutions that serve as benchmarks; others do not. The original DeepMind paper reported improvements on several of these. This example suite allows you to test whether your setup and LLM can rediscover those results.

---

### Online Judge Programming (`examples/online_judge_programming/`)

**What it's trying to achieve**: Solve competitive programming problems — problems from sites like Kattis or LeetCode where you must write a program that passes a judge's automated test cases within time and memory limits.

**The example problem (Alphabet)**: Find the length of the longest substring of a given string that contains all 26 letters of the alphabet. The evaluator runs the evolved program against the judge's test cases.

**The initial program**: A brute-force O(n³) solution that checks all substrings.

**What OpenEvolve discovers**: A sliding-window algorithm with a character frequency counter. The key insight — that you can advance a window over the string in O(n) time — is discovered in about 4 iterations.

**Why it's notable**: This demonstrates that OpenEvolve can produce not just parameter improvements but fundamentally better algorithms when the problem structure admits a clever solution. It also shows that the competitive programming setting is a natural fit: the evaluator is already written (the judge), and the scoring is binary (pass/fail) aggregated over test cases.

---

### R Robust Regression (`examples/r_robust_regression/`)

**What it's trying to achieve**: Evolve a robust regression method in R that handles datasets with outliers better than ordinary least squares.

**The initial program**: Basic OLS regression using R's `lm()` function.

**The evaluator**: Runs the R program (via `Rscript`) on datasets with injected outliers, measures mean absolute error, and returns the score.

**What OpenEvolve discovers**: Progressively more outlier-resistant methods — iteratively reweighted least squares, M-estimators, and combinations of robust scaling and Huber loss functions.

**Why it's notable**: Another demonstration of multi-language support, this time with R, which is common in statistics and data science. Any language with a command-line interpreter is supported.

---

### MLX Metal Kernel Optimization (`examples/mlx_metal_kernel_optimization/`)

**What it's trying to achieve**: Optimize low-level GPU compute kernels for Apple Silicon using the MLX framework's Metal shading language backend. The goal is to maximize throughput of matrix operations on the GPU.

**The initial program**: A baseline Metal kernel (GPU shader code) for matrix-vector multiplication.

**The evaluator**: Runs the kernel on Apple Silicon hardware, measures wall-clock time and FLOP/s, and returns throughput as the score.

**What OpenEvolve discovers**: Memory access pattern optimizations (coalescing), register tiling, loop unrolling factors, and threadgroup size tuning — the same kinds of transformations that GPU performance engineers spend weeks applying by hand.

**Why it's notable**: This is hardware-specific code at the system programming level, far below what most LLMs are routinely asked to write. It demonstrates that the EVOLVE-BLOCK abstraction works even for specialized, low-level code as long as a scoring function exists.

---

### Attention Optimization (`examples/attention_optimization/`)

**What it's trying to achieve**: Optimize a custom multi-head attention mechanism — the core computational building block of transformer models. The goal is to maximize throughput (tokens per second) while maintaining numerical correctness.

**The initial program**: A standard PyTorch attention implementation using explicit matrix multiplications.

**The evaluator**: Benchmarks the evolved attention function on a suite of sequence lengths and batch sizes, verifies correctness against the reference implementation, and returns throughput as the score.

**What OpenEvolve discovers**: Fused operations (combining multiple passes into one), memory-efficient chunked attention for long sequences, and custom CUDA-friendly computation orderings.

**Why it's notable**: This is directly analogous to what performance engineers working on production LLM inference systems do. An evolved kernel that improves throughput by even a few percent translates to significant cost savings at scale.

---

### Web Scraper with optillm (`examples/web_scraper_optillm/`)

**What it's trying to achieve**: Evolve a web scraping strategy using optillm — an LLM proxy that adds reasoning strategies (chain-of-thought, self-consistency, debate) on top of a base model. The goal is to maximize extraction accuracy across diverse web page structures.

**Why it's notable**: This is an integration example rather than a pure optimization example. It shows how OpenEvolve composes with other LLM infrastructure.

---

### LM-Eval Integration (`examples/lm_eval_integration/`)

**What it's trying to achieve**: Use OpenEvolve with the `lm-evaluation-harness` library (the standard tool for evaluating language models) as the evaluator backend. The evolved programs are prompts or few-shot example sets for a range of NLP benchmarks.

**Why it's notable**: Shows how to plug OpenEvolve into existing evaluation infrastructure without rewriting the evaluator from scratch.

---

## What the Examples Have in Common

Despite their diversity, all examples follow the same structural pattern:

1. **A fixed evaluation harness**: The evaluator defines what "better" means and is never modified. It is the specification.

2. **A clearly scoped evolution target**: The EVOLVE-BLOCK marks exactly what the LLM is allowed to change. Everything outside it is scaffolding.

3. **Metrics that reveal structure**: The best evaluators return not just a scalar score but additional metrics that the MAP-Elites grid can use to maintain diversity — execution time, memory usage, code complexity, or domain-specific measurements.

4. **A starting point that works, however poorly**: The initial program does not need to be good. It needs to be syntactically correct and produce a non-zero score so the LLM has something to improve. A random search, a linear model, a naive brute force — all fine.

5. **An objective that is hard to manually optimize**: If you can easily improve it yourself, OpenEvolve may not be worth the compute. The sweet spot is problems where you know what good looks like (you can write a scorer) but do not know how to get there.

---

## Key Limitations to Be Aware Of

- **The evaluator must be deterministic or nearly so.** If the score of the same program varies widely between runs (due to noise, randomness, or external state), the signal is too noisy for evolution to make progress. Use fixed random seeds or average over multiple runs in the evaluator.

- **Evaluation time is the primary cost driver.** If each evaluation takes 60 seconds and you run 10,000 iterations with 4 parallel workers, that is 69 hours of wall time. Fast evaluators (< 5 seconds) are strongly preferred for exploratory runs.

- **The LLM does not know your domain.** It can rearrange, combine, and extend patterns it has seen in training data. For problems that require genuinely novel mathematical insight not in the training corpus, it will plateau.

- **The EVOLVE-BLOCK is a single contiguous block.** Multi-file or multi-function evolution requires careful design of the scaffolding so that all relevant code is inside one block, or the evaluator imports a module that is entirely the evolved block.
