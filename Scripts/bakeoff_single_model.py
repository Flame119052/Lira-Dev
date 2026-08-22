#!/usr/bin/env python3
"""PROTOTYPE/measurement script — throwaway, not shipped product code.
Loads one MLX model, measures load time + peak RSS, runs a short generation,
measures first-token latency + tokens/sec + peak RSS after generation.
Run once per model in its own fresh process for clean isolated numbers.
"""
import sys
import time
import json
import resource

def peak_rss_gb():
    # ru_maxrss is bytes on macOS
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / (1024 ** 3)

def main():
    model_id = sys.argv[1]
    result = {"model": model_id}

    t0 = time.time()
    from mlx_lm import load, generate
    model, tokenizer = load(model_id)
    load_time = time.time() - t0
    result["load_seconds"] = round(load_time, 2)
    result["peak_rss_gb_after_load"] = round(peak_rss_gb(), 3)

    prompt = "In one short paragraph, explain what makes a good personal assistant."
    messages = [{"role": "user", "content": prompt}]
    formatted = tokenizer.apply_chat_template(messages, add_generation_prompt=True)

    gen_start = time.time()
    response = generate(model, tokenizer, prompt=formatted, max_tokens=150, verbose=False)
    gen_time = time.time() - gen_start

    result["generation_seconds"] = round(gen_time, 2)
    result["response_preview"] = response[:200]
    result["peak_rss_gb_after_generation"] = round(peak_rss_gb(), 3)

    print(json.dumps(result, indent=2))

if __name__ == "__main__":
    main()
